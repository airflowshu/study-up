import 'package:flutter/material.dart';

import '../../core/breakpoints.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import '../../core/utils.dart';
import '../../data/cloud/sync_service.dart';
import '../../data/repository.dart';
import '../../models/models.dart';
import '../../state/app_state.dart';
import '../../widgets/common.dart';
import '../../widgets/homework_card.dart';
import '../shared/homework_detail_page.dart';
import 'day_time_detail_page.dart';
import 'homework_edit_page.dart';

/// 家长端首页：按孩子看某一天的布置，点「布置新作业」录入。
///
/// 平板上也不再右侧分栏了：点某一条整页打开详情，图大字大、图片能全屏看，
/// 和手机上的手感一致。列表本身限宽居中，横屏不会被拉成一条长条。
class ParentHomePage extends StatefulWidget {
  const ParentHomePage({super.key, required this.device});

  final DeviceType device;

  @override
  State<ParentHomePage> createState() => _ParentHomePageState();
}

class _ParentHomePageState extends State<ParentHomePage> {
  final _repo = Repository.instance;
  DateTime _date = DateTime.now();
  List<Homework> _items = [];
  bool _loading = true;

  /// 当天各科累计秒数。**只有有记录的学科**才会出现在这里。
  Map<String, int> _duration = {};

  /// 已经为「哪个孩子 + 哪一天」拉过计时记录，避免每次 _load 都打一次网络请求。
  /// 必须带上孩子：多孩子家庭切人时是同一天，但数据是两个人的。
  String? _pulledDate;

  @override
  void initState() {
    super.initState();
    _load();
  }

  int _lastStamp = 0;

