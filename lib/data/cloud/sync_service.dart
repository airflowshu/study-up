import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../models/models.dart';
import '../../state/study_timer.dart';
import '../repository.dart';
import 'cloud_api.dart';

enum SyncPhase { idle, syncing, done, failed }

/// 打点开关：`--dart-define=SYNC_TRACE=true` 时才输出每步耗时。
/// 默认关闭，正式包不带这些日志。
const _trace = bool.fromEnvironment('SYNC_TRACE');

void _t(Stopwatch sw, String label) {
  if (!_trace) return;
  debugPrint('[SYNC] ${sw.elapsedMilliseconds.toString().padLeft(5)}ms $label');
}

/// 同步引擎。
///
/// 设计主线是「两端写不同字段」，这是 V1 不出现冲突的唯一原因：
/// - 家长端写：subject / content / images / date / is_deleted
/// - 孩子端写：is_done / done_at
/// 谁都不整行覆盖，所以孩子刚打的勾不会被家长下一次编辑冲掉。
class SyncService extends ChangeNotifier {
  SyncService._();
  static final SyncService instance = SyncService._();

  SyncPhase phase = SyncPhase.idle;
  String message = '尚未同步';
  DateTime? lastSuccess;
  int pendingCount = 0;

  /// 上次失败是不是「网络不通」导致的（而不是服务端报错）。
  /// 界面据此区分「设备离线」和「云端出问题」——两者的提示语完全不同。
  bool lastFailureWasOffline = false;

  /// 上次失败是不是「本地已经没有可用会话」导致的。
  ///
  /// 它和 [lastFailureWasOffline] 是两种完全不同的处置：没网只能等，
  /// 没会话必须重新登录。混成一个「同步失败」，用户就会对着一条
  /// 点多少次都消不掉的红条——这正是家长端那个 bug 的表象。
  bool lastFailureWasAuthMissing = false;

  /// 本轮同步里是否撞到过「会话缺失」。
  ///
  /// 单条推送的异常在内部被吞掉（一条传不上去不能拖累其它条），
  /// 所以不能只看 [phase]，要在这里记一笔。
  bool _sawAuthMissing = false;

  void _noteAuthError(CloudException e) {
    if (e.authMissing) _sawAuthMissing = true;
  }

  // 串行队列：同步不能并发跑，但也不能像早前那样「正在同步就直接返回」——
  // 孩子在同步进行中打勾时，那次请求会被静默吞掉，勾不上传。
  // 现在每次调用都排到上一次之后执行，保证最后一次写入一定会到达云端。
  Future<void> _chain = Future<void>.value();

  Repository get _repo => Repository.instance;
  CloudApi get _api => CloudApi.instance;

  void _set(SyncPhase p, String msg) {
    phase = p;
    message = msg;
    notifyListeners();
  }

  Future<void> refreshPending() async {
    pendingCount = await _repo.pendingSyncCount();
    notifyListeners();
  }

  /// 家庭/孩子档案是否需要重新推。档案没变就别推——
  /// 每天布置作业十几次，每次都 select 一遍 families + N 次 children 纯属白跑。
  bool _familyDirty = true;

  /// 建家庭、加/改名/删孩子、换设备接入之后调用，让下一轮同步把档案补一遍。
  void markFamilyDirty() {
    _familyDirty = true;
  }

