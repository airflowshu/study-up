import 'package:flutter/material.dart';

import '../../core/breakpoints.dart';
import '../../core/theme.dart';
import '../../core/utils.dart';
import '../../data/cloud/sync_service.dart';
import '../../data/repository.dart';
import '../../models/models.dart';
import '../../state/app_state.dart';
import '../../widgets/common.dart';
import 'day_time_detail_page.dart';

/// 家长端 · 统计（原型 D、E）。
///
/// 日 / 月 / 年三种粒度 + 「本月 / 本年 / 自定义」三个快捷口径。
/// 时长只统计**有记录**的学科和日期，没有记录不写 0——
/// 「0 分钟」会让家长误以为孩子一点没学，而实际可能只是没打开过页面。
class ParentStatsPage extends StatefulWidget {
  const ParentStatsPage({super.key, required this.device});

  final DeviceType device;

  @override
  State<ParentStatsPage> createState() => _ParentStatsPageState();
}

enum _Mode { day, month, year }

class _ParentStatsPageState extends State<ParentStatsPage> {
  final _repo = Repository.instance;

  _Mode _mode = _Mode.month;

  /// 当前锚点。日模式看它的日期，月模式看它的年月，年模式看它的年份。
  DateTime _anchor = DateTime.now();

  /// 自定义区间（含两端）。非空时优先于 [_mode] / [_anchor]。
  String? _customFrom;
  String? _customTo;

  Map<String, int> _bySubject = {};
  Map<String, int> _byDay = {};
  Map<String, Set<String>> _subjectsPerDay = {};
  bool _loading = true;
  bool _showAllDays = false;

  /// 已加载区间，切页回来没变就不重复拉网络。
  String _loadedRange = '';
  String _loadedChild = '';

  Child? get _child => AppStateScope.of(context).activeChild;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  // ---------------- 区间 ----------------

  String get _from {
    if (_customFrom != null) return _customFrom!;
    switch (_mode) {
      case _Mode.day:
        return dateKey(_anchor);
      case _Mode.month:
        return dateKey(DateTime(_anchor.year, _anchor.month, 1));
      case _Mode.year:
        return dateKey(DateTime(_anchor.year, 1, 1));
    }
  }

  String get _to {
    if (_customTo != null) return _customTo!;
    switch (_mode) {
      case _Mode.day:
        return dateKey(_anchor);
      case _Mode.month:
        // 用次月第 0 天拿到本月最后一天，免去大小月判断
        return dateKey(DateTime(_anchor.year, _anchor.month + 1, 0));
      case _Mode.year:
        return dateKey(DateTime(_anchor.year, 12, 31));
    }
  }

  String get _rangeLabel {
    if (_customFrom != null) return '$_customFrom 至 $_customTo';
    switch (_mode) {
      case _Mode.day:
        return '${_anchor.year} 年 ${_anchor.month} 月 ${_anchor.day} 日';
      case _Mode.month:
        return monthLabel(_anchor);
      case _Mode.year:
        return '${_anchor.year} 年';
    }
  }

  String get _totalLabel {
    if (_customFrom != null) return '区间总耗时';
    switch (_mode) {
      case _Mode.day:
        return '当日总耗时';
      case _Mode.month:
        return '本月总耗时';
      case _Mode.year:
        return '本年总耗时';
    }
  }

  int get _totalSeconds => _bySubject.values.fold(0, (sum, v) => sum + v);

  // ---------------- 数据 ----------------

