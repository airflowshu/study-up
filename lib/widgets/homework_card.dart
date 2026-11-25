import 'package:flutter/material.dart';

import '../core/motion.dart';
import '../core/theme.dart';
import '../core/utils.dart';
import '../models/models.dart';
import 'attachment_card.dart';
import 'common.dart';
import 'image_stack.dart';
import 'rich_body_view.dart';

/// 作业卡片。家长端与孩子端共用，靠参数控制可点区域：
/// - 孩子端：onToggleDone 可点，卡片变淡表示已完成
/// - 家长端：onToggleDone 为 null，只读展示完成状态
///
/// 微交互两层：
/// 1. **按下整卡回收 1.3%**（110ms）——手指落在卡片上立刻有回执，
///    不用等抬手、不用等页面跳转。这是列表里唯一每个操作都会经过的反馈。
/// 2. **完成态换色走 230ms 过渡**——打勾时底色和左侧学科色条一起退到
///    完成档，读起来是「这张卡被划掉了」，而不是「换了一张图」。
class HomeworkCard extends StatefulWidget {
  const HomeworkCard({
    super.key,
    required this.homework,
    this.onTap,
    this.onEdit,
    this.onToggleDone,
    this.showDoneState = true,
    this.durationSeconds,
  });

  final Homework homework;
  final VoidCallback? onTap;
  final VoidCallback? onEdit;
  final VoidCallback? onToggleDone;
  final bool showDoneState;

  /// 家长端：孩子在这科上累计的秒数。
  /// null / 0 时**整块不出现**——没计时记录就不写「0 分」，
  /// 否则家长会读成「孩子这科一点没学」。
  final int? durationSeconds;

  @override
  State<HomeworkCard> createState() => _HomeworkCardState();
}