  /// 家长端把孩子档案推上去。孩子端要靠这些数据才能登录。
  ///
  /// 家庭行不再由客户端写：它由 `/auth/v1/families` 在服务端创建，
  /// 家庭码也由服务端生成以保证全局唯一。客户端再写会被服务端拒绝（403），
  /// 而且会让每一轮同步都整体失败——所以这里只剩孩子。
  Future<void> pushFamilyAndChildren(Family family, List<Child> children) async {
    if (!_familyDirty) return;
    try {
      for (final c in children) {
        final rows = await _api.select('children', query: {'id': 'eq.${c.id}'});
        final payload = {
          'family_id': c.familyId,
          'name': c.name,
          'color_index': c.colorIndex,
          'created_at': c.createdAt,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        };
        if (rows.isEmpty) {
          await _api.insert('children', {'id': c.id, ...payload, 'is_deleted': false});
        } else {
          // 刻意**不带** is_deleted：云端可能是另一台家长设备删掉后留的墓碑，
          // 这里硬写 false 会把已删的孩子复活。新建才写 false。
          await _api.patch('children', c.id, payload);
        }
      }
      // 全部成功才清标记，中途失败下轮还要补
      _familyDirty = false;
    } catch (e) {
      // 家庭档案推送失败不阻塞作业同步，下次再试
      _familyDirty = true;
      debugPrint('pushFamilyAndChildren failed: $e');
    }
  }

  /// 家长端：把本地删掉的孩子同步成云端的软删墓碑，并级联标记他名下的数据。
  ///
  /// 顺序必须是「先子后父」：先按 child_id 批量标 homework / homework_sessions，
  /// 最后才标 children。中途任何一步失败都保留墓碑，下轮重来——
  /// 宁可重复一次幂等的 UPDATE，也不能出现「孩子删了、作业还活着」的半截状态。
  Future<void> _pushChildDeletions() async {
    final tombstones = await _repo.pendingChildDeletions();
    for (final t in tombstones) {
      try {
        final now = DateTime.now().millisecondsSinceEpoch;
        final filter = 'child_id=eq.${Uri.encodeQueryComponent(t.id)}';
        final patch = {'is_deleted': true, 'updated_at': now};
        await _api.patchWhere('homework', filter, patch);
        await _api.patchWhere('homework_sessions', filter, patch);
        await _api.patchWhere(
          'children',
          'id=eq.${Uri.encodeQueryComponent(t.id)}',
          patch,
        );
        await _repo.clearChildDeletion(t.id);
      } on CloudException catch (e) {
        // 留在墓碑里，下次同步再试
        _noteAuthError(e);
        debugPrint('delete child ${t.id} failed: ${e.message}');
      }
    }
  }


  /// 孩子端同步时发现「我已被家长删除」就置为 true，
  /// 由 AppState 在每轮同步后检查并清掉登录态。
  ///
  /// 只在云端**明确**返回 is_deleted = true 时才置位：网络失败、查不到行
  /// 都不算，否则断网一次孩子就被踢下线了。
  bool childRevoked = false;

  Future<void> _checkRevoked(String childId) async {
    try {
      final rows = await _api.select(
        'children',
        query: {'id': 'eq.$childId', 'select': 'id,is_deleted'},
        limit: 1,
      );
      if (rows.isNotEmpty && (rows.first['is_deleted'] ?? false) == true) {
        childRevoked = true;
      }
    } catch (_) {
      // 查不到就算了，下一轮再看
    }
  }

  /// 家长端：把本地待上传的作业推上去（含图片）。
  Future<void> _pushHomework({required bool uploadContent}) async {
    final pending = await _repo.pendingHomework();
    for (final hw in pending) {
      try {
        if (uploadContent) {
          final keys = await _uploadImages(hw);
          if (keys == null) {
            // 有图片没传成功，整条跳过，绝不写半截数据到云端
            continue;
          }
          final atts = await _uploadAttachments(hw);
          if (atts == null) {
            // 附件同理：卡片已经在正文里出现了，云端却没文件，
            // 孩子端点开就是 404，不如整条留到下轮
            continue;
          }
          final fields = {
            'child_id': hw.childId,
            'family_id': hw.familyId,
            'date': hw.date,
            'subject': hw.subject,
            'content': hw.content,
            'images': keys,
            'attachments': [for (final a in atts) a.toCloudMap()],
            'is_deleted': hw.isDeleted,
            'created_at': hw.createdAt,
            'updated_at': hw.updatedAt,
          };
          final patched = await _api.patch('homework', hw.id, fields);
          if (patched.isEmpty) {
            await _api.insert('homework', {
              'id': hw.id,
              ...fields,
              'is_done': hw.isDone,
              'done_at': hw.doneAt,
            });
          }
          await _repo.markSynced(hw.id, imageKeys: keys, attachments: atts);
        } else {
          // 孩子端只有完成状态可写，且只写这两个字段
          final ok = await _api.patch('homework', hw.id, {
            'is_done': hw.isDone,
            'done_at': hw.doneAt,
          });
          if (ok.isNotEmpty) {
            await _repo.markSynced(hw.id);
          }
        }
      } on CloudException catch (e) {
        // 单条失败不影响其它条，留待下次
        _noteAuthError(e);
        debugPrint('push ${hw.id} failed: ${e.message}');
      }
    }
  }

