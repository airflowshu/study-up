import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/motion.dart';
import '../core/theme.dart';
import '../models/models.dart';

/// 头像上的姓名单字缩写：取名字最后一个字。
///
/// 「张小满」→「满」而不是「汪」。姓谁家孩子都常见，一个字区分不出人；
/// 名的末字区分度高得多，家长在孩子切换条上扫一眼就能认出来。
///
/// 用 `runes` 而不是 `substring`：后者按 UTF-16 码元切，碰到 emoji 这类
/// 代理对会切出半个字符，渲染成乱码方块。空名字给 `?`。
String childInitial(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return '?';
  return String.fromCharCode(trimmed.runes.last);
}

/// 孩子头像：圆形底色 + 姓名单字。
class ChildAvatar extends StatelessWidget {
  const ChildAvatar({super.key, required this.child, this.size = 32});

  final Child child;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = AppColors
        .childPalette[child.colorIndex % AppColors.childPalette.length];
    final initial = childInitial(child.name);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        shape: BoxShape.circle,
      ),
      child: Text(
        initial,
        style: TextStyle(
          color: color,
          fontSize: size * 0.42,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 完成勾选圆。孩子点它切换完成状态，家长端只读展示。
///
/// 视觉圆 [size] 默认 28，外面套一个 44×44 的触摸盒：
/// 孩子手指点偏一点也要打得中，44 是无障碍最小触摸尺寸。
/// 触摸盒靠 [Alignment.centerRight] 贴右，卡片右侧不必再留额外空白。
///
/// 打勾是这个 App 里唯一的高频正向反馈，值得一次完整的确认：
/// 圆填色（170ms）+ 对勾从 0.45 倍弹到 1 倍（落在 380ms 同一条时间线上）
/// + 外圈一圈成功色扩散后淡出。三层同时起跑、不同时长收尾，
/// 读起来是「一件事完成了」，而不是三段各自播放的动画。
class DoneCircle extends StatefulWidget {
  const DoneCircle({
    super.key,
    required this.done,
    this.onTap,
    this.size = 28,
    this.tapSize = 44,
  });

  final bool done;
  final VoidCallback? onTap;
  final double size;

  /// 可点状态下的触摸盒边长
  final double tapSize;

  @override
  State<DoneCircle> createState() => _DoneCircleState();
}

class _DoneCircleState extends State<DoneCircle>
    with SingleTickerProviderStateMixin {
  /// 打勾庆祝曲线：0 → 1 覆盖 380ms。
  late final AnimationController _burst = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
  );

  @override
  void initState() {
    super.initState();
    // 一上来就是已完成（例如翻到前几天的作业）不播庆祝，直接给终态，
    // 否则一屏卡片会一起放烟花。
    if (widget.done) _burst.value = 1;
  }

  @override
  void didUpdateWidget(covariant DoneCircle old) {
    super.didUpdateWidget(old);
    if (widget.done && !old.done) {
      _burst.forward(from: 0);
    } else if (!widget.done && old.done) {
      // 取消打勾立刻归零：对勾已经消失，不必再补一段出场。
      _burst.value = 0;
    }
  }

  @override
  void dispose() {
    _burst.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final done = widget.done;
    final size = widget.size;
    final reduce = AppMotion.reduced(context);

    final circle = AnimatedContainer(
      duration: AppMotion.quick,
      curve: AppMotion.easeOutQuart,
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: done ? AppColors.success : Colors.transparent,
        border: Border.all(
          color: done ? AppColors.success : AppColors.borderStrong,
          width: 1.6,
        ),
      ),
      child: done
          ? AnimatedBuilder(
              animation: _burst,
              builder: (context, child) {
                // 对勾在前 45% 内完成缩放，后 55% 保持不变，
                // 这样它和外圈扩散是「同时开始、先后结束」的关系。
                final t = (_burst.value / 0.45).clamp(0.0, 1.0);
                final e = AppMotion.easeOutExpo.transform(t);
                return Opacity(
                  opacity: e,
                  child: Transform.scale(
                    scale: 0.45 + 0.55 * e,
                    child: child,
                  ),
                );
              },
              child: Icon(
                Icons.check_rounded,
                size: size * 0.66,
                color: AppColors.onAccent,
              ),
            )
          : null,
    );

    final visual = Stack(
      // 扩散圈会超出 28dp 的圆，不能裁。
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        if (done && !reduce) _ring(size),
        circle,
      ],
    );

    if (widget.onTap == null) return visual;

    // 触摸区必须显式撑开并声明 opaque：
    // 未打勾时圆内没有子节点，透明装饰盒不参与命中测试，
    // 若不加 opaque，点击会直接穿透到底下的卡片，表现为「点了没反应」。
    return Semantics(
      button: true,
      label: done ? '已完成，点击取消' : '标记为已完成',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          // 平板上有触感马达，这一下比任何视觉反馈都直接。
          // 没有马达的设备调了也无副作用。
          HapticFeedback.selectionClick();
          widget.onTap!();
        },
        child: SizedBox(
          width: widget.tapSize,
          height: widget.tapSize,
          child: Align(
            alignment: Alignment.centerRight,
            child: visual,
          ),
        ),
      ),
    );
  }

  /// 外圈扩散：随 [_burst] 从 1 倍放大到 1.55 倍，同时透明度归零。
  Widget _ring(double size) {
    return AnimatedBuilder(
      animation: _burst,
      builder: (context, _) {
        final v = _burst.value;
        // 起止两端都不画，省掉两次无意义的合成层。
        if (v <= 0 || v >= 1) return const SizedBox.shrink();
        final e = AppMotion.easeOutQuart.transform(v);
        return Opacity(
          opacity: (1 - v) * 0.4,
          child: Transform.scale(
            scale: 1 + 0.55 * e,
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.success,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 学科小标签，颜色跟学科固定对应。
class SubjectTag extends StatelessWidget {
  const SubjectTag({super.key, required this.subject, this.dense = false});

  final String subject;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.ofSubject(subject);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 6 : 8,
        vertical: dense ? 2 : 3,
      ),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
      child: Text(
        subject,
        style: TextStyle(
          color: c,
          fontSize: dense ? AppText.caption : AppText.label,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 分区卡：编辑页这类长表单用，带序号方块的标题 + 内容。
/// 下滑到任何位置都能看出「现在填的是哪一段」。
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.index,
    required this.title,
    required this.child,
    this.trailing,
  });

  final int index;
  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpace.md + 2),
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
              Container(
                width: 18,
                height: 18,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.primarySoft,
                  borderRadius: BorderRadius.circular(AppRadius.xs),
                ),
                child: Text(
                  '$index',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: AppColors.primaryInk,
                  ),
                ),
              ),
              const SizedBox(width: AppSpace.sm),
              Text(
                title,
                style: TextStyle(
                  fontSize: AppText.label,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textSecondary,
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: AppSpace.sm),
                trailing!,
              ],
            ],
          ),
          const SizedBox(height: AppSpace.md - 2),
          child,
        ],
      ),
    );
  }
}

