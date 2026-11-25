import 'dart:async';

import 'package:flutter/material.dart';
import 'package:table_calendar/table_calendar.dart';

import '../../core/breakpoints.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import '../../core/utils.dart';
import '../../data/cloud/sync_service.dart';
import '../../data/repository.dart';
import '../../models/models.dart';
import '../../widgets/common.dart';
import '../../widgets/homework_card.dart';
import '../shared/homework_detail_page.dart';

/// 孩子端日历：有作业的日期打点，点某天看那天的作业。
class ChildCalendarPage extends StatefulWidget {
  const ChildCalendarPage({
    super.key,
    required this.device,
    required this.child,
  });

  final DeviceType device;
  final Child child;

  @override
  State<ChildCalendarPage> createState() => _ChildCalendarPageState();
}

class _ChildCalendarPageState extends State<ChildCalendarPage> {
  final _repo = Repository.instance;
  DateTime _focused = DateTime.now();
  DateTime _selected = DateTime.now();
  Set<String> _marked = {};
  List<Homework> _dayItems = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadMarks(_focused.year, _focused.month);
    _loadDay(_selected);
  }

  Future<void> _loadMarks(int year, int month) async {
    final set = await _repo.datesWithHomework(widget.child.id, year, month);
    if (!mounted) return;
    setState(() => _marked = set);
  }

  Future<void> _loadDay(DateTime day) async {
    final rows = await _repo.homeworkByDate(widget.child.id, dateKey(day));
    if (!mounted) return;
    setState(() {
      _dayItems = rows;
      _loading = false;
    });
  }

  /// 点卡片 → 整页详情。
  ///
  /// 卡片正文固定三行摘要（列表本来也放不下长作业），之前这里没接 onTap，
  /// 点上去毫无反应，家长写了大段文字孩子根本看不全。详情页按图文混排铺开，
  /// 图片还能点开全屏。
  ///
  /// 不传 trackTime：日历是**回看**场景，翻前几天的作业不该产生学习时长，
  /// 否则家长统计里会凭空多出几分钟。计时只在「今日」页做。
  Future<void> _openDetail(Homework hw) async {
    // 记下当前选中的日期：详情页停留期间 _selected 理论上不会变，
    // 但返回后要按「当初点的是哪天」刷新，别读成一个可能已经变了的字段。
    final day = _selected;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => HomeworkDetailPage(
          homework: hw,
          onToggleDone: (done) => _setDone(hw, done),
          trackTime: false,
        ),
      ),
    );
    if (!mounted) return;
    await _loadDay(day);
  }

  /// 在详情页里补打勾/撤销。
  ///
  /// 卡片上的圆圈在日历页不显示（那是今日页的动作），但详情页底部有
  /// 「我做好了」。孩子翻到前几天发现漏打了，不用退回今日页去改。
  Future<void> _setDone(Homework hw, bool next) async {
    setState(() {
      final i = _dayItems.indexWhere((e) => e.id == hw.id);
      if (i != -1) {
        _dayItems[i] = hw.copyWith(
          isDone: next,
          doneAt: next ? DateTime.now().millisecondsSinceEpoch : null,
          clearDoneAt: !next,
        );
      }
    });
    await _repo.setDone(hw.id, next);
    // 只上行这两个字段，不拉全量
    unawaited(SyncService.instance
        .syncAll(isParent: false, childId: hw.childId, pull: false));
  }

  Widget _calendarCard() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 10),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
      ),
      child: TableCalendar(
        locale: 'zh_CN',
        firstDay: DateTime(2020),
        lastDay: DateTime.now().add(const Duration(days: 365)),
        focusedDay: _focused,
        currentDay: DateTime.now(),
        rowHeight: 44,
        daysOfWeekHeight: 28,
        availableCalendarFormats: const {CalendarFormat.month: '月'},
        headerStyle: HeaderStyle(
          formatButtonVisible: false,
          titleCentered: true,
          titleTextStyle: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary,
          ),
          leftChevronIcon: Icon(Icons.chevron_left,
              size: 22, color: AppColors.textSecondary),
          rightChevronIcon: Icon(Icons.chevron_right,
              size: 22, color: AppColors.textSecondary),
        ),
        daysOfWeekStyle: DaysOfWeekStyle(
          weekdayStyle: TextStyle(fontSize: 11, color: AppColors.textTertiary),
          weekendStyle: TextStyle(fontSize: 11, color: AppColors.textTertiary),
        ),
        calendarStyle: CalendarStyle(
          outsideDaysVisible: false,
          defaultTextStyle: const TextStyle(fontSize: 13),
          weekendTextStyle: const TextStyle(fontSize: 13),
          todayDecoration: BoxDecoration(
            color: AppColors.seed.withValues(alpha: 0.15),
            shape: BoxShape.circle,
          ),
          todayTextStyle: TextStyle(
            color: AppColors.seed,
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
          selectedDecoration: BoxDecoration(
            color: AppColors.seed,
            shape: BoxShape.circle,
          ),
          selectedTextStyle: TextStyle(
            color: AppColors.onAccent,
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
        ),
        selectedDayPredicate: (d) => isSameDay(d, _selected),
        eventLoader: (day) =>
            _marked.contains(dateKey(day)) ? const [true] : const [],
        calendarBuilders: CalendarBuilders(
          markerBuilder: (context, day, events) {
            if (events.isEmpty) return null;
            final isSelected = isSameDay(day, _selected);
            return Positioned(
              bottom: 4,
              child: Container(
                width: 4,
                height: 4,
                decoration: BoxDecoration(
                  color: isSelected
                      ? AppColors.onAccent
                      : AppColors.seed.withValues(alpha: 0.7),
                  shape: BoxShape.circle,
                ),
              ),
            );
          },
        ),
        onDaySelected: (selected, focused) {
          setState(() {
            _selected = selected;
            _focused = focused;
          });
          _loadDay(selected);
        },
        onPageChanged: (focused) {
          setState(() => _focused = focused);
          _loadMarks(focused.year, focused.month);
        },
      ),
    );
  }

  Widget _dayList() {
    final doneCount = _dayItems.where((e) => e.isDone).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Row(
            children: [
              Text(
                relativeDate(dateKey(_selected)),
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(width: 8),
              if (_dayItems.isNotEmpty)
                Text(
                  '已完成 $doneCount/${_dayItems.length}',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.textTertiary,
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _dayItems.isEmpty
                  ? const EmptyState(
                      title: '这天没有作业',
                      hint: '有作业的日子日历上会有小圆点',
                      icon: Icons.event_available_outlined,
                    )
                  // key 挂日期：换一天才重播入场。
                  // 在这一天里补个勾只改 _dayItems，key 不变，不会整屏闪一次。
                  : EntranceGroup(
                      key: ValueKey(dateKey(_selected)),
                      child: ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                        itemCount: _dayItems.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (context, i) => Entrance(
                          index: i,
                          child: HomeworkCard(
                            homework: _dayItems[i],
                            onTap: () => _openDetail(_dayItems[i]),
                          ),
                        ),
                      ),
                    ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.device == DeviceType.expanded) {
      return SafeArea(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 420,
              child: SingleChildScrollView(child: _calendarCard()),
            ),
            const VerticalDivider(width: 1),
            Expanded(child: _dayList()),
          ],
        ),
      );
    }

    return SafeArea(
      top: false,
      child: Column(
        children: [
          _calendarCard(),
          Expanded(child: _dayList()),
        ],
      ),
    );
  }
}