  /// 上传缺 key 的图片。返回与图片槽位等长的 key 列表；
  /// 有图片传不上去就返回 null，让整条作业留到下轮再同步。
  ///
  /// 3 路并发：家长一次粘 5~10 张图时，串行上传要等好几轮往返，
  /// 并发能把「点发布 → 孩子端看到图」的等待明显压短。
  ///
  /// 槽位口径：images[i] 是本地路径（云端图是空串），imageKeys[i] 是云 key，
  /// 两列按下标一一对应。第 i 格已有 key 就沿用，只有「既没 key 又没本地文件」
  /// 的槽位才需要传。**绝不能因为 images 是空的就返回空列表**——
  /// 那会把「本机没原图、图在云端」的作业的云端图片清空。
  Future<List<String>?> _uploadImages(Homework hw) async {
    final n =
        hw.images.length > hw.imageKeys.length ? hw.images.length : hw.imageKeys.length;
    if (n == 0) return <String>[];
    final keys = List<String>.from(hw.imageKeys);
    while (keys.length < n) {
      keys.add('');
    }

    final pending = <int>[];
    for (var i = 0; i < n; i++) {
      if (keys[i].isNotEmpty) continue;
      if (i >= hw.images.length) continue;
      final local = hw.images[i];
      if (local.isEmpty) continue;
      if (!File(local).existsSync()) continue;
      pending.add(i);
    }
    if (pending.isEmpty) return keys;

    var failed = false;
    const parallel = 3;
    for (var start = 0; start < pending.length; start += parallel) {
      final batch = pending.skip(start).take(parallel).toList();
      await Future.wait(batch.map((i) async {
        final ext = p.extension(hw.images[i]);
        // 路径带上家庭 id：服务端据此校验归属，别人的 token 写不进这个前缀
        final key = 'f/${hw.familyId}/homework/${hw.id}/$i${ext.isEmpty ? '.jpg' : ext}';
        try {
          final bytes = await File(hw.images[i]).readAsBytes();
          await _api.uploadImage(key, bytes, _mimeOf(key));
          keys[i] = key;
        } catch (e) {
          // 任何一张失败都整条延后，绝不把半截 images 数组写进云端
          debugPrint('upload ${hw.images[i]} failed: $e');
          failed = true;
        }
      }));
      if (failed) return null;
    }
    return keys;
  }

  String _mimeOf(String path) {
    final ext = p.extension(path).toLowerCase();
    switch (ext) {
      case '.png':
        return 'image/png';
      case '.webp':
        return 'image/webp';
      case '.gif':
        return 'image/gif';
      default:
        return 'image/jpeg';
    }
  }

