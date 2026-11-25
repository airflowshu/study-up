import 'package:flutter/material.dart';

import '../../core/breakpoints.dart';
import '../../core/theme.dart';
import '../../core/utils.dart';
import '../../data/repository.dart';
import '../../models/models.dart';
import '../../state/app_state.dart';
import '../../widgets/common.dart';
import '../../widgets/homework_card.dart';
import 'homework_edit_page.dart';

/// 家长端历史：按日期倒序看所有布置过的作业。
/// 平板横屏下左侧是日期索引，右侧是当日各科。
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key, required this.device});

  final DeviceType device;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  final _repo = Repository.instance;
  List<Homework> _all = [];
  bool _loading = true;
  String _subjectFilter = '全部';
  String? _selectedDate;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final child = AppStateScope.read(context).activeChild;
    if (child == null) {
      setState(() => _loading = false);
      return;
    }
    final rows = await _repo.homeworkAll(child.id);
    if (!mounted) return;
    setState(() {
      _all = rows;
      _loading = false;
      if (_selectedDate == null && rows.isNotEmpty) {
        _selectedDate = rows.first.date;
      }
    });
  }

  List<Homework> get _filtered => _subjectFilter == '全部'
      ? _all
      : _all.where((e) => e.subject == _subjectFilter).toList();

  Map<String, List<Homework>> get _grouped {
    final map = <String, List<Homework>>{};
    for (final hw in _filtered) {
      map.putIfAbsent(hw.date, () => []).add(hw);
    }
    final keys = map.keys.toList()..sort((a, b) => b.compareTo(a));
    return {for (final k in keys) k: map[k]!};
  }

  List<String> get _subjects {
    final set = <String>{};
    for (final hw in _all) {
      set.add(hw.subject);
    }
    final list = set.toList();
    list.sort();
    return ['全部', ...list];
  }

  Future<void> _openEdit(Homework hw) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => HomeworkEditPage(
          childId: hw.childId,
          date: parseDateKey(hw.date),
          existing: hw,
        ),
      ),
    );
    _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_all.isEmpty) {
      return const EmptyState(
        title: '还没有历史记录',
        hint: '布置过的作业会按日期存在这里',
        icon: Icons.history_rounded,
      );
    }

    final filterBar = _buildFilterBar();

    if (widget.device == DeviceType.expanded) {
      final grouped = _grouped;
      final dates = grouped.keys.toList();
      final activeDate = _selectedDate != null && grouped.containsKey(_selectedDate)
          ? _selectedDate!
          : (dates.isEmpty ? null : dates.first);
      final dayItems = activeDate == null ? <Homework>[] : grouped[activeDate]!;

      return SafeArea(
        child: Column(
          children: [
            filterBar,
            Expanded(
              child: Row(
                children: [
                  SizedBox(
                    width: 240,
                    child: ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: dates.length,
                      itemBuilder: (context, i) {
                        final d = dates[i];
                        final selected = d == activeDate;
                        return InkWell(
                          onTap: () => setState(() => _selectedDate = d),
                          child: Container(
                            margin: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 3),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 10),
                            decoration: BoxDecoration(
                              color: selected
                                  ? AppColors.seed.withValues(alpha: 0.1)
                                  : Colors.transparent,
                              borderRadius:
                                  BorderRadius.circular(AppRadius.sm),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        relativeDate(d),
                                        style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: selected
                                              ? FontWeight.w600
                                              : FontWeight.w400,
                                          color: selected
                                              ? AppColors.seed
                                              : AppColors.textPrimary,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        '${grouped[d]!.length} 科',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: AppColors.textTertiary,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (selected)
                                  Icon(Icons.chevron_right,
                                      size: 16, color: AppColors.seed),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(
                    child: ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: dayItems.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (context, i) {
                        final hw = dayItems[i];
                        return HomeworkCard(
                          homework: hw,
                          onTap: () => _openEdit(hw),
                          onEdit: () => _openEdit(hw),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    // 手机竖屏：日期分组标题 + 卡片
    final grouped = _grouped;
    return SafeArea(
      top: false,
      child: Column(
        children: [
          filterBar,
          Expanded(
            child: ListView(
              key: const PageStorageKey('history_list'),
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              children: [
                for (final entry in grouped.entries) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 14, 4, 8),
                    child: Row(
                      children: [
                        Text(
                          relativeDate(entry.key),
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textSecondary,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '已完成 ${entry.value.where((e) => e.isDone).length}/${entry.value.length}',
                          style: TextStyle(
                            fontSize: 11,
                            color: AppColors.textTertiary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  for (final hw in entry.value)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: HomeworkCard(
                        homework: hw,
                        onTap: () => _openEdit(hw),
                        onEdit: () => _openEdit(hw),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterBar() {
    return Container(
      height: 46,
      color: AppColors.pageBg,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        children: [
          for (final s in _subjects)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: GestureDetector(
                onTap: () => setState(() => _subjectFilter = s),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: _subjectFilter == s
                        ? AppColors.seed.withValues(alpha: 0.12)
                        : AppColors.surface2,
                    borderRadius: BorderRadius.circular(AppRadius.full),
                    border: Border.all(
                      color: _subjectFilter == s
                          ? AppColors.seed.withValues(alpha: 0.4)
                          : AppColors.border,
                    ),
                  ),
                  child: Text(
                    s,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: _subjectFilter == s
                          ? FontWeight.w600
                          : FontWeight.w400,
                      color: _subjectFilter == s
                          ? AppColors.seed
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