  /// 后台同步完成后 syncStamp 会变，这里跟着重新读一次本地库，
  /// 从而看到孩子刚打的勾。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final stamp = AppStateScope.of(context).syncStamp;
    if (stamp != _lastStamp) {
      _lastStamp = stamp;
      // 同步里不拉计时段（那是按需拉的），所以本地库里的时长还是旧的。
      // 清掉「已拉过」的标记，让下面重新拉一次当天的记录，
      // 否则家长看到的是孩子做作业之前的时长。
      _pulledDate = null;
      _load();
    }
  }

  Future<void> _load() async {
    // 入口兜一层：任何路径（同步回调、返回后刷新）在页面已销毁时调用都要安静退出
    if (!mounted) return;
    final state = AppStateScope.read(context);
    final child = state.activeChild;
    if (child == null) {
      setState(() {
        _items = [];
        _duration = {};
        _loading = false;
      });
      return;
    }
    final key = dateKey(_date);
    final pullKey = '${child.id}|$key';

    // 计时记录是孩子那台设备产生的，家长这台只在打开这一天时拉一次。
    // 放在读本地之前：拉回来的会先合并进本地库，接着一次性读出来。
    if (_pulledDate != pullKey) {
      _pulledDate = pullKey;
      try {
        await SyncService.instance.pullSessions(
          childId: child.id,
          from: key,
          to: key,
        );
      } catch (_) {
        // 断网就看本地已有的记录，不阻塞列表
      }
      if (!mounted) return;
    }

    final rows = await _repo.homeworkByDate(child.id, key);
    final duration = await _repo.subjectSecondsOnDate(child.id, key);
    if (!mounted) return;
    setState(() {
      _items = _sorted(rows);
      _duration = duration;
      _loading = false;
    });
  }

  /// 学科按固定顺序排，同科按创建时间，孩子扫读时顺序稳定。
  List<Homework> _sorted(List<Homework> rows) {
    const order = ['语文', '数学', '英语', '科学', '道法', '体育', '美术', '音乐'];
    int rank(String s) {
      final i = order.indexOf(s);
      return i == -1 ? 99 : i;
    }

    final list = [...rows];
    list.sort((a, b) {
      final r = rank(a.subject).compareTo(rank(b.subject));
      if (r != 0) return r;
      return a.createdAt.compareTo(b.createdAt);
    });
    return list;
  }

  Future<void> _openEdit({Homework? existing}) async {
    final child = AppStateScope.read(context).activeChild;
    if (child == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => HomeworkEditPage(
          childId: child.id,
          date: _date,
          existing: existing,
        ),
      ),
    );
    // 保存后编辑页会 pop，此时本页可能已经不在树上（切过角色、被重建过）。
    // 不判 mounted 直接 _load 会拿 State.context 空断言崩掉，
    // 崩在异步里没人接，表现就是「作业发不出去 / 列表不刷新」。
    if (!mounted) return;
    await _load();
  }

  /// 点卡片 → 整页详情。详情页里再点「编辑」进编辑页，
  /// 保存后详情页自己换成新内容，不用退出来重进。
  Future<void> _openDetail(Homework hw) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => HomeworkDetailPage(
          homework: hw,
          onEdit: () async {
            await _openEdit(existing: hw);
            return _repo.homeworkById(hw.id);
          },
        ),
      ),
    );
    if (!mounted) return;
    await _load();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      helpText: '选择日期',
      cancelText: '取消',
      confirmText: '确定',
    );
    if (picked == null) return;
    setState(() {
      _date = picked;
      _loading = true;
    });
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final doneCount = _items.where((e) => e.isDone).length;
    final maxWidth = widget.device == DeviceType.expanded ? 820.0 : 760.0;
    final totalSeconds = _duration.values.fold(0, (sum, v) => sum + v);

    return SafeArea(
      top: false,
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Column(
            children: [
              _Header(
                children: state.children,
                activeChild: state.activeChild,
                date: _date,
                onPickDate: _pickDate,
                onSwitchChild: (id) async {
                  await state.selectChild(id);
                  setState(() => _loading = true);
                  await _load();
                },
              ),
              if (!_loading)
                _ProgressCard(
                  date: _date,
                  total: _items.length,
                  done: doneCount,
                ),
              // 一条时长都没有时整块不出现——不写「今日累计 0 分」，
              // 那会被读成"孩子今天一点没学"。
              if (!_loading && totalSeconds > 0 && state.activeChild != null)
                RevealOnMount(
                  offsetY: 6,
                  child: _TimeSummary(
                    seconds: totalSeconds,
                    subjects: _duration.length,
                    isToday: dateKey(_date) == todayKey(),
                    onTap: () => _openTimeDetail(state.activeChild!),
                  ),
                ),
              Expanded(child: _list()),
              _addButton(),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openTimeDetail(Child child) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DayTimeDetailPage(
          child: child,
          date: dateKey(_date),
        ),
      ),
    );
    if (!mounted) return;
    await _load();
  }

  Widget _list() {
    // 骨架屏而不是裸转圈：首屏等待时看不出「在加载」还是「卡住了」。
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
    if (_items.isEmpty) {
      // 空态不放按钮：底部常驻一个「布置新作业」，再来一个就是俩。
      return EmptyState(
        title: '${humanDate(_date)}还没有布置作业',
        hint: '点下面的「布置新作业」，把老师发的作业录进来',
        icon: Icons.assignment_outlined,
      );
    }
    // 列表自己一组：换日期、换孩子时会先走骨架屏（_loading），
    // 组被销毁重建，入场自然重播；而打完勾后的重排不动 _loading，
    // 组还在，不会一勾就让整屏重新淡入一遍。
    return EntranceGroup(
      child: ListView.separated(
        key: PageStorageKey('parent_home_${dateKey(_date)}'),
        padding: const EdgeInsets.fromLTRB(
          AppSpace.lg,
          AppSpace.sm,
          AppSpace.lg,
          AppSpace.lg,
        ),
        itemCount: _items.length,
        separatorBuilder: (_, __) => const SizedBox(height: AppSpace.md),
        itemBuilder: (context, i) {
          final hw = _items[i];
          return Entrance(
            index: i,
            child: HomeworkCard(
              homework: hw,
              durationSeconds: _duration[hw.subject],
              onTap: () => _openDetail(hw),
              onEdit: () => _openEdit(existing: hw),
            ),
          );
        },
      ),
    );
  }

  Widget _addButton() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        AppSpace.sm + 2,
        AppSpace.lg,
        AppSpace.md + 2,
      ),
      child: PrimaryAction(
        label: '布置新作业',
        icon: Icons.add,
        onPressed: () => _openEdit(),
      ),
    );
  }
}

/// 今日进度卡：把「已完成 2/5 科」从一行 12px 灰字做成带进度条的独立卡。
/// 这是家长打开 App 最想知道的事，不该藏在头部第二行。
class _ProgressCard extends StatelessWidget {
  const _ProgressCard({
    required this.date,
    required this.total,
    required this.done,
  });

  final DateTime date;
  final int total;
  final int done;

