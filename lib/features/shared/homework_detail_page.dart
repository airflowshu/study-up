import 'package:flutter/material.dart';

import '../../core/rich_body.dart';
import '../../core/theme.dart';
import '../../core/utils.dart';
import '../../models/models.dart';
import '../../state/study_timer.dart';
import '../../widgets/attachment_card.dart';
import '../../widgets/common.dart';
import '../../widgets/rich_body_view.dart';

/// 作业详情整页。
///
/// 从列表点进来就是全屏，不再挤在平板右侧那一栏里：
/// 正文按图文混排铺开，图片点开是全屏查看器。
class HomeworkDetailPage extends StatefulWidget {
  const HomeworkDetailPage({
    super.key,
    required this.homework,
    this.onToggleDone,
    this.onEdit,
    this.showDoneState = true,
    this.trackTime = false,
  });

  final Homework homework;

  /// 孩子端：点圆圈打勾，回调新的完成状态
  final ValueChanged<bool>? onToggleDone;

  /// 家长端：右上角「编辑」。回调返回改完后的作业，详情页自己换新内容，
  /// 不用退出再点一次（返回 null 表示没改或已删除，保持原样）。
  final Future<Homework?> Function()? onEdit;

  final bool showDoneState;

  /// 孩子端：进页面就开始给这科计时（作业已打勾则不计）。
  /// 界面上一律不提示——孩子不该看到自己"被计时"。
  final bool trackTime;

  @override
  State<HomeworkDetailPage> createState() => _HomeworkDetailPageState();
}

class _HomeworkDetailPageState extends State<HomeworkDetailPage> {
  late Homework _hw = widget.homework;

  @override
  void initState() {
    super.initState();
    _syncTimer();
  }

  @override
  void dispose() {
    super.dispose();
  }

  /// 退出详情 = 本段结束。
  ///
  /// 挂在 [PopScope] 上而不是 [dispose]：dispose 发生在路由动画**之后**，
  /// 而调用方（孩子端列表）是在 `Navigator.push` 的 future 完成后就去查
  /// 「有没有待上传的计时」。那时 dispose 还没跑，`stop()` 没被调用，
  /// 这一段就永远传不上去。PopScope 在 pop 发起时就触发，时序才稳。
  void _stopTiming() {
    if (!widget.trackTime) return;
    // 不 await：落库由 StudyTimer 内部的队列跑完。
    // 调用方 await StudyTimer.idle 就能等到它写完。
    StudyTimer.instance.stop();
  }

  /// 计时跟着「是否还没完成」走：没打勾就计时，打勾就立刻停表。
  void _syncTimer() {
    if (!widget.trackTime) return;
    if (_hw.isDone) {
      StudyTimer.instance.stop();
    } else {
      StudyTimer.instance.start(_hw);
    }
  }

  void _toggle() {
    final next = !_hw.isDone;
    setState(() {
      _hw = _hw.copyWith(
        isDone: next,
        doneAt: next ? DateTime.now().millisecondsSinceEpoch : null,
        clearDoneAt: !next,
      );
    });
    // 打勾即停，之后再打开不再计时；取消打勾则重新开始计时
    _syncTimer();
    widget.onToggleDone?.call(next);
  }

  /// 进编辑页，回来把详情页内容换成最新的那条。
  Future<void> _edit() async {
    final handler = widget.onEdit;
    if (handler == null) return;
    final fresh = await handler();
    if (!mounted || fresh == null) return;
    setState(() => _hw = fresh);
  }

