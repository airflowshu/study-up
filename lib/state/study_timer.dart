import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:uuid/uuid.dart';

import '../data/repository.dart';
import '../models/models.dart';

/// 作业耗时计时器。
///
/// 只在**孩子端**、且作业**还没打勾**的时候跑。孩子端界面上一律不显示，
/// 所以这里刻意不继承 ChangeNotifier、不对外暴露「已用多久」——
/// 唯一的出口是退出时写进本地库的那一段 [HomeworkSession]。
///
/// 三条规则（与需求说明书第 19 章一致）：
/// - 切后台、锁屏：暂停。刷手机的时间不该算成做作业
/// - 单段超过 120 分钟：截断。防的是「打开后忘了关，跑一整天」
/// - 按 10 秒粒度累加：不足 10 秒的匆匆一瞥不留记录，避免脏数据
///
/// **落库必须串行**：一段计时会因为切后台暂停而多次写库，最后退出时再写一次，
/// 收尾那次写的秒数最多。如果这些写并发执行，「中途那次的旧值」可能后完成、
/// 把最终值覆盖掉，段就白记了。所以所有写都挂在 [_chain] 这条 Future 链上，
/// 按调用顺序一个个来。
class StudyTimer with WidgetsBindingObserver {
  StudyTimer._() {
    WidgetsBinding.instance.addObserver(this);
  }

  static final StudyTimer instance = StudyTimer._();

  /// 累加粒度（秒）。低于这个数的停留不写库。
  static const int granularity = 10;

  /// 单段上限（秒）。
  static const int maxSeconds = 120 * 60;

  static const _uuid = Uuid();
  final _repo = Repository.instance;

  /// 时钟。默认走系统时间；测试里换成假的，
  /// 这样「停留了 60 秒」不用真的等 60 秒，测试才能跑得快。
  @visibleForTesting
  DateTime Function() clock = DateTime.now;

  /// 落库出口。默认写本地库；测试里换成收集器，
  /// 断言「到底写了哪几段」而不是去查数据库。
  @visibleForTesting
  Future<void> Function(HomeworkSession session)? sessionWriter;

  /// 当前时刻（毫秒）。所有时间取用都走这里，不直接调 DateTime.now()。
  int _nowMs() => clock().millisecondsSinceEpoch;

  /// 把计时器恢复到初始状态。**只给测试用**——
  /// 它会丢掉当前这一段，不落库。
  @visibleForTesting
  void resetForTest() {
    _id = null;
    _childId = null;
    _familyId = null;
    _homeworkId = null;
    _date = null;
    _subject = null;
    _startAt = 0;
    _accumMs = 0;
    _resumedAt = null;
    _chain = Future<void>.value();
  }

  /// 当前这一段的身份。**只在计时中非空**。
  String? _id;
  String? _childId;
  String? _familyId;
  String? _homeworkId;
  String? _date;
  String? _subject;

  /// 本段的起始时刻（毫秒）。
  int _startAt = 0;

  /// 已经累计的毫秒数（不含正在跑的那一段）。
  int _accumMs = 0;

  /// 当前这次「前台停留」的起始时刻（毫秒）。暂停时置 null。
  int? _resumedAt;

  /// 落库队列。所有写按顺序排队，杜绝并发覆盖。
  Future<void> _chain = Future<void>.value();

  bool get isRunning => _id != null;

  /// 等所有待写落库完成。
  ///
  /// 调用方（比如孩子端退出详情后要判断「有没有新记录要上传」）必须等这个，
  /// 否则可能在写库之前就去查，得到「没有待上传」的结论，这段时长就永远传不上去了。
  Future<void> get idle => _chain;

  /// 开始一段。作业已完成、或已经在计时，直接忽略。
  void start(Homework hw) {
    if (hw.isDone || _id != null) return;
    final now = _nowMs();
    _id = _uuid.v4();
    _childId = hw.childId;
    _familyId = hw.familyId;
    _homeworkId = hw.id;
    _date = hw.date;
    _subject = hw.subject;
    _startAt = now;
    _accumMs = 0;
    _resumedAt = now;
  }