/// 主行动按钮：50dp 高 + s2 阴影。
/// 页面里唯一的那个主 CTA 用它，让它在灰底上真的「浮」起来。
class PrimaryAction extends StatelessWidget {
  const PrimaryAction({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.busy = false,
    this.color,
    this.expand = true,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool busy;
  final Color? color;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final bg = color ?? AppColors.primary;
    final child = busy
        ? SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.onAccent,
            ),
          )
        : Row(
            mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 19, color: AppColors.onAccent),
                const SizedBox(width: AppSpace.sm - 2),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: AppText.body,
                  fontWeight: FontWeight.w600,
                  color: AppColors.onAccent,
                ),
              ),
            ],
          );

    return SizedBox(
      width: expand ? double.infinity : null,
      height: 50,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.md),
          boxShadow: onPressed == null ? null : AppShadow.s2,
        ),
        child: FilledButton(
          onPressed: busy ? null : onPressed,
          style: FilledButton.styleFrom(
            backgroundColor: bg,
            disabledBackgroundColor: bg.withValues(alpha: 0.5),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// 环形进度（孩子端「已完成 2/5」）。
/// 比一行灰字更快读：一眼看到的是比例，不用去读数字。
///
/// 数字变了，环要跟着走过去而不是跳过去——跳变会被误读成「数据重算了」，
/// 走过去才是「刚才那一勾算进去了」。环的颜色在最后 10% 才渐变到成功色，
/// 所以「差一科」和「全打完」在余光里就能分开。
class ProgressRing extends StatelessWidget {
  const ProgressRing({
    super.key,
    required this.done,
    required this.total,
    this.size = 52,
    this.stroke = 5,
  });

  final int done;
  final int total;
  final double size;
  final double stroke;

  @override
  Widget build(BuildContext context) {
    final ratio = total == 0 ? 0.0 : (done / total).clamp(0.0, 1.0);
    final complete = total > 0 && done == total;

    final ring = TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: ratio),
      duration: AppMotion.reduced(context) ? Duration.zero : AppMotion.progress,
      curve: AppMotion.easeOutQuint,
      builder: (context, v, _) {
        // 前 90% 全是主色，最后 10% 过渡到成功色：
        // 只有真的打满时才「变色」，打满的过程中不会提前泛绿。
        final greenT = ((v - 0.9) / 0.1).clamp(0.0, 1.0);
        final color = Color.lerp(AppColors.primary, AppColors.success, greenT)!;
        return Stack(
          alignment: Alignment.center,
          children: [
            CircularProgressIndicator(
              value: total == 0 ? 0 : v,
              strokeWidth: stroke,
              strokeCap: StrokeCap.round,
              backgroundColor: AppColors.surface3,
              color: color,
            ),
            Text(
              '$done/$total',
              style: TextStyle(
                fontSize: AppText.label,
                fontWeight: FontWeight.w700,
                color: complete ? AppColors.successInk : AppColors.primaryInk,
              ),
            ),
          ],
        );
      },
    );

    return SizedBox(width: size, height: size, child: ring);
  }
}