  Future<void> _load({bool force = false}) async {
    final child = _child;
    if (child == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final from = _from;
    final to = _to;
    final key = '${child.id}|$from|$to';
    if (!force && key == _loadedRange && _loadedChild == child.id) return;

    if (mounted) setState(() => _loading = true);

    // 计时记录在孩子那台设备上，这里按当前区间拉一次。
    // 日视图是一天、年视图是一年，都只发一条请求。
    try {
      await SyncService.instance
          .pullSessions(childId: child.id, from: from, to: to);
    } catch (_) {
      // 断网就用本地已有的，不拦页面
    }

    final bySubject = await _repo.subjectSecondsInRange(child.id, from, to);
    final byDay = await _repo.daySecondsInRange(child.id, from, to);
    final perDay = await _repo.subjectsPerDayInRange(child.id, from, to);
    if (!mounted) return;
    setState(() {
      _bySubject = bySubject;
      _byDay = byDay;
      _subjectsPerDay = perDay;
      _loading = false;
      _loadedRange = key;
      _loadedChild = child.id;
      _showAllDays = false;
    });
  }

  // ---------------- 交互 ----------------

  void _shift(int delta) {
    setState(() {
      _customFrom = null;
      _customTo = null;
      switch (_mode) {
        case _Mode.day:
          _anchor = _anchor.add(Duration(days: delta));
        case _Mode.month:
          _anchor = DateTime(_anchor.year, _anchor.month + delta, 1);
        case _Mode.year:
          _anchor = DateTime(_anchor.year + delta, 1, 1);
      }
    });
    _load(force: true);
  }

  void _selectMode(_Mode m) {
    setState(() {
      _mode = m;
      _customFrom = null;
      _customTo = null;
      _anchor = DateTime.now();
    });
    _load(force: true);
  }

  void _thisMonth() {
    setState(() {
      _mode = _Mode.month;
      _anchor = DateTime.now();
      _customFrom = null;
      _customTo = null;
    });
    _load(force: true);
  }

  void _thisYear() {
    setState(() {
      _mode = _Mode.year;
      _anchor = DateTime.now();
      _customFrom = null;
      _customTo = null;
    });
    _load(force: true);
  }

  bool get _isThisMonth =>
      _customFrom == null &&
      _mode == _Mode.month &&
      _anchor.year == DateTime.now().year &&
      _anchor.month == DateTime.now().month;

  bool get _isThisYear =>
      _customFrom == null &&
      _mode == _Mode.year &&
      _anchor.year == DateTime.now().year;

  Future<void> _openCustom() async {
    final picked = await showModalBottomSheet<({String from, String to})>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _CustomRangeSheet(from: _from, to: _to),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _customFrom = picked.from;
      _customTo = picked.to;
    });
    _load(force: true);
  }

  // ---------------- 界面 ----------------

  @override
  Widget build(BuildContext context) {
    final child = _child;
    if (child == null) {
      return const EmptyState(
        title: '还没有孩子档案',
        hint: '先在设置里添加孩子，才能看到作业耗时',
        icon: Icons.person_outline,
      );
    }
    final wide = widget.device == DeviceType.expanded;
    final maxWidth = wide ? 820.0 : 760.0;

    return SafeArea(
      top: wide,
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: RefreshIndicator(
            onRefresh: () => _load(force: true),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
              children: [
                _ModeSelector(mode: _mode, onChanged: _selectMode),
                const SizedBox(height: AppSpace.md),
                _RangeBar(
                  label: _rangeLabel,
                  sub: '$_from 至 $_to',
                  onPrev: () => _shift(-1),
                  onNext: () => _shift(1),
                ),
                const SizedBox(height: AppSpace.sm + 2),
                Row(
                  children: [
                    _QuickChip(
                      label: '本月',
                      active: _isThisMonth,
                      onTap: _thisMonth,
                    ),
                    const SizedBox(width: AppSpace.sm),
                    _QuickChip(
                      label: '本年',
                      active: _isThisYear,
                      onTap: _thisYear,
                    ),
                    const SizedBox(width: AppSpace.sm),
                    _QuickChip(
                      label: '自定义',
                      active: _customFrom != null,
                      onTap: _openCustom,
                    ),
                  ],
                ),
                const SizedBox(height: AppSpace.lg),
                if (_loading) ...[
                  const Padding(
                    padding: EdgeInsets.only(top: AppSpace.xl),
                    child: CardSkeleton(),
                  ),
                  const SizedBox(height: AppSpace.xl),
                  const CardSkeleton(),
                ]
                else if (_bySubject.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 50),
                    child: EmptyState(
                      title: '这段时间还没有计时记录',
                      hint: '孩子点开未完成的学科时会自动累计，家长端才看得到',
                      icon: Icons.bar_chart_rounded,
                    ),
                  )
                else ...[
                  _hero(),
                  const SizedBox(height: 20),
                  const _SectionTitle('按学科'),
                  const SizedBox(height: 2),
                  ..._subjectBars(),
                  if (_byDay.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    const _SectionTitle('按天'),
                    const SizedBox(height: 6),
                    _dayList(),
                  ],
                  if (_mode == _Mode.day && _customFrom == null) ...[
                    const SizedBox(height: 16),
                    _detailLink(child),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _hero() {
    final days = _byDay.length;
    final avg = days == 0 ? 0 : _totalSeconds ~/ days;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.gradientA, AppColors.gradientB],
        ),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.primaryBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _totalLabel,
            style: TextStyle(
              fontSize: 12,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 6),
          DurationHeadline(seconds: _totalSeconds),
          const SizedBox(height: 8),
          Text(
            days == 0
                ? '暂无记录'
                : '$days 天有记录 · 日均 ${formatDuration(avg)}',
            style: TextStyle(
              fontSize: 12,
              color: AppColors.textTertiary,
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _subjectBars() {
    final entries = _bySubject.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final maxSeconds = entries.isEmpty ? 1 : entries.first.value;
    final total = _totalSeconds;
    return [
      for (final e in entries)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  SubjectTag(subject: e.key, dense: true),
                  const Spacer(),
                  Text(
                    formatDuration(e.value),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(width: AppSpace.sm),
                  // 百分比固定列宽右对齐：三行数字的个位竖着排成一条线
                  SizedBox(
                    width: 34,
                    child: Text(
                      '${total == 0 ? 0 : (e.value / total * 100).round()}%',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontSize: AppText.caption,
                        color: AppColors.textTertiary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 7),
              ClipRRect(
                // 全圆角：细条在高 DPI 上两端容易糊成方角
                borderRadius: BorderRadius.circular(AppRadius.full),
                child: LinearProgressIndicator(
                  value: maxSeconds == 0 ? 0 : (e.value / maxSeconds),
                  minHeight: 8,
                  backgroundColor: AppColors.surface3,
                  valueColor:
                      AlwaysStoppedAnimation<Color>(AppColors.ofSubject(e.key)),
                ),
              ),
            ],
          ),
        ),
    ];
  }

  Widget _dayList() {
    final entries = _byDay.entries.toList()
      ..sort((a, b) => b.key.compareTo(a.key));
    final showAll = _showAllDays || entries.length <= 3;
    final visible = showAll ? entries : entries.take(3).toList();

    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadow.s1,
      ),
      child: Column(
        children: [
          for (var i = 0; i < visible.length; i++) ...[
            if (i > 0)
              const Divider(
                height: 1,
                indent: AppSpace.md + 2,
                endIndent: AppSpace.md + 2,
              ),
            _DayRow(
              date: visible[i].key,
              seconds: visible[i].value,
              subjectCount: _subjectsPerDay[visible[i].key]?.length ?? 0,
              onTap: () => _openDay(visible[i].key),
            ),
          ],
          if (!showAll) ...[
            const Divider(height: 1, indent: 14, endIndent: 14),
            InkWell(
              onTap: () => setState(() => _showAllDays = true),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Text(
                      '查看全部 ${entries.length} 天',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.seed,
                      ),
                    ),
                    const Spacer(),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 16,
                      color: AppColors.seed,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _detailLink(Child child) {
    return Center(
      child: TextButton.icon(
        onPressed: () => _openDay(dateKey(_anchor)),
        icon: const Icon(Icons.schedule, size: 16),
        label: const Text('查看当日明细'),
      ),
    );
  }

  Future<void> _openDay(String date) async {
    final child = _child;
    if (child == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DayTimeDetailPage(child: child, date: date),
      ),
    );
  }
}

// ---------------- 小部件 ----------------

class _ModeSelector extends StatelessWidget {
  const _ModeSelector({required this.mode, required this.onChanged});

  final _Mode mode;
  final ValueChanged<_Mode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: BorderRadius.circular(AppRadius.md - 2),
      ),
      child: Row(
        children: [
          for (final (label, m) in [
            ('日', _Mode.day),
            ('月', _Mode.month),
            ('年', _Mode.year),
          ])
            Expanded(
              child: GestureDetector(
                onTap: () => onChanged(m),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: mode == m ? AppColors.card : Colors.transparent,
                    borderRadius: BorderRadius.circular(AppRadius.sm - 1),
                    boxShadow: mode == m ? AppShadow.s1 : null,
                  ),
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: AppText.label,
                      fontWeight:
                          mode == m ? FontWeight.w700 : FontWeight.w500,
                      color: mode == m
                          ? AppColors.textPrimary
                          : AppColors.textSecondary,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _RangeBar extends StatelessWidget {
  const _RangeBar({
    required this.label,
    required this.sub,
    required this.onPrev,
    required this.onNext,
  });

  final String label;
  final String sub;
  final VoidCallback onPrev;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.md,
        vertical: AppSpace.sm + 2,
      ),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadow.s1,
      ),
      child: Row(
        children: [
          _Chev(icon: Icons.chevron_left_rounded, onTap: onPrev),
          Expanded(
            child: Column(
              children: [
                Text(
                  label,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: AppText.body,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  sub,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: AppText.caption,
                    color: AppColors.textTertiary,
                  ),
                ),
              ],
            ),
          ),
          _Chev(icon: Icons.chevron_right_rounded, onTap: onNext),
        ],
      ),
    );
  }
}

class _Chev extends StatelessWidget {
  const _Chev({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkResponse(
      onTap: onTap,
      radius: 22,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Icon(icon, size: 22, color: AppColors.textSecondary),
      ),
    );
  }
}

class _QuickChip extends StatelessWidget {
  const _QuickChip({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: active ? AppColors.primary : AppColors.card,
      shape: StadiumBorder(
        side: BorderSide(
          color: active ? AppColors.primary : AppColors.border,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          child: Text(
            label,
            style: TextStyle(
              fontSize: AppText.label,
              fontWeight: FontWeight.w600,
              color: active ? AppColors.onAccent : AppColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: AppColors.textSecondary,
        ),
      ),
    );
  }
}

class _DayRow extends StatelessWidget {
  const _DayRow({
    required this.date,
    required this.seconds,
    required this.subjectCount,
    required this.onTap,
  });

  final String date;
  final int seconds;
  final int subjectCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final d = parseDateKey(date);
    final weekday = const ['一', '二', '三', '四', '五', '六', '日'][d.weekday - 1];
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(
          children: [
            Text(
              '${d.month}月${d.day}日',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '周$weekday · $subjectCount 科',
              style: TextStyle(
                fontSize: 11,
                color: AppColors.textTertiary,
              ),
            ),
            const Spacer(),
            Text(
              formatDuration(seconds),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 16,
              color: AppColors.textTertiary,
            ),
          ],
        ),
      ),
    );
  }
}

/// 自定义时间范围（原型 E）。日期选择 + 4 个常用区间。
class _CustomRangeSheet extends StatefulWidget {
  const _CustomRangeSheet({required this.from, required this.to});

  final String from;
  final String to;

  @override
  State<_CustomRangeSheet> createState() => _CustomRangeSheetState();
}

class _CustomRangeSheetState extends State<_CustomRangeSheet> {
  late DateTime _from = parseDateKey(widget.from);
  late DateTime _to = parseDateKey(widget.to);

  Future<void> _pick(bool isFrom) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: isFrom ? _from : _to,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      helpText: isFrom ? '开始日期' : '结束日期',
      cancelText: '取消',
      confirmText: '确定',
    );
    if (picked == null) return;
    setState(() {
      if (isFrom) {
        _from = picked;
        if (_to.isBefore(_from)) _to = _from;
      } else {
        _to = picked;
        if (_to.isBefore(_from)) _from = _to;
      }
    });
  }

  void _preset(String name) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    late DateTime from;
    late DateTime to;
    switch (name) {
      case '近 7 天':
        from = today.subtract(const Duration(days: 6));
        to = today;
      case '近 30 天':
        from = today.subtract(const Duration(days: 29));
        to = today;
      case '本学期':
        // 9 月之后算秋季学期，否则算春季学期（2 月开学）
        from = now.month >= 9
            ? DateTime(now.year, 9, 1)
            : DateTime(now.year, 2, 1);
        to = today;
      default: // 暑假
        from = DateTime(now.month >= 7 ? now.year : now.year - 1, 7, 1);
        to = DateTime(from.year, 8, 31);
    }
    setState(() {
      _from = from;
      _to = to.isAfter(today) ? today : to;
      if (_to.isBefore(_from)) _to = _from;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 18),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.borderStrong,
                  borderRadius: BorderRadius.circular(AppRadius.xs),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              '自定义时间范围',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 14),
            _Field(
              label: '开始日期',
              value: dateKey(_from),
              onTap: () => _pick(true),
            ),
            const SizedBox(height: 8),
            _Field(
              label: '结束日期',
              value: dateKey(_to),
              onTap: () => _pick(false),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final p in ['近 7 天', '近 30 天', '本学期', '暑假'])
                  _QuickChip(
                    label: p,
                    active: false,
                    onTap: () => _preset(p),
                  ),
              ],
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(46),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                      ),
                    ),
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    onPressed: () => Navigator.of(context).pop(
                      (from: dateKey(_from), to: dateKey(_to)),
                    ),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(46),
                    ),
                    child: const Text('查看统计'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(
          color: AppColors.surface2,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: AppColors.textSecondary,
              ),
            ),
            const Spacer(),
            Text(
              value,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(width: 6),
            Icon(
              Icons.calendar_today_outlined,
              size: 14,
              color: AppColors.textTertiary,
            ),
          ],
        ),
      ),
    );
  }
}