  /// 上传缺 key 的附件，返回带上云端 key 的新列表；任何一个失败就返回 null。
  ///
  /// 文件名不参与 key：中文名、空格、重名都会让 URL 变脏。
  /// key 用附件的稳定 id 拼，家长删掉中间某个附件再传，也不会互相覆盖。
  Future<List<Attachment>?> _uploadAttachments(Homework hw) async {
    if (hw.attachments.isEmpty) return hw.attachments;
    final out = <Attachment>[];
    for (final a in hw.attachments) {
      if (!a.isFile || a.key.isNotEmpty || a.localPath.isEmpty) {
        out.add(a);
        continue;
      }
      final file = File(a.localPath);
      if (!file.existsSync()) {
        // 原文件被系统清了：保留卡片（云端如果已有 key 还能打开），
        // 不让它拖住整条作业
        debugPrint('attachment file gone: ${a.localPath}');
        out.add(a);
        continue;
      }
      try {
        final ext = p.extension(a.localPath);
        final tag = a.id.isNotEmpty ? a.id : 'idx${hw.attachments.indexOf(a)}';
        final key = 'f/${hw.familyId}/homework/${hw.id}/att-$tag$ext';
        final bytes = await file.readAsBytes();
        await _api.uploadImage(key, bytes, _mimeOfAttachment(a));
        out.add(a.copyWith(key: key));
      } catch (e) {
        debugPrint('upload attachment ${a.name} failed: $e');
        return null;
      }
    }
    return out;
  }

  /// 附件上传用的 MIME。优先用创建时记下的，老数据按扩展名兜底。
  String _mimeOfAttachment(Attachment a) {
    if (a.mime.isNotEmpty) return a.mime;
    final name = a.name.isNotEmpty ? a.name : a.localPath;
    switch (p.extension(name).toLowerCase()) {
      case '.pdf':
        return 'application/pdf';
      case '.docx':
        return 'application/vnd.openxmlformats-officedocument'
            '.wordprocessingml.document';
      default:
        return 'application/octet-stream';
    }
  }

  /// 孩子端：把本地待上传的计时段推上去。
  ///
  /// 一段计时中途暂停过一次就落一次库，同一个 id 覆盖写，所以这里
  /// patch 到就完事，patch 不到（云端还没有这条）才 insert。
  /// 单段失败不影响别的段，留待下次同步。
  Future<void> _pushSessions() async {
    // 推送前先等计时器把队列里的段写完。否则「退出详情页立刻同步」
    // 会在段还没落库时就把待上传列表读空了，这一段永远传不上去。
    await StudyTimer.instance.idle;
    final pending = await _repo.pendingSessions();
    for (final s in pending) {
      try {
        final fields = {
          'child_id': s.childId,
          'family_id': s.familyId,
          'homework_id': s.homeworkId,
          'date': s.date,
          'subject': s.subject,
          'start_at': s.startAt,
          'end_at': s.endAt,
          'seconds': s.seconds,
          'updated_at': s.updatedAt,
          'is_deleted': false,
        };
        final patched = await _api.patch('homework_sessions', s.id, fields);
        if (patched.isEmpty) {
          await _api.insert('homework_sessions', {
            'id': s.id,
            ...fields,
            'created_at': s.createdAt,
          });
        }
        await _repo.markSessionSynced(s.id);
      } on CloudException catch (e) {
        _noteAuthError(e);
        debugPrint('push session ${s.id} failed: ${e.message}');
      }
    }
  }

  /// 家长端：按日期区间拉孩子的计时段。
  ///
  /// 不放进 [syncAll] 的固定流程里：一次常规同步只该拉「今天」，
  /// 统计页要看一整个月/年时才按需拉对应的区间，避免每次同步都搬半年的数据。
  Future<int> pullSessions({
    required String childId,
    required String from,
    required String to,
  }) async {
    final rows = await _api.selectRaw(
      'homework_sessions',
      'child_id=eq.${Uri.encodeQueryComponent(childId)}'
      '&date=gte.$from&date=lte.$to'
      // 只取用得上的列：年视图一次可能要搬几千行，少几个字段就是几十 KB
      '&select=id,child_id,homework_id,date,subject,'
      'start_at,end_at,seconds,created_at,updated_at,is_deleted',
      limit: 3000,
    );
    for (final r in rows) {
      if ((r['is_deleted'] ?? false) == true) continue;
      await _repo.mergeSessionFromCloud(HomeworkSession(
        id: r['id'] as String,
        childId: r['child_id'] as String,
        homeworkId: (r['homework_id'] ?? '') as String,
        date: (r['date'] ?? '') as String,
        subject: (r['subject'] ?? '') as String,
        startAt: (r['start_at'] as num?)?.toInt() ?? 0,
        endAt: (r['end_at'] as num?)?.toInt(),
        seconds: (r['seconds'] as num?)?.toInt() ?? 0,
        createdAt: (r['created_at'] as num?)?.toInt() ?? 0,
        updatedAt: (r['updated_at'] as num?)?.toInt() ?? 0,
        pendingSync: false,
      ));
    }
    debugPrint('pull sessions ${rows.length} rows ($from ~ $to)');
    return rows.length;
  }

