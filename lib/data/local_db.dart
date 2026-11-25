import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

/// 本地库：离线可用、秒开、孩子端断网也能看。
/// 与云端的关系见 repository：先写本地，再异步上传（未接云端前标记 pendingSync）。
class LocalDb {
  LocalDb._();
  static final LocalDb instance = LocalDb._();
  Database? _db;

  Future<Database> get db async {
    if (_db != null) return _db!;
    final dir = await getDatabasesPath();
    final path = p.join(dir, 'homework.db');
    try {
      _db = await _open(path);
    } catch (e) {
      // 迁移把库搞到打不开时，别让整个 App 陪葬。
      //
      // 触发路径很隐蔽：Android 的 `allowBackup` 默认 true，应用数据会被系统
      // 自动备份；用户卸载后重装，备份服务会把 databases/ 原样恢复回来。
      // 恢复的是「卸载前那个版本」的库，schema 可能停在任何中间状态，
      // 而迁移脚本只要有一处不兼容，库就永久打不开——卸载重装都救不回来，
      // 因为下次安装备份又把它恢复一遍。
      //
      // 兜底策略：把坏库改名留档（不删，万一要捞数据），新建一个干净的库
      // 先让 App 跑起来。云端有数据，重新输一次家庭码就能同步回来。
      _db = await _recover(path, e);
    }
    return _db!;
  }

  /// 换后端时的一次性清理。
  ///
  /// 旧库里存着旧家庭 id、旧作业、旧 token。不清会出两个问题：
  ///
  /// 1. 用户在新服务器上建了家庭，本地旧作业的 `family_id` 还是旧值，
  ///    同步时会被服务端按新家庭覆盖 —— 已经放弃的历史作业会诡异地「复活」；
  /// 2. 旧的 refresh token 打新服务端只会拿到 401，触发一次没必要的登出流程。
  ///
  /// 返回 true 表示这次真的清理过，界面应当回到角色选择页。
  Future<bool> migrateToNewBackend() async {
    final database = await db;
    final rows = await database.query(
      'meta',
      where: 'key = ?',
      whereArgs: ['schema_epoch'],
      limit: 1,
    );
    if (rows.isNotEmpty && rows.first['value'] == '2') return false;

    await database.delete('homework');
    await database.delete('children');
    await database.delete('homework_sessions');
    await database.delete('deleted_children');
    await database.delete('meta');

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('cb_token');
    await prefs.remove('cb_refresh_token');
    await prefs.remove('cb_expire_at');

    await database.insert('meta', {'key': 'schema_epoch', 'value': '2'});
    debugPrint('[local_db] 已清理旧后端数据，等待重新登录');
    return true;
  }