class _HomeworkCardState extends State<HomeworkCard> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final homework = widget.homework;
    final subjectColor = AppColors.ofSubject(homework.subject);
    final done = homework.isDone;
    final reduce = AppMotion.reduced(context);
    final interactive = widget.onTap != null;

    final card = AnimatedContainer(
      duration: AppMotion.base,
      curve: AppMotion.easeOutQuart,
      // 白底与描边必须由 Container 自己画：
      // 之前依赖 Material 的 color 没有落地，卡片在浅色页面上完全看不出边界。
      decoration: BoxDecoration(
        // 已完成不用整卡 opacity（那样正文对比度只剩 2.6:1，看不清），
        // 改成换一层更浅的底色 + 正文降一档色阶。
        color: done ? AppColors.doneBg : AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
        // 按下时抬一档阴影：配合回收的尺度，形成「被按下去」的立体感。
        boxShadow: _pressed && interactive ? AppShadow.s2 : AppShadow.s1,
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: widget.onTap,
          // 只在这个回调里改状态，不自己写 Listener：
          // InkWell 已经处理了「手指滑走算取消」这类边界情况。
          onHighlightChanged: interactive ? _setPressed : null,
          child: Stack(
            children: [
              // 左侧学科色条：用 Positioned 撑满卡片高度。
              // 不能靠 Row 的 stretch —— ListView 里高度无界，stretch 会直接布局失败。
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: 3,
                child: AnimatedContainer(
                  duration: AppMotion.base,
                  curve: AppMotion.easeOutQuart,
                  color:
                      done ? subjectColor.withValues(alpha: 0.5) : subjectColor,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(15, 10, 8, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        SubjectTag(subject: homework.subject),
                        if (widget.durationSeconds != null &&
                            widget.durationSeconds! > 0) ...[
                          const SizedBox(width: AppSpace.sm),
                          _TimeChip(seconds: widget.durationSeconds!),
                        ],
                        const Spacer(),
                        if (widget.showDoneState && widget.onToggleDone == null)
                          _doneLabel(done),
                        if (widget.onEdit != null) _editButton(widget.onEdit!),
                        if (widget.onToggleDone != null)
                          DoneCircle(
                            done: done,
                            onTap: widget.onToggleDone,
                          ),
                      ],
                    ),
                    const SizedBox(height: AppSpace.xs + 2),
                    // 正文颜色跟着完成态走 230ms 过渡；删除线是离散属性，
                    // 会直接切换——正好，那条横杠本身就是「完成」的强信号。
                    AnimatedDefaultTextStyle(
                      duration: AppMotion.base,
                      curve: AppMotion.easeOutQuart,
                      style: TextStyle(
                        fontSize: AppText.body,
                        height: 1.55,
                        color: done
                            ? AppColors.textTertiary
                            : AppColors.textPrimary,
                        decoration: done ? TextDecoration.lineThrough : null,
                        decorationColor: AppColors.textDisabled,
                      ),
                      child: Text(
                        // 卡片只是摘要：去掉 [图N] 标记，图片另行折叠展示
                        richPreviewText(homework.content),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (homework.imageRefs.isNotEmpty) ...[
                      const SizedBox(height: AppSpace.sm),
                      // 多图默认叠成一小摞（微信式），点「展开 N」再铺成网格
                      StackedImages(images: homework.imageRefs, tile: 84),
                    ],
                    if (homework.attachments.isNotEmpty) ...[
                      const SizedBox(height: AppSpace.sm),
                      // 摘要里只露两个，点整卡进详情看全部。
                      // 这里不响应点击：卡片本身就是「进详情」的入口。
                      AttachmentList(
                        attachments: homework.attachments,
                        dense: true,
                        max: 2,
                        enabled: false,
                      ),
                    ],
                    if (homework.pendingSync) ...[
                      const SizedBox(height: AppSpace.sm - 2),
                      Row(
                        children: [
                          StatusPill(
                            label: '待同步',
                            color: AppColors.warningInk,
                            icon: Icons.cloud_off_outlined,
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (!interactive || reduce) return card;
    return AnimatedScale(
      scale: _pressed ? 0.987 : 1,
      duration: AppMotion.press,
      curve: AppMotion.easeOutQuart,
      child: card,
    );
  }

  /// 「编辑」：32dp 的图标按钮。
  ///
  /// 原来是 12px 的文字按钮，视觉权重比整卡点击（进详情）还低，
  /// 而改作业是家长的高频动作。改成图标后不再和「查看」抢同一层视觉。
  Widget _editButton(VoidCallback onPressed) {
    return Semantics(
      button: true,
      label: '编辑',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: SizedBox(
          width: 44,
          height: 32,
          child: Align(
            alignment: Alignment.centerRight,
            child: Icon(
              Icons.edit_outlined,
              size: 17,
              color: AppColors.textTertiary,
            ),
          ),
        ),
      ),
    );
  }

  Widget _doneLabel(bool done) {
    return AnimatedContainer(
      duration: AppMotion.base,
      curve: AppMotion.easeOutQuart,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: done ? AppColors.successSoft : AppColors.surface2,
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (done)
            Padding(
              padding: EdgeInsets.only(right: 3),
              child:
                  Icon(Icons.check_circle, size: 12, color: AppColors.success),
            ),
          Text(
            done ? '已完成' : '未完成',
            style: TextStyle(
              fontSize: AppText.caption,
              fontWeight: FontWeight.w600,
              color: done ? AppColors.successInk : AppColors.textTertiary,
            ),
          ),
        ],
      ),
    );
  }
}

/// 家长端卡片上的耗时胶囊。只在有记录时出现（由调用方判断）。
class _TimeChip extends StatelessWidget {
  const _TimeChip({required this.seconds});

  final int seconds;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.schedule, size: 12, color: AppColors.primaryInk),
        const SizedBox(width: 3),
        Text(
          formatDuration(seconds),
          style: TextStyle(
            fontSize: AppText.caption,
            fontWeight: FontWeight.w600,
            color: AppColors.primaryInk,
          ),
        ),
      ],
    );
  }
}