  /// 孩子端：拉某个孩子名下全部作业，合并进本地。
  Future<int> pullHomework(String childId) async {
    final rows = await _api.select(
      'homework',
      query: {'child_id': 'eq.$childId', 'select': '*'},
      limit: 500,
    );
    var n = 0;
    for (final r in rows) {
      await _repo.mergeFromCloud(_fromCloud(r));
      n++;
    }
    return n;
  }

  Homework _fromCloud(Map<String, dynamic> r) {
    final rawImages = r['images'];
    final keys = <String>[];
    if (rawImages is List) {
      for (final e in rawImages) {
        // 空串也要原样占住槽位：云端数组里第 i 项就是第 i 张图，
        // 丢掉空串会让后面的图整体前移，正文里的 [图N] 就指错图了。
        // 而且「这一格云端没有 key」正是本机可能还留着原图的那一格，
        // 一丢就把本机原图也带没了（收尾部的空槽是数据层的事，见 mergeFromCloud）。
        keys.add(e is String ? e : '');
      }
    }
    return Homework(
      id: r['id'] as String,
      childId: r['child_id'] as String,
      familyId: (r['family_id'] as String?) ?? '',
      date: r['date'] as String,
      subject: (r['subject'] ?? '') as String,
      content: (r['content'] ?? '') as String,
      images: const [],
      imageKeys: keys,
      attachments: Attachment.parseList(r['attachments']),
      isDone: (r['is_done'] ?? false) == true,
      doneAt: (r['done_at'] as num?)?.toInt(),
      createdAt: (r['created_at'] as num?)?.toInt() ?? 0,
      updatedAt: (r['updated_at'] as num?)?.toInt() ?? 0,
      isDeleted: (r['is_deleted'] ?? false) == true,
    );
  }

  // 注：原来的 findChildrenInCloud / findFamilyInCloud / findFamilyByCode
  // 已经删掉。它们的前提是「匿名 token 能读全表」，而现在服务端按 token 里的
  // family_id 强制隔离，客户端既查不到别人的家庭码，也没有必要再自己比对。

  /// 拉某个家庭下的孩子名单，并写进本地。
  /// 家长换手机 / 重装后用家庭码接入时靠这条恢复。
  Future<List<Child>> pullChildren(String familyId) async {
    final rows = await _api.select(
      'children',
      query: {'family_id': 'eq.$familyId', 'select': '*'},
      limit: 100,
    );
    final out = <Child>[];
    for (final r in rows) {
      final id = r['id'] as String;
      if ((r['is_deleted'] ?? false) == true) {
        // 云端已有墓碑：本机残留的这条要清掉，否则换设备接入后
        // 已删的孩子会从缓存里「复活」。
        await _repo.removeLocalChild(id);
        continue;
      }
      final c = Child(
        id: id,
        familyId: r['family_id'] as String,
        name: r['name'] as String,
        colorIndex: (r['color_index'] as num?)?.toInt() ?? 0,
        createdAt: (r['created_at'] as num?)?.toInt() ?? 0,
      );
      await _repo.upsertChild(c);
      out.add(c);
    }
    return out;
  }