  @override
  Widget build(BuildContext context) {
    final ratio = total == 0 ? 0.0 : done / total;
    // 数据到位后才挂上来，所以这里用 RevealOnMount：骨架屏退场、
    // 进度卡补位的那一刻有一次淡入，读起来是「数据到了」而不是「闪了一下」。
    return RevealOnMount(
      offsetY: 6,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpace.lg,
          0,
          AppSpace.lg,
          AppSpace.md,
        ),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(
            AppSpace.lg,
            AppSpace.md + 2,
            AppSpace.lg,
            AppSpace.md + 2,
          ),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: AppColors.border),
            boxShadow: AppShadow.s1,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    humanDate(date),
                    style: TextStyle(
                      fontSize: AppText.body,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const Spacer(),
                  RichText(
                    text: TextSpan(
                      style: TextStyle(
                        fontSize: AppText.label,
                        color: AppColors.textTertiary,
                      ),
                      children: [
                        const TextSpan(text: '已完成 '),
                        TextSpan(
                          text: '$done',
                          style: TextStyle(
                            fontSize: AppText.body,
                            fontWeight: FontWeight.w700,
                            color: AppColors.primaryInk,
                          ),
                        ),
                        TextSpan(text: '/$total 科'),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpace.sm + 2),
              // 进度条要「走过去」而不是「跳过去」：家长看的是比值，
              // 跳变会被读成「数字重算了 / 数据不对」。
              //
              // 这条 tween 的 begin 固定 0，首帧从 0 涨到当前值——
              // 数据刚到的时候正好是一次「今天已经做到这儿了」的说明。
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: total == 0 ? 0 : ratio),
                duration: AppMotion.reduced(context)
                    ? Duration.zero
                    : AppMotion.progress,
                curve: AppMotion.easeOutQuint,
                builder: (context, v, _) {
                  final greenT = ((v - 0.9) / 0.1).clamp(0.0, 1.0);
                  return ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadius.full),
                    child: LinearProgressIndicator(
                      value: v,
                      minHeight: 6,
                      backgroundColor: AppColors.surface3,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        Color.lerp(
                            AppColors.primary, AppColors.success, greenT)!,
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.children,
    required this.activeChild,
    required this.date,
    required this.onPickDate,
    required this.onSwitchChild,
  });

  final List<Child> children;
  final Child? activeChild;
  final DateTime date;
  final VoidCallback onPickDate;
  final ValueChanged<String> onSwitchChild;

  @override
  Widget build(BuildContext context) {
    final isToday = dateKey(date) == todayKey();
    return Container(
      color: AppColors.pageBg,
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        AppSpace.md,
        AppSpace.lg,
        AppSpace.sm + 2,
      ),
      child: Row(
        children: [
          // 孩子切换：多孩子家庭在这里换人
          if (children.length > 1)
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final c in children)
                      Padding(
                        padding: const EdgeInsets.only(right: AppSpace.sm),
                        child: _ChildChip(
                          child: c,
                          selected: c.id == activeChild?.id,
                          onTap: () => onSwitchChild(c.id),
                        ),
                      ),
                  ],
                ),
              ),
            )
          else
            Expanded(
              child: Text(
                activeChild?.name ?? '',
                style: TextStyle(
                  fontSize: AppText.body,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
          Material(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(AppRadius.full),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onPickDate,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpace.md,
                  vertical: AppSpace.xs + 3,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.calendar_today_outlined,
                      size: 14,
                      color: AppColors.primaryInk,
                    ),
                    const SizedBox(width: AppSpace.xs + 2),
                    Text(
                      isToday ? '今天' : humanDate(date),
                      style: TextStyle(
                        fontSize: AppText.label,
                        fontWeight: FontWeight.w600,
                        color: AppColors.primaryInk,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 「今日累计 46 分 → 明细」汇总条（原型 B 顶部那条）。
class _TimeSummary extends StatelessWidget {
  const _TimeSummary({
    required this.seconds,
    required this.subjects,
    required this.isToday,
    required this.onTap,
  });

  final int seconds;
  final int subjects;
  final bool isToday;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        0,
        AppSpace.lg,
        AppSpace.md,
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadius.md),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.md,
              AppSpace.md,
              AppSpace.md,
              AppSpace.md,
            ),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [AppColors.gradientA, AppColors.gradientB],
              ),
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(color: AppColors.primaryBorder),
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: AppColors.card,
                    borderRadius: BorderRadius.circular(AppRadius.md - 2),
                    boxShadow: AppShadow.s1,
                  ),
                  child: Icon(
                    Icons.schedule,
                    size: 18,
                    color: AppColors.primaryInk,
                  ),
                ),
                const SizedBox(width: AppSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        formatDuration(seconds),
                        style: TextStyle(
                          fontSize: AppText.body,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        '${isToday ? '今日' : '当日'}累计 · $subjects 科有记录',
                        style: TextStyle(
                          fontSize: AppText.caption,
                          color: AppColors.textTertiary,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  '明细',
                  style: TextStyle(
                    fontSize: AppText.label,
                    fontWeight: FontWeight.w600,
                    color: AppColors.primaryInk,
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: AppColors.primaryInk,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ChildChip extends StatelessWidget {
  const _ChildChip({
    required this.child,
    required this.selected,
    required this.onTap,
  });

  final Child child;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = AppColors
        .childPalette[child.colorIndex % AppColors.childPalette.length];
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.14) : AppColors.surface2,
          borderRadius: BorderRadius.circular(AppRadius.full),
          border: Border.all(
            color: selected ? color.withValues(alpha: 0.5) : AppColors.border,
          ),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 9,
              backgroundColor: color.withValues(alpha: 0.2),
              child: Text(
                childInitial(child.name),
                style: TextStyle(
                  fontSize: 10,
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              child.name,
              style: TextStyle(
                fontSize: AppText.label,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected ? color : AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