/// 加载骨架块。
///
/// 刻意不做动画：列表首帧挂一堆 AnimationController 会拖慢首屏，
/// 静态渐变块已经足够传达「还在读」。
class Skeleton extends StatelessWidget {
  const Skeleton({
    super.key,
    this.width,
    this.height = 13,
    this.radius = AppRadius.xs,
  });

  final double? width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [AppColors.surface3, AppColors.surface2, AppColors.surface3],
        ),
      ),
    );
  }
}

/// 列表加载骨架：三行文字 + 一个图块，替代裸转圈。
class CardSkeleton extends StatelessWidget {
  const CardSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: const [
        Skeleton(width: 64, height: 18),
        SizedBox(height: AppSpace.md),
        Skeleton(width: double.infinity),
        SizedBox(height: AppSpace.sm),
        Skeleton(width: 180),
        SizedBox(height: AppSpace.md),
        Skeleton(width: 76, height: 76, radius: AppRadius.sm),
      ],
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.title,
    this.hint,
    this.icon = Icons.inbox_outlined,
    this.action,
  });

  final String title;
  final String? hint;
  final IconData icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.xxl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: AppColors.surface2,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 26, color: AppColors.textDisabled),
            ),
            const SizedBox(height: AppSpace.md),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: AppText.body,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
            if (hint != null) ...[
              const SizedBox(height: AppSpace.xs + 2),
              Text(
                hint!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: AppText.label,
                  height: 1.6,
                  color: AppColors.textTertiary,
                ),
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: AppSpace.lg + 2),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// 宽屏下限制阅读宽度并居中，避免一行文字横跨整个平板。
class ReadingWidth extends StatelessWidget {
  const ReadingWidth({
    super.key,
    required this.child,
    this.maxWidth = 720,
  });

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}

/// 底部小提示条，用于「待同步」「上传中」等状态。
class StatusPill extends StatelessWidget {
  StatusPill({
    super.key,
    required this.label,
    this.color,
    this.icon,
  });

  final String label;

  /// 不传就用警示色。默认值不能直接写 AppColors.warning——
  /// 那是运行时取值，不能做常量默认参数。
  final Color? color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final color = this.color ?? AppColors.warning;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: color),
            const SizedBox(width: AppSpace.xs),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: AppText.caption,
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