  /// 家长端一键同步。
  /// [isParent] 决定写内容和拉状态的顺序：家长先推后拉，孩子只拉 + 回传打勾。
  ///
  /// 同一时刻只跑一轮。重复调用会**等当前这轮结束**，而不是直接返回 ——
  /// 否则页面刷新会比拉取先完成，界面上就会出现「明明有作业却显示没有」。
  ///
  /// [pull] 为 false 时只上行不下行。孩子打勾这种高频动作只写两个字段，
  /// 没必要顺带把全部作业再拉一遍——那才是真正白耗流量的地方。
  Future<void> syncAll({
    required bool isParent,
    String? childId,
    Family? family,
    List<Child>? children,
    bool pull = true,
  }) {
    // 排队执行：上一次同步结束后立刻跑这一次，避免并发；
    // 也不吞掉进行中发起的同步请求，否则孩子刚打的勾可能传不上去。
    final next = _chain.then((_) => _doSync(
          isParent: isParent,
          childId: childId,
          family: family,
          children: children,
          pull: pull,
        ));
    _chain = next.catchError((_) {});
    return next;
  }

  Future<void> _doSync({
    required bool isParent,
    String? childId,
    Family? family,
    List<Child>? children,
    bool pull = true,
  }) async {
    final sw = Stopwatch()..start();
    _sawAuthMissing = false;
    _set(SyncPhase.syncing, '同步中…');
    try {
      if (isParent) {
        // 删除必须比档案推送先跑：pushFamilyAndChildren 只遍历还存在的孩子，
        // 已删的那条只能靠墓碑告知云端。
        await _pushChildDeletions();
        _t(sw, 'pushChildDeletions');
        if (family != null) {
          await pushFamilyAndChildren(family, children ?? const []);
          _t(sw, 'pushFamilyAndChildren');
        }
        await _pushHomework(uploadContent: true);
        _t(sw, 'pushHomework');
        // 这台设备如果当过孩子端，本地可能攒了几段没传的计时
        await _pushSessions();
        _t(sw, 'pushSessions');
        if (pull && childId != null) await pullHomework(childId);
        _t(sw, 'pullHomework');
      } else {
        // 孩子端先确认自己没被家长删掉：删了就别再拉数据了，
        // 由 AppState 在同步结束后清掉登录态。
        if (childId != null) await _checkRevoked(childId);
        _t(sw, 'checkRevoked');
        await _pushHomework(uploadContent: false);
        _t(sw, 'pushHomework');
        // 孩子端把刚计的段回传，家长端才看得到耗时
        await _pushSessions();
        _t(sw, 'pushSessions');
        if (pull && childId != null) await pullHomework(childId);
        _t(sw, 'pullHomework');
      }
      lastSuccess = DateTime.now();
      lastFailureWasOffline = false;
      lastFailureWasAuthMissing = false;
      await refreshPending();
      _t(sw, 'refreshPending');
      // 单条失败不会抛异常（一条传不上去不能拖累其它条），所以这里要看残留数：
      // 还有没传上去的就别报「已同步」——否则自动重试永远不会被触发，
      // 那几条会一直挂到用户下一次进来才知道。
      if (pendingCount > 0) {
        // 会话缺失时不能再报「稍后自动重试」：重试一千次也是同样结果，
        // 得让用户看到「要重新登录」这个动作。
        _set(
          SyncPhase.failed,
          _sawAuthMissing
              ? '登录已失效，$pendingCount 条没传上去'
              : '$pendingCount 条没传上去，稍后自动重试',
        );
      } else if (_sawAuthMissing) {
        // 没有待传数据但拉取阶段撞到 401：同样要暴露出来
        _set(SyncPhase.failed, '登录已失效，请重新登录');
      } else {
        _set(SyncPhase.done, '已同步');
      }
    } on CloudException catch (e) {
      lastFailureWasOffline = _api.lastErrorWasNetwork;
      lastFailureWasAuthMissing = e.authMissing;
      await refreshPending();
      _set(SyncPhase.failed, e.message);
    } catch (e) {
      lastFailureWasOffline = false;
      lastFailureWasAuthMissing = false;
      await refreshPending();
      _set(SyncPhase.failed, '同步失败：$e');
    }
  }
}
