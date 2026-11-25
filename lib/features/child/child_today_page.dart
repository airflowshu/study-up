import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/breakpoints.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import '../../core/boot_trace.dart';
import '../../core/utils.dart';
import '../../data/cloud/sync_service.dart';
import '../../data/repository.dart';
import '../../models/models.dart';
import '../../state/study_timer.dart';
import '../../widgets/common.dart';
import '../../widgets/homework_card.dart';
import '../shared/homework_detail_page.dart';

/// 孩子端今日作业：打开就看到今天要做什么，点圆圈打勾。
class ChildTodayPage extends StatefulWidget {
  const ChildTodayPage({
    super.key,
    required this.device,
    required this.child,
  });

  final DeviceType device;
  final Child child;

  @override
  State<ChildTodayPage> createState() => _ChildTodayPageState();
}

class _ChildTodayPageState extends State<ChildTodayPage> {
  final _repo = Repository.instance;
  List<Homework> _items = [];
  bool _loading = true;
  String _syncMsg = '';

  /// 正在跑一次网络刷新。用来给右上角按钮挂「刷新中」状态，并挡住连点。
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    // 先把本地库里的数据画出来，再在后台拉云端。
    //
    // 这里原来是直接 `_refresh()`，而 `_refresh()` 要等整个网络同步跑完
    // 才去读本地库 —— 在「云端往返一秒多」的链路上，等于把「打开就能看到
    // 今天的作业」变成白等好几秒，而数据其实早就存在手机里。
    //
    // 本机一条数据都没有时（新装设备）确实只能等网络，那种情况由
    // `_refresh()` 完成后的第二次 `_load()` 补上，首屏 loading 圈照常显示。
    unawaited(_load());
    // 打开就先拉一次云端：孩子端本机可能一条数据都没有。
    // silent：首帧本来就是 loading 圈，不必再 setState 一次。
    unawaited(_refresh(silent: true));

