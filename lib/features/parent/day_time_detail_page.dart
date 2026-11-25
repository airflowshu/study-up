import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../core/utils.dart';
import '../../data/cloud/sync_service.dart';
import '../../data/repository.dart';
import '../../models/models.dart';
import '../../widgets/common.dart';

/// 家长端 · 某一天的耗时明细（原型 C）。
///
/// 从「今日累计」那条汇总条点进来。这里是唯一显示到「秒」的页面——
/// 列表上给家长的是「18 分」这种能扫读的量级，进到明细才需要精确。
class DayTimeDetailPage extends StatefulWidget {
  const DayTimeDetailPage({
    super.key,
    required this.child,
    required this.date,
    this.pullFromCloud = true,
  });

  final Child child;
  final String date;

  /// 家长端打开时先从云端拉这一天的记录。孩子端不会进这个页面。
  final bool pullFromCloud;

  @override
  State<DayTimeDetailPage> createState() => _DayTimeDetailPageState();
}

class _DayTimeDetailPageState extends State<DayTimeDetailPage> {
  final _repo = Repository.instance;

  Map<String, int> _bySubject = {};
  List<HomeworkSession> _sessions = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (widget.pullFromCloud) {
      try {
        await SyncService.instance.pullSessions(
          childId: widget.child.id,
          from: widget.date,
          to: widget.date,
        );
      } catch (_) {
        // 断网就看本地已有的，不拦页面
      }
    }
    final bySubject =
        await _repo.subjectSecondsOnDate(widget.child.id, widget.date);
    final sessions = await _repo.sessionsOfDate(widget.child.id, widget.date);
    if (!mounted) return;
    setState(() {
      _bySubject = bySubject;
      _sessions = sessions;
      _loading = false;
    });
  }

  int get _total =>
      _bySubject.values.fold(0, (sum, v) => sum + v);

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 840;
    final isToday = widget.date == todayKey();

    return Scaffold(
      appBar: AppBar(title: Text(isToday ? '今日耗时' : '耗时明细')),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: EdgeInsets.fromLTRB(
                    wide ? 28 : 16,
                    8,
                    wide ? 28 : 16,
                    32,
                  ),
                  children: [
                    ReadingWidth(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${humanDateFromKey(widget.date)} · ${widget.child.name}',
                            style: TextStyle(
                              fontSize: 13,
                              color: AppColors.textSecondary,
                            ),
                          ),
                          const SizedBox(height: 14),
                          if (_bySubject.isEmpty)
                            const Padding(
                              padding: EdgeInsets.only(top: 60),
                              child: EmptyState(
                                title: '这一天还没有计时记录',
                                hint: '孩子点开未完成的学科时，时长会悄悄累计起来',
                                icon: Icons.timer_outlined,
                              ),
                            )
                          else ...[
                            _hero(),
                            const SizedBox(height: 20),
                            const _SectionTitle('按学科'),
                            const SizedBox(height: 4),
                            ..._subjectBars(),
                            ..._sessionBlocks(),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _hero() {
    final subjects = _bySubject.length;
    final avg = subjects == 0 ? 0 : _total ~/ subjects;
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
            '当日累计',
            style: TextStyle(
              fontSize: AppText.label,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: AppSpace.xs + 2),
          DurationHeadline(seconds: _total),
          const SizedBox(height: AppSpace.sm),
          Text(
            '$subjects 科有记录 · 平均每科 ${formatDuration(avg)}',
            style: TextStyle(
              fontSize: AppText.label,
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
    return [
      for (final e in entries)
        _SubjectBar(
          subject: e.key,
          seconds: e.value,
          ratio: maxSeconds == 0 ? 0 : e.value / maxSeconds,
          total: _total,
        ),
    ];
  }

  /// 每科下面挂「每次进入」的时间段。原型只展开了语文，
  /// 这里全展开——家长点进明细就是想知道"什么时候做的、做了多久"。
  List<Widget> _sessionBlocks() {
    final out = <Widget>[];
    final entries = _bySubject.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    for (final e in entries) {
      final mine =
          _sessions.where((s) => s.subject == e.key).toList()
            ..sort((a, b) => a.startAt.compareTo(b.startAt));
      if (mine.isEmpty) continue;
      out.addAll([
        const SizedBox(height: 18),
        _SectionTitle('${e.key} · 每次进入'),
        const SizedBox(height: 6),
        Container(
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(AppRadius.sm),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            children: [
              for (var i = 0; i < mine.length; i++) ...[
                if (i > 0)
                  const Divider(height: 1, indent: 14, endIndent: 14),
                _SessionRow(session: mine[i]),
              ],
            ],
          ),
        ),
      ]);
    }
    return out;
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 4),
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

/// 学科横向条。百分比按「占当日总计」算，条长按「占最大那科」算，
/// 这样即使只有两科，条也不会都缩成一点点。
class _SubjectBar extends StatelessWidget {
  const _SubjectBar({
    required this.subject,
    required this.seconds,
    required this.ratio,
    required this.total,
  });

  final String subject;
  final int seconds;
  final double ratio;
  final int total;

  @override
  Widget build(BuildContext context) {
    final color = AppColors.ofSubject(subject);
    final pct = total == 0 ? 0 : (seconds / total * 100).round();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SubjectTag(subject: subject, dense: true),
              const Spacer(),
              Text(
                formatDurationLong(seconds),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '$pct%',
                style: TextStyle(
                  fontSize: 11,
                  color: AppColors.textTertiary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.xs),
            child: LinearProgressIndicator(
              value: ratio.clamp(0.0, 1.0),
              minHeight: 6,
              backgroundColor: AppColors.surface3,
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
        ],
      ),
    );
  }
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({required this.session});

  final HomeworkSession session;

  @override
  Widget build(BuildContext context) {
    final start = formatTimeOfDay(session.startAt);
    final endMs = session.endAt;
    final end = endMs == null
        ? '—'
        : formatTimeOfDay(endMs);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Text(
            '$start — $end',
            style: TextStyle(
              fontSize: 13,
              color: AppColors.textSecondary,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const Spacer(),
          Text(
            formatDurationLong(session.seconds),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

/// 大号时长。`46 分` / `12 小时 40 分`，数字比单位重。
class DurationHeadline extends StatelessWidget {
  DurationHeadline({
    super.key,
    required this.seconds,
    this.numberSize = AppText.display,
    this.unitSize = AppText.body,
    this.color,
  });

  final int seconds;
  final double numberSize;
  final double unitSize;

  /// 不传就跟随当前主题的文字主色。
  /// 默认值不能写成 `AppColors.textPrimary`——那是运行时取值，不是常量表达式。
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final color = this.color ?? AppColors.textPrimary;
    if (seconds < 60) {
      return Text(
        '不到 1 分',
        style: TextStyle(
          fontSize: numberSize * 0.6,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      );
    }
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final numStyle = TextStyle(
      fontSize: numberSize,
      fontWeight: FontWeight.w700,
      color: color,
      height: 1.1,
      // 等宽数字：刷新时数字跳动不会左右抖
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final unitStyle = TextStyle(
      fontSize: unitSize,
      fontWeight: FontWeight.w500,
      color: color.withValues(alpha: 0.75),
    );
    return Text.rich(
      TextSpan(
        children: [
          if (h > 0) ...[
            TextSpan(text: '$h', style: numStyle),
            TextSpan(text: ' 小时 ', style: unitStyle),
          ],
          TextSpan(text: '$m', style: numStyle),
          TextSpan(text: ' 分', style: unitStyle),
        ],
      ),
    );
  }
}