  /// 结束本段并落库。返回写进去的秒数（0 表示太短或压根没在计时）。
  ///
  /// **状态同步摘掉**：`_id` 等字段在返回前就清空，不等落库完成。
  /// 否则「退出详情 → 立刻点进另一科」会因为上一段还没停干净而拒绝计时，
  /// 那一科就完全记不到。
  Future<int> stop() {
    final id = _id;
    if (id == null) return Future<int>.value(0);

    // 先冻结这一段的数据，再把当前状态清空。
    final snap = _Snapshot(
      id: id,
      childId: _childId!,
      familyId: _familyId ?? '',
      homeworkId: _homeworkId!,
      date: _date!,
      subject: _subject!,
      startAt: _startAt,
      accumMs: _accumMs,
      resumedAt: _resumedAt,
    );

    _id = null;
    _childId = null;
    _familyId = null;
    _homeworkId = null;
    _date = null;
    _subject = null;
    _accumMs = 0;
    _resumedAt = null;

    return _enqueue(snap, finalStop: true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_id == null) return;
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _pause();
      case AppLifecycleState.resumed:
        _resume();
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        // inactive 在拉通知栏、来电、iOS 控制中心都会闪一下，
        // 拿它当暂停会让时长碎成一地；真正的暂停看 paused/hidden。
        break;
    }
  }

  void _pause() {
    if (_resumedAt == null) return;
    _accumMs += _nowMs() - _resumedAt!;
    _resumedAt = null;
    // 立刻落一次库：进程在后台被系统杀掉时，这段时长不至于白数字化。
    // 走同一条队列，收尾那次写一定排在它后面，最终值不会被它盖掉。
    _enqueue(_snapshotNow(), finalStop: false);
  }

  void _resume() {
    if (_id == null || _resumedAt != null) return;
    _resumedAt = _nowMs();
  }

  _Snapshot _snapshotNow() => _Snapshot(
        id: _id!,
        childId: _childId!,
        familyId: _familyId ?? '',
        homeworkId: _homeworkId!,
        date: _date!,
        subject: _subject!,
        startAt: _startAt,
        accumMs: _accumMs,
        resumedAt: _resumedAt,
      );

  /// 把一次写库挂到队列尾部，返回这次写入的秒数。
  ///
  /// 秒数和结束时刻在**入队那一刻**就算好，不能等到真正写的时候再算：
  /// 排队期间可能还夹着别的写入，等轮到自己时已经过去好几秒，
  /// 那几秒会被错算进孩子的作业时长里。
  Future<int> _enqueue(_Snapshot snap, {required bool finalStop}) {
    final completer = Completer<int>();
    final now = _nowMs();
    final seconds = effectiveSeconds(
      accumMs: snap.accumMs,
      resumedAt: snap.resumedAt,
      nowMs: now,
      capSeconds: maxSeconds,
      granularity: granularity,
    );
    _chain = _chain.then((_) async {
      if (seconds > 0) {
        final session = HomeworkSession(
          id: snap.id,
          childId: snap.childId,
          familyId: snap.familyId,
          homeworkId: snap.homeworkId,
          date: snap.date,
          subject: snap.subject,
          startAt: snap.startAt,
          // 非收尾那次的 end_at 留空，表示「这段还没结束」
          endAt: finalStop ? now : null,
          seconds: seconds,
          createdAt: snap.startAt,
          updatedAt: now,
          pendingSync: true,
        );
        final writer = sessionWriter;
        if (writer != null) {
          await writer(session);
        } else {
          await _repo.upsertSession(session);
        }
      }
      completer.complete(seconds);
    }).catchError((_) {
      // 写库失败不能让整条链断掉——后面还有段要写。
      if (!completer.isCompleted) completer.complete(0);
    });
    return completer.future;
  }

  /// 有效秒数：已累计的 + 还在跑的，并按上限截断、按粒度向下取整。
  ///
  /// 抽成纯函数是为了能直接单测——这是整个功能里最容易算错的地方。
  @visibleForTesting
  static int effectiveSeconds({
    required int accumMs,
    required int? resumedAt,
    required int nowMs,
    int capSeconds = maxSeconds,
    int granularity = granularity,
  }) {
    var ms = accumMs;
    if (resumedAt != null) ms += nowMs - resumedAt;
    final capMs = capSeconds * 1000;
    if (ms > capMs) ms = capMs;
    if (ms <= 0) return 0;
    return (ms ~/ 1000) ~/ granularity * granularity;
  }
}

/// 一次写库所需的数据快照。
///
/// 冻结成不可变对象，是为了让它能安全地排队等写——等待期间当前段可能已经变了。
class _Snapshot {
  final String id;
  final String childId;
  final String familyId;
  final String homeworkId;
  final String date;
  final String subject;
  final int startAt;
  final int accumMs;
  final int? resumedAt;

  const _Snapshot({
    required this.id,
    required this.childId,
    required this.familyId,
    required this.homeworkId,
    required this.date,
    required this.subject,
    required this.startAt,
    required this.accumMs,
    required this.resumedAt,
  });
}
