import 'dart:convert';
import 'dart:io';

import 'package:sqflite/sqflite.dart';

import '../models/models.dart';
import 'local_db.dart';

/// 数据访问层。上层的页面只跟这里打交道，
/// 将来把本地库换成云端只改这一层，界面不动。
class Repository {
  Repository._();
  static final Repository instance = Repository._();

  // ---------------- 家庭与全局状态 ----------------

  Future<String?> readMeta(String key) async {
    final db = await LocalDb.instance.db;
    final rows = await db.query('meta', where: 'key = ?', whereArgs: [key]);
    if (rows.isEmpty) return null;
    return rows.first['value'] as String;
  }

  Future<void> writeMeta(String key, String value) async {
    final db = await LocalDb.instance.db;
    await db.insert(
      'meta',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteMeta(String key) async {
    final db = await LocalDb.instance.db;
    await db.delete('meta', where: 'key = ?', whereArgs: [key]);
  }

  Future<Family?> loadFamily() async {
    final raw = await readMeta('family');
    if (raw == null) return null;
    return Family.fromMap(jsonDecode(raw) as Map<String, Object?>);
  }

  Future<void> saveFamily(Family family) async {
    await writeMeta('family', jsonEncode(family.toMap()));
  }

  // ---------------- 孩子 ----------------

  Future<List<Child>> children() async {
    final db = await LocalDb.instance.db;
    final rows = await db.query('children', orderBy: 'created_at ASC');
    return rows.map(Child.fromMap).toList();
  }

  Future<void> upsertChild(Child child) async {
    final db = await LocalDb.instance.db;
    await db.insert(
      'children',
      child.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 删孩子：本地物理删（这台设备上不该再看见），同时留一条墓碑。
  ///
  /// 墓碑是给云端看的：`is_deleted = true` 必须推上去，否则
  /// - 家长换设备用家庭码接入时，这个孩子会被 [SyncService.pullChildren] 拉回来「复活」
  /// - 孩子那台设备仍然能凭姓名登进来，继续看到他名下的作业
  ///
  /// 本地连作业和计时段一起删，是因为这台设备已经不需要它们了；
  /// 云端那两份交给墓碑同步时级联软删。
  Future<void> deleteChild(String id) async {
    final db = await LocalDb.instance.db;
    // 先取 family_id：删完 children 行就查不到了
    final rows = await db.query(
      'children',
      columns: ['family_id'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    final familyId =
        rows.isEmpty ? '' : ((rows.first['family_id'] as String?) ?? '');

    await db.insert(
      'deleted_children',
      {
        'id': id,
        'family_id': familyId,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await db.delete('children', where: 'id = ?', whereArgs: [id]);
    await db.delete('homework', where: 'child_id = ?', whereArgs: [id]);
    await db.delete('homework_sessions', where: 'child_id = ?', whereArgs: [id]);
  }

  /// 只清本机缓存，**不写墓碑**。
  ///
  /// 用于「云端已经标记删除，本机还留着」的场景：这时不需要再通知云端，
  /// 写墓碑反而会在同步时重复一次无意义的 UPDATE。
  Future<void> removeLocalChild(String id) async {
    final db = await LocalDb.instance.db;
    await db.delete('children', where: 'id = ?', whereArgs: [id]);
    await db.delete('homework', where: 'child_id = ?', whereArgs: [id]);
    await db.delete('homework_sessions', where: 'child_id = ?', whereArgs: [id]);
  }

  /// 还没通知云端的删除。同步成功后由 [clearChildDeletion] 清掉。
  Future<List<({String id, String familyId})>> pendingChildDeletions() async {
    final db = await LocalDb.instance.db;
    final rows = await db.query('deleted_children', orderBy: 'created_at ASC');
    return [
      for (final r in rows)
        (
          id: r['id'] as String,
          familyId: (r['family_id'] as String?) ?? '',
        ),
    ];
  }

  Future<void> clearChildDeletion(String id) async {
    final db = await LocalDb.instance.db;
    await db.delete('deleted_children', where: 'id = ?', whereArgs: [id]);
  }

  /// 孩子端凭姓名登录。同名时返回多条，由界面要求补家庭码消歧。
  Future<List<Child>> findChildrenByName(String name) async {
    final db = await LocalDb.instance.db;
    final rows = await db.query(
      'children',
      where: 'name = ?',
      whereArgs: [name.trim()],
    );
    return rows.map(Child.fromMap).toList();
  }

  Future<bool> childNameExists(String name, {String? exceptId}) async {
    final db = await LocalDb.instance.db;
    final rows = await db.query(
      'children',
      where: exceptId == null ? 'name = ?' : 'name = ? AND id != ?',
      whereArgs: exceptId == null ? [name.trim()] : [name.trim(), exceptId],
    );
    return rows.isNotEmpty;
  }

  // ---------------- 作业 ----------------

  Future<List<Homework>> homeworkByDate(String childId, String date) async {
    final db = await LocalDb.instance.db;
    final rows = await db.query(
      'homework',
      where: 'child_id = ? AND date = ? AND is_deleted = 0',
      whereArgs: [childId, date],
      orderBy: 'created_at ASC',
    );
    return rows.map(Homework.fromMap).toList();
  }

  Future<List<Homework>> homeworkByRange(
    String childId,
    String from,
    String to,
  ) async {
    final db = await LocalDb.instance.db;
    final rows = await db.query(
      'homework',
      where:
          'child_id = ? AND date >= ? AND date <= ? AND is_deleted = 0',
      whereArgs: [childId, from, to],
      orderBy: 'date DESC, created_at ASC',
    );
    return rows.map(Homework.fromMap).toList();
  }

  Future<List<Homework>> homeworkAll(String childId) async {
    final db = await LocalDb.instance.db;
    final rows = await db.query(
      'homework',
      where: 'child_id = ? AND is_deleted = 0',
      whereArgs: [childId],
      orderBy: 'date DESC, created_at ASC',
    );
    return rows.map(Homework.fromMap).toList();
  }

  Future<void> upsertHomework(Homework hw) async {
    final db = await LocalDb.instance.db;
    await db.insert(
      'homework',
      hw.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> softDeleteHomework(String id) async {
    final db = await LocalDb.instance.db;
    await db.update(
      'homework',
      {
        'is_deleted': 1,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
        'pending_sync': 1,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 只更新完成状态相关的两个字段。
  /// 这是并发安全的要点：家长端写内容、孩子端写完成状态，两端字段不重叠，
  /// 因此永远不要用整条记录覆盖去改 isDone。
  Future<void> setDone(String id, bool done) async {
    final db = await LocalDb.instance.db;
    await db.update(
      'homework',
      {
        'is_done': done ? 1 : 0,
        'done_at': done ? DateTime.now().millisecondsSinceEpoch : null,
        'pending_sync': 1,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 日历打点：某孩子某个月里哪些日期有作业。
  Future<Set<String>> datesWithHomework(
    String childId,
    int year,
    int month,
  ) async {
    final db = await LocalDb.instance.db;
    final from = '$year-${month.toString().padLeft(2, '0')}-01';
    final to = '$year-${month.toString().padLeft(2, '0')}-31';
    final rows = await db.query(
      'homework',
      columns: ['date'],
      where:
          'child_id = ? AND date >= ? AND date <= ? AND is_deleted = 0',
      whereArgs: [childId, from, to],
      groupBy: 'date',
    );
    return rows.map((e) => e['date'] as String).toSet();
  }

  Future<int> pendingSyncCount() async {
    final db = await LocalDb.instance.db;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM homework WHERE pending_sync = 1',
    );
    return (rows.first['c'] as int?) ?? 0;
  }

  // ---------------- 云端同步支持 ----------------

  Future<Homework?> homeworkById(String id) async {
    final db = await LocalDb.instance.db;
    final rows =
        await db.query('homework', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return Homework.fromMap(rows.first);
  }

  /// 待上传的行。家长端上传正文，孩子端只上传完成状态。
  Future<List<Homework>> pendingHomework() async {
    final db = await LocalDb.instance.db;
    final rows = await db.query('homework', where: 'pending_sync = 1');
    return rows.map(Homework.fromMap).toList();
  }

  /// 上传成功后清标记，同时把云端返回的图片 key 落库。
  Future<void> markSynced(
    String id, {
    List<String>? imageKeys,
    List<Attachment>? attachments,
  }) async {
    final db = await LocalDb.instance.db;
    await db.update(
      'homework',
      {
        'pending_sync': 0,
        if (imageKeys != null) 'image_keys': imageKeys.join('\u0001'),
        // 附件上传后会拿到云端 key，必须写回本地：
        // 不写回的话下一轮同步会认为它还没传，把同一个文件再传一遍。
        if (attachments != null)
          'attachments': Attachment.encodeList(attachments),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 把云端一条作业合并进本地。
  ///
  /// 合并规则（V1 唯一要写对的地方）：
  /// - 本地有未上传的改动 → 正文以本地为准，只吸收云端完成状态，绝不会被覆盖
  /// - 本地没有待上传改动 → 云端为准，但**逐槽位**保留本机已有的图片文件，
  ///   免得家长端把原图「弄丢」变成网络图（详见 [mergeCloudSlots]）
  Future<void> mergeFromCloud(Homework cloud) async {
    final local = await homeworkById(cloud.id);
    final db = await LocalDb.instance.db;

    if (local == null) {
      await upsertHomework(cloud);
      return;
    }

    if (local.pendingSync) {
      await db.update(
        'homework',
        {
          'is_done': cloud.isDone ? 1 : 0,
          'done_at': cloud.doneAt,
        },
        where: 'id = ?',
        whereArgs: [cloud.id],
      );
      return;
    }

    // 逐槽位合并：云端定槽位，本机第 i 格有原图就继续用本地路径。
    // 只有本机读不到文件（文件被清理、路径失效）的格子才留空走云端图。
    final merged = dropEmptyTailSlots(
      mergeCloudSlots(local.images, cloud.imageKeys)
          .map(
            (s) => ImageSlot(_readableFile(s.local) ? s.local : '', s.key),
          )
          .toList(),
    );
    await upsertHomework(
      cloud.copyWith(
        images: [for (final s in merged) s.local],
        imageKeys: [for (final s in merged) s.key],
      ),
    );
  }

  /// 本地路径现在还读得到吗。
  /// 失效的路径不要硬填进 images——编辑页会按它去读文件，结果是一张破图。
  bool _readableFile(String path) {
    if (path.isEmpty) return false;
    try {
      return File(path).existsSync();
    } catch (_) {
      return false;
    }
  }

  Future<void> clearAllHomeworkPending() async {
    final db = await LocalDb.instance.db;
    await db.update('homework', {'pending_sync': 0});
  }

  // ---------------- 作业计时 ----------------

  /// 写一段计时（含暂停中途的多次落库，同一个 id 覆盖）。
  Future<void> upsertSession(HomeworkSession s) async {
    final db = await LocalDb.instance.db;
    await db.insert(
      'homework_sessions',
      s.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<HomeworkSession>> pendingSessions() async {
    final db = await LocalDb.instance.db;
    final rows =
        await db.query('homework_sessions', where: 'pending_sync = 1');
    return rows.map(HomeworkSession.fromMap).toList();
  }

  Future<void> markSessionSynced(String id) async {
    final db = await LocalDb.instance.db;
    await db.update(
      'homework_sessions',
      {'pending_sync': 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 云端拉下来的段落库。
  /// 本地还有没上传的改动时以本地为准——同一段计时本地才是最准的。
  Future<void> mergeSessionFromCloud(HomeworkSession s) async {
    final db = await LocalDb.instance.db;
    final rows = await db.query(
      'homework_sessions',
      where: 'id = ?',
      whereArgs: [s.id],
      limit: 1,
    );
    if (rows.isNotEmpty) {
      final local = HomeworkSession.fromMap(rows.first);
      if (local.pendingSync) return;
    }
    await db.insert(
      'homework_sessions',
      s.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 某天某一科的时长合计（秒）。键是学科名。
  ///
  /// 只返回**有记录**的学科：没有记录就不该出现在界面上，
  /// 写「0 分钟」容易被家长读成「这科没学」。
  Future<Map<String, int>> subjectSecondsOnDate(
    String childId,
    String date,
  ) async {
    final db = await LocalDb.instance.db;
    final rows = await db.rawQuery(
      'SELECT subject, SUM(seconds) AS s FROM homework_sessions '
      'WHERE child_id = ? AND date = ? GROUP BY subject',
      [childId, date],
    );
    return _sumMap(rows, 'subject');
  }

  /// 区间内按学科汇总。
  Future<Map<String, int>> subjectSecondsInRange(
    String childId,
    String from,
    String to,
  ) async {
    final db = await LocalDb.instance.db;
    final rows = await db.rawQuery(
      'SELECT subject, SUM(seconds) AS s FROM homework_sessions '
      'WHERE child_id = ? AND date >= ? AND date <= ? GROUP BY subject',
      [childId, from, to],
    );
    return _sumMap(rows, 'subject');
  }

  /// 区间内按天汇总，返回 yyyy-MM-dd → 秒。
  Future<Map<String, int>> daySecondsInRange(
    String childId,
    String from,
    String to,
  ) async {
    final db = await LocalDb.instance.db;
    final rows = await db.rawQuery(
      'SELECT date, SUM(seconds) AS s FROM homework_sessions '
      'WHERE child_id = ? AND date >= ? AND date <= ? GROUP BY date',
      [childId, from, to],
    );
    return _sumMap(rows, 'date');
  }

  /// 某一天的全部计时段，按开始时间正序。
  Future<List<HomeworkSession>> sessionsOfDate(
    String childId,
    String date,
  ) async {
    final db = await LocalDb.instance.db;
    final rows = await db.query(
      'homework_sessions',
      where: 'child_id = ? AND date = ?',
      whereArgs: [childId, date],
      orderBy: 'start_at ASC',
    );
    return rows.map(HomeworkSession.fromMap).toList();
  }

  /// 按天汇总里「有记录的学科数」：同一天多段要算一科。
  Future<Map<String, Set<String>>> subjectsPerDayInRange(
    String childId,
    String from,
    String to,
  ) async {
    final db = await LocalDb.instance.db;
    final rows = await db.rawQuery(
      'SELECT DISTINCT date, subject FROM homework_sessions '
      'WHERE child_id = ? AND date >= ? AND date <= ?',
      [childId, from, to],
    );
    final out = <String, Set<String>>{};
    for (final r in rows) {
      out.putIfAbsent(r['date'] as String, () => <String>{}).add(
            r['subject'] as String,
          );
    }
    return out;
  }

  Map<String, int> _sumMap(List<Map<String, Object?>> rows, String key) {
    final out = <String, int>{};
    for (final r in rows) {
      final s = (r['s'] as num?)?.toInt() ?? 0;
      if (s <= 0) continue;
      out[r[key] as String] = s;
    }
    return out;
  }
}