  @override
  Widget build(BuildContext context) {
    final canToggle = widget.onToggleDone != null;
    final wide = MediaQuery.sizeOf(context).width >= 840;

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _stopTiming();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_hw.subject),
          actions: [
            if (widget.onEdit != null)
              TextButton(
                onPressed: _edit,
                child: const Text('编辑'),
              ),
            const SizedBox(width: 4),
          ],
        ),
        bottomNavigationBar: canToggle ? _bottomAction() : null,
        body: SafeArea(
          bottom: false,
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              wide ? 28 : AppSpace.lg + 2,
              AppSpace.md + 2,
              wide ? 28 : AppSpace.lg + 2,
              AppSpace.xxl + 4,
            ),
            child: ReadingWidth(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _headerCard(),
                  const SizedBox(height: AppSpace.xl),
                  RichBody(
                    content: _hw.content,
                    images: _hw.imageRefs,
                    layout: RichImageLayout.grid,
                    singleImageWidth: wide ? 340 : 300,
                    blockSpacing: AppSpace.lg,
                    style: TextStyle(
                      fontSize: AppText.title,
                      height: 1.9,
                      color: _hw.isDone
                          ? AppColors.textTertiary
                          : AppColors.textPrimary,
                    ),
                  ),
                  if (_hw.attachments.isNotEmpty) ...[
                    const SizedBox(height: AppSpace.lg),
                    // 详情页是全量展示：不折叠、不截断，点一个开一个
                    AttachmentList(attachments: _hw.attachments),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 学科色页头：进页面先确认「进对了」。
  ///
  /// 原来只有一行学科标签 + 日期的小字，标题层级完全没有，
  /// 一屏多科时长文看着都一个样。
  Widget _headerCard() {
    final color = AppColors.ofSubject(_hw.subject);
    final first = _firstLine();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            color.withValues(alpha: 0.12),
            color.withValues(alpha: 0.05),
          ],
        ),
        borderRadius: BorderRadius.circular(AppRadius.lg - 4),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpace.sm,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(AppRadius.xs),
                ),
                child: Text(
                  _hw.subject,
                  style: const TextStyle(
                    fontSize: AppText.label,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(width: AppSpace.sm),
              Text(
                humanDateFromKey(_hw.date),
                style: TextStyle(
                  fontSize: AppText.caption,
                  color: color.withValues(alpha: 0.85),
                ),
              ),
              const Spacer(),
              _donePill(_hw.isDone),
            ],
          ),
          if (first.isNotEmpty) ...[
            const SizedBox(height: AppSpace.md),
            Text(
              first,
              style: TextStyle(
                fontSize: AppText.title,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
                height: 1.45,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 正文第一行当标题用（去掉 [图N] 标记），太长就截断。
  String _firstLine() {
    final text = plainText(_hw.content);
    final line = text.split('\n').firstWhere(
          (l) => l.trim().isNotEmpty,
          orElse: () => '',
        );
    final t = line.trim();
    if (t.length <= 24) return t;
    return '${t.substring(0, 24)}…';
  }

  /// 底部完成区：孩子端最关键的动作，原来只藏在右上角一个 26dp 小圆里。
  ///
  /// 打勾后按钮变成「已完成 · 撤销」的次要态，孩子能自己改回来。
  Widget _bottomAction() {
    final done = _hw.isDone;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        AppSpace.sm + 2,
        AppSpace.lg,
        AppSpace.md,
      ),
      child: SafeArea(
        top: false,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          transitionBuilder: (child, animation) => ScaleTransition(
            scale: animation,
            child: child,
          ),
          child: done
              ? OutlinedButton.icon(
                  key: const ValueKey('done'),
                  onPressed: _toggle,
                  icon: const Icon(Icons.check_rounded, size: 19),
                  label: const Text('已完成 · 点此撤销'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(50),
                    foregroundColor: AppColors.successInk,
                    side: BorderSide(color: AppColors.success),
                    backgroundColor: AppColors.successSoft,
                    textStyle: const TextStyle(
                      fontSize: AppText.body,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                )
              : PrimaryAction(
                  key: const ValueKey('todo'),
                  label: '我做好了',
                  icon: Icons.check_rounded,
                  onPressed: _toggle,
                ),
        ),
      ),
    );
  }

  Widget _donePill(bool done) {
    return StatusPill(
      label: done ? '已完成' : '未完成',
      color: done ? AppColors.successInk : AppColors.textTertiary,
      icon: done ? Icons.check_circle : Icons.radio_button_unchecked,
    );
  }
}