    // 启动时 AppState 也会自动同步一次，那条链路走完时页面得跟着刷新，
    // 否则刚拉下来的新作业要等用户手动下拉才出现。
    SyncService.instance.addListener(_onSyncChanged);
  }

  /// 任何来源的同步（启动、切回前台、失败重试）完成后，重新读一次本地库。
  ///
  /// 只在 done 时读：syncing / failed 期间读库没有意义，反而让列表闪。
  void _onSyncChanged() {
    if (!mounted) return;
    if (SyncService.instance.phase == SyncPhase.done) {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    SyncService.instance.removeListener(_onSyncChanged);
    super.dispose();
  }

  Future<void> _load() async {
    final rows = await _repo.homeworkByDate(widget.child.id, todayKey());
    bootMark('today list loaded (${rows.length} 条)');
    if (!mounted) return;
    setState(() {
      _items = _sort(rows);
      _loading = false;
    });
  }

  List<Homework> _sort(List<Homework> rows) {
    const order = ['语文', '数学', '英语', '科学', '道法', '体育', '美术', '音乐'];
    int rank(String s) {
      final i = order.indexOf(s);
      return i == -1 ? 99 : i;
    }

    final list = [...rows];
    list.sort((a, b) {
      final r = rank(a.subject).compareTo(rank(b.subject));
      return r != 0 ? r : a.createdAt.compareTo(b.createdAt);
    });
    return list;
  }

  /// 刷新：先从云端拉，再读本地。没网时拉取失败也不影响看缓存。
  ///
  /// [feedback] 为 true（点右上角「刷新」）时结束后弹一句结果——
  /// 没新作业时列表看起来毫无变化，不给回话就会被当成按钮坏了。
  Future<void> _refresh({bool feedback = false, bool silent = false}) async {
    // 连点只跑一次；下拉手势和按钮可能同时触发
    if (_refreshing) return;

    // 启动时 AppState 已经发起过一次自动同步，而 SyncService 内部是串行队列：
    // 这里再排一次不会并行提速，只会把完整流程再跑一遍（实测多花 1.7 秒）。
    // 自动刷新时直接复用正在进行的那次，等它结束由 _onSyncChanged 负责刷新列表。
    // 用户手动点「刷新」则照常排队，那是明确的重试意图。
    if (!feedback && SyncService.instance.phase == SyncPhase.syncing) {
      return;
    }

    _refreshing = true;
    if (!silent && mounted) setState(() {});

    var msg = '';
    try {
      await SyncService.instance
          .syncAll(isParent: false, childId: widget.child.id);
      msg = SyncService.instance.message;
    } catch (_) {
      msg = '刷新失败，检查网络后重试';
    }
    if (!mounted) return;
    setState(() {
      _refreshing = false;
      _syncMsg = msg;
    });
    await _load();

    if (!feedback || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg.isEmpty ? '已刷新' : msg),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// 点卡片 → 整页详情。
  /// 打勾回调给列表，列表和详情页各存一份状态，退出时不会不一致。
  Future<void> _openDetail(Homework hw) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => HomeworkDetailPage(
          homework: hw,
          onToggleDone: (done) => _setDone(hw, done),
          // 孩子端点进未完成的学科就开始计时，界面上不显示任何计时痕迹
          trackTime: true,
        ),
      ),
    );
    if (!mounted) return;
    // 详情页里可能打过勾或刷新过，回来对齐一下列表
    await _load();
    // 退出详情时那一段计时正在落库，必须等它写完再去查「有没有待上传」。
    // 不等的话会查到空列表，这一段的时长就永远传不上去了。
    await StudyTimer.instance.idle;
    if (!await _hasPendingSessions()) return;
    unawaited(SyncService.instance
        .syncAll(isParent: false, childId: widget.child.id, pull: false));
  }

  Future<bool> _hasPendingSessions() async {
    try {
      return (await _repo.pendingSessions()).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// 打勾只回写 isDone / doneAt 两个字段，绝不覆盖家长写的正文。
  Future<void> _toggle(Homework hw) => _setDone(hw, !hw.isDone);

  Future<void> _setDone(Homework hw, bool next) async {
    setState(() {
      final i = _items.indexWhere((e) => e.id == hw.id);
      if (i != -1) {
        _items[i] = hw.copyWith(
          isDone: next,
          doneAt: next ? DateTime.now().millisecondsSinceEpoch : null,
          clearDoneAt: !next,
        );
      }
    });
    await _repo.setDone(hw.id, next);
    // 后台把这两个字段回传，家长端下次同步就能看到已完成。
    // pull: false —— 打勾只要上行，不必把全部作业再拉一遍。
    unawaited(SyncService.instance
        .syncAll(isParent: false, childId: hw.childId, pull: false));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return ListView.separated(
        padding: const EdgeInsets.fromLTRB(
          AppSpace.lg,
          AppSpace.sm,
          AppSpace.lg,
          AppSpace.lg,
        ),
        itemCount: 3,
        separatorBuilder: (_, __) => const SizedBox(height: AppSpace.md),
        itemBuilder: (_, __) => Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(15, 12, 15, 12),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: AppColors.border),
            boxShadow: AppShadow.s1,
          ),
          child: const CardSkeleton(),
        ),
      );
    }

    // 平板上也不分栏：点某一条就整页打开详情，读起来更松快，
    // 图片点开再全屏看。列表本身限宽居中，横屏时不会拉成一条长条。
    //
    // expanded（≥840dp）没有 AppBar，内容直接顶到屏幕边，
    // 这里要自己让出状态栏，否则右上角「刷新」会压在信号/电量图标上。
    return SafeArea(
      top: widget.device == DeviceType.expanded,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          // 整屏共用一个入场控制器：标题先到，卡片按学科顺序依次跟上。
          // 孩子打开就是要看「还剩几科」，所以标题必须第一个落地，
          // 不能等卡片排完才出现。
          child: EntranceGroup(
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: _items.isEmpty
                  ? ListView(
                      children: [
                        Entrance(index: 0, child: _header()),
                        const SizedBox(height: 60),
                        Entrance(
                          index: 1,
                          child: EmptyState(
                            title: '今天还没有布置作业',
                            hint: _syncMsg.isEmpty
                                ? '可以下拉刷新，也可以点右上角「刷新」'
                                : '$_syncMsg · 点「刷新」重试',
                            icon: Icons.wb_sunny_outlined,
                          ),
                        ),
                      ],
                    )
                  : ListView.separated(
                      key: const PageStorageKey('child_today'),
                      padding: const EdgeInsets.fromLTRB(
                        AppSpace.lg,
                        0,
                        AppSpace.lg,
                        AppSpace.xl,
                      ),
                      itemCount: _items.length + 1,
                      separatorBuilder: (_, __) =>
                          const SizedBox(height: AppSpace.md),
                      itemBuilder: (context, i) {
                        if (i == 0) {
                          return Entrance(index: 0, child: _header());
                        }
                        final hw = _items[i - 1];
                        return Entrance(
                          index: i,
                          child: HomeworkCard(
                            homework: hw,
                            onToggleDone: () => _toggle(hw),
                            onTap: () => _openDetail(hw),
                          ),
                        );
                      },
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header() {
    final total = _items.length;
    final done = _items.where((e) => e.isDone).length;
    final left = total - done;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        AppSpace.md,
        AppSpace.lg,
        AppSpace.sm + 2,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      humanDate(DateTime.now()),
                      style: TextStyle(
                        fontSize: AppText.label,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: AppSpace.xs),
                    // 说「还剩几科」而不是「共几科」：孩子关心的是剩下多少活
                    Text(
                      total == 0
                          ? '今天没有作业'
                          : (left == 0 ? '今天全部完成' : '今天还有 $left 科'),
                      style: TextStyle(
                        fontSize: AppText.headline,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpace.md),
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (total > 0) ProgressRing(done: done, total: total),
                  if (total > 0) const SizedBox(height: AppSpace.sm),
                  _refreshButton(),
                ],
              ),
            ],
          ),
          // 全部打完勾要给个交代：否则最后一项点掉后界面毫无变化，
          // 孩子不知道「今天结束了」。
          //
          // 这块是条件挂载的，用 RevealOnMount 而不是 Entrance——
          // 它出现的那一刻整组入场早就跑完了，靠 index 拿不到动画。
          if (total > 0 && left == 0) ...[
            const SizedBox(height: AppSpace.md),
            RevealOnMount(
                offsetY: 6, scaleFrom: 0.97, child: _celebrate(total)),
          ],
        ],
      ),
    );
  }

  Widget _celebrate(int total) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(
        AppSpace.md,
        AppSpace.md,
        AppSpace.md,
        AppSpace.md,
      ),
      decoration: BoxDecoration(
        color: AppColors.successSoft,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.successInk.withValues(alpha: 0.28)),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: AppColors.card,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.check_rounded,
              size: 19,
              color: AppColors.success,
            ),
          ),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '全部完成，太棒了',
                  style: TextStyle(
                    fontSize: AppText.body,
                    fontWeight: FontWeight.w600,
                    color: AppColors.successInk,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$total 科作业都打完勾了',
                  style: TextStyle(
                    fontSize: AppText.caption,
                    color: AppColors.successInk.withValues(alpha: 0.8),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 右上角「刷新」：下拉刷新没人看得出来，给一个明摆着的入口。
  ///
  /// 平板（expanded）没有 AppBar，所以按钮放在页面头部右端而不是 AppBar 的 actions 里，
  /// 三种形态位置一致。
  Widget _refreshButton() {
    final busy = _refreshing;
    return Material(
      color: AppColors.primary.withValues(alpha: busy ? 0.06 : 0.10),
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: busy ? null : () => _refresh(feedback: true),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (busy)
                const SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(
                  Icons.refresh_rounded,
                  size: 17,
                  color: busy ? AppColors.textDisabled : AppColors.primaryInk,
                ),
              const SizedBox(width: 5),
              Text(
                busy ? '刷新中' : '刷新',
                style: TextStyle(
                  fontSize: AppText.label,
                  fontWeight: FontWeight.w600,
                  color: busy ? AppColors.textTertiary : AppColors.primaryInk,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