  /// 按当前 schema 打开库（首次建库走 onCreate，老库走 onUpgrade）。
  static Future<Database> _open(String path) {    return openDatabase(
      path,
      version: 5,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE children(
            id TEXT PRIMARY KEY,
            family_id TEXT NOT NULL,
            name TEXT NOT NULL,
            color_index INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE homework(
            id TEXT PRIMARY KEY,
            child_id TEXT NOT NULL,
            family_id TEXT NOT NULL DEFAULT '',
            date TEXT NOT NULL,
            subject TEXT NOT NULL,
            content TEXT NOT NULL,
            images TEXT NOT NULL DEFAULT '',
            image_keys TEXT NOT NULL DEFAULT '',
            attachments TEXT NOT NULL DEFAULT '[]',
            is_done INTEGER NOT NULL DEFAULT 0,
            done_at INTEGER,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            pending_sync INTEGER NOT NULL DEFAULT 0,
            is_deleted INTEGER NOT NULL DEFAULT 0
          )
        ''');
        // 家长端与孩子端都按「孩子 + 日期」查，这个复合索引是热点路径
        await db.execute(
          'CREATE INDEX idx_homework_child_date ON homework(child_id, date)',
        );
        await db.execute('''
          CREATE TABLE meta(
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
          )
        ''');
        await _createSessions(db);
        await _createChildTombstones(db);
      },
      // v1 → v2：加云存储 key 列。用户已装的机器上旧数据必须保留，
      // 所以只加列，不重建表。
      // v2 → v3：加计时会话表。
      // v3 → v4：加 family_id 列 + 孩子删除墓碑表。
      // v4 → v5：加附件列（PDF/DOCX 文件与链接卡片的 JSON 数组）。
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await _addColumnIfMissing(
            db, 'homework', 'image_keys', "TEXT NOT NULL DEFAULT ''",
          );
        }
        if (oldVersion < 3) {
          await _createSessions(db);
        }
        if (oldVersion < 4) {
          await _addColumnIfMissing(
            db, 'homework', 'family_id', "TEXT NOT NULL DEFAULT ''",
          );
          await _addColumnIfMissing(
            db, 'homework_sessions', 'family_id', "TEXT NOT NULL DEFAULT ''",
          );
          await _createChildTombstones(db);
        }
        if (oldVersion < 5) {
          // 老作业一律是 '[]'，渲染层按空列表处理，不需要数据回填。
          await _addColumnIfMissing(
            db, 'homework', 'attachments', "TEXT NOT NULL DEFAULT '[]'",
          );
        }
      },
    );
  }

  /// 坏库兜底：留档旧文件，重建一个干净的库。
  ///
  /// 连 `-wal` / `-shm` / `-journal` 一起挪走，只挪主库文件不够——
  /// 留着旧的 WAL，新库打开时会把旧事务日志重放进来，等于白重建。
  static Future<Database> _recover(String path, Object error) async {
    debugPrint('[LocalDb] 打开本地库失败，准备重建：$error');
    final backup = '$path.broken-${DateTime.now().millisecondsSinceEpoch}';
    for (final suffix in const ['', '-wal', '-shm', '-journal']) {
      final file = File('$path$suffix');
      if (!await file.exists()) continue;
      try {
        await file.rename('$backup$suffix');
      } catch (_) {
        // 句柄没释放时改名会失败，退化成删除：库已经打不开了，留着没用
        try {
          await file.delete();
        } catch (_) {}
      }
    }
    debugPrint('[LocalDb] 旧库文件已留存：$backup');
    return _open(path);
  }

  /// 加列前先查一遍表结构，已经有了就跳过。
  ///
  /// 必须有这一步：`_createSessions` 是「新建库」和「老库升级」共用的建表语句，
  /// 它从一开始就带着 v4 才引入的 family_id。于是从 v1/v2 跳版本升到 v4 的设备
  /// 会先建表（表里已有 family_id），紧接着 v3→v4 的 ALTER 又要加同一列，
  /// 撞 duplicate column，数据库打不开，App 直接白屏。
  ///
  /// 正常升级路径（v3→v4）只走 ALTER，碰不到这个坑，所以只在「装过很老版本、
  /// 中间跨了好几个版本」的设备上炸——这种设备恰恰是最难复现的那批。
  static Future<void> _addColumnIfMissing(
    Database db,
    String table,
    String column,
    String definition,
  ) async {
    final rows = await db.rawQuery('PRAGMA table_info($table)');
    if (rows.any((r) => r['name'] == column)) return;
    await db.execute('ALTER TABLE $table ADD COLUMN $column $definition');
  }

  /// 孩子删除墓碑。
  ///
  /// 本地删孩子是物理删（这台设备上不该再显示），但云端必须收到一条明确的
  /// `is_deleted = true`，否则换设备用家庭码接入时孩子会「复活」，
  /// 孩子那台设备也还能用姓名登进来。墓碑就是「这条删除还没告诉云端」的待办。
  static Future<void> _createChildTombstones(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS deleted_children(
        id TEXT PRIMARY KEY,
        family_id TEXT NOT NULL DEFAULT '',
        created_at INTEGER NOT NULL
      )
    ''');
  }

  /// 作业计时会话。老库升级与新建库共用，两处必须完全一致。
  static Future<void> _createSessions(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS homework_sessions(
        id TEXT PRIMARY KEY,
        child_id TEXT NOT NULL,
        family_id TEXT NOT NULL DEFAULT '',
        homework_id TEXT NOT NULL,
        date TEXT NOT NULL,
        subject TEXT NOT NULL,
        start_at INTEGER NOT NULL,
        end_at INTEGER,
        seconds INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        pending_sync INTEGER NOT NULL DEFAULT 0
      )
    ''');
    // 家长端按「孩子 + 日期」出当日明细，按区间出月/年统计，两条都是热点
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_session_child_date '
      'ON homework_sessions(child_id, date)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_session_homework '
      'ON homework_sessions(homework_id)',
    );
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
