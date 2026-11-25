import 'package:flutter/material.dart';

/// 全局动效令牌。
///
/// 这个 App 的动效承担三件事，别的都不做：
/// 1. **交代状态变了**（打勾、切换、刷新完成）
/// 2. **交代内容从哪来**（入场时从下方 12dp 处淡入，暗示「这里是新内容」）
/// 3. **给手指一个即时回执**（按下就缩，不等抬手）
///
/// 三条硬约束：
/// - 一律指数减速曲线，不用回弹/弹性。回弹会把注意力引到动画本身，
///   而这个界面的主角是作业内容，不是动画。
/// - 反馈类不超过 120ms。超过这个数，手指会觉得「按了没反应」。
/// - 入场总时长封顶 460ms。孩子点开就要看到今天还剩几科，
///   等动画的时间在体感上直接算成卡顿。
class AppMotion {
  AppMotion._();

  /// 按下 / 抬起的即时回执。再长就有滞后感。
  static const Duration press = Duration(milliseconds: 110);

  /// 小范围状态过渡：图标缩放、徽标切换、图片区展开。
  static const Duration quick = Duration(milliseconds: 170);

  /// 常规状态过渡：卡片完成态、页签交叉淡出。
  static const Duration base = Duration(milliseconds: 230);

  /// 大块容器变化。
  static const Duration slow = Duration(milliseconds: 340);

  /// 整组入场。组内再按 index 错峰，所以单项实际只跑其中一段。
  static const Duration entrance = Duration(milliseconds: 460);

  /// 环形 / 条形进度追值。比 base 长：数字跳一下没关系，
  /// 进度条跳一下会让人以为数据错了。
  static const Duration progress = Duration(milliseconds: 420);

  /// 平缓收敛，最不容易看出「动画感」。
  static const Curve easeOutQuart = Cubic(0.25, 1, 0.5, 1);

  /// 稍快一点，用在需要「干脆」的地方（表头、进度）。
  static const Curve easeOutQuint = Cubic(0.22, 1, 0.36, 1);

  /// 最果断，用在入场的第一帧位移。
  static const Curve easeOutExpo = Cubic(0.16, 1, 0.3, 1);

  /// 系统「减弱动画」是否开启（Android 移除动画 / iOS 减弱动态效果）。
  ///
  /// 开了之后：位移与渐显一律退化成直接显示；
  /// 颜色、进度这类不引起前庭不适的过渡保留——它们传达信息，不是装饰。
  static bool reduced(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;
}

/// 入场编组的控制器：**整组只开一个 [AnimationController]**。
///
/// 为什么不给每个条目各自一个控制器：列表一屏十几张卡片，
/// 每张都挂一个 ticker，首帧就要多跑十几个 TickerFuture，
/// 入场的成本会超过入场本身的价值。这里用一个控制器，
/// 各条目按 index 从同一条时间线上切自己那一段。
class EntranceGroup extends StatefulWidget {
  const EntranceGroup({
    super.key,
    required this.child,
    this.stagger = 0.055,
    this.maxStaggered = 7,
  });

  final Widget child;

  /// 相邻两项的起始时间差，占整段时长的比例。
  static const double span = 0.42;

  final double stagger;

  /// 参与错峰的最大项数。超出的项与最后一项同时进场——
  /// 它们本来就在屏幕外，错峰也看不见，白等时间。
  final int maxStaggered;

  @override
  State<EntranceGroup> createState() => _EntranceGroupState();
}

class _EntranceGroupState extends State<EntranceGroup>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: AppMotion.entrance,
  );

  @override
  void initState() {
    super.initState();
    // initState 里 forward 是安全的：控制器只会在下一帧开始 tick，
    // 不会在 build 阶段同步触发重建。
    _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _EntranceScope(
      controller: _c,
      stagger: widget.stagger,
      maxStaggered: widget.maxStaggered,
      child: widget.child,
    );
  }
}

class _EntranceScope extends InheritedWidget {
  const _EntranceScope({
    required this.controller,
    required this.stagger,
    required this.maxStaggered,
    required super.child,
  });

  final AnimationController controller;
  final double stagger;
  final int maxStaggered;

  @override
  bool updateShouldNotify(_EntranceScope old) =>
      controller != old.controller ||
      stagger != old.stagger ||
      maxStaggered != old.maxStaggered;
}

/// 组内第 [index] 项的入场：淡入 + 从下方位移归位。
///
/// 找不到 [EntranceGroup] 时直接返回原样，方便在任意上下文里安全使用。
class Entrance extends StatelessWidget {
  const Entrance({
    super.key,
    required this.index,
    required this.child,
    this.offsetY = 12,
  });

  final int index;
  final Widget child;

  /// 起始下移距离。超过 16dp 就像「从天而降」，对这个 App 太热闹。
  final double offsetY;

  @override
  Widget build(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<_EntranceScope>();
    if (scope == null) return child;
    // 减弱动画：直接给终态，连 AnimatedBuilder 都不挂。
    if (AppMotion.reduced(context)) return child;

    final capped = index < 0
        ? 0
        : (index > scope.maxStaggered ? scope.maxStaggered : index);
    final start = capped * scope.stagger;

    return AnimatedBuilder(
      animation: scope.controller,
      // child 传进来只拼一次，每帧只重建 Opacity + Transform 这层壳，
      // 卡片内部不会跟着逐帧重建。
      child: child,
      builder: (context, child) {
        final raw = (scope.controller.value - start) / EntranceGroup.span;
        final t = raw.clamp(0.0, 1.0);
        final e = AppMotion.easeOutQuart.transform(t);
        return Opacity(
          opacity: e,
          child: Transform.translate(
            offset: Offset(0, offsetY * (1 - e)),
            child: child,
          ),
        );
      },
    );
  }
}

/// 单独挂载时的入场（不进 [EntranceGroup] 的零散块）。
///
/// 典型场景：数据到位后才第一次构建的块（进度卡、全部完成横幅）。
/// 只在挂载那一次播，之后重建不重播；被移除再挂回来才会再播一次。
class RevealOnMount extends StatefulWidget {
  const RevealOnMount({
    super.key,
    required this.child,
    this.offsetY = 8,
    this.scaleFrom = 0.985,
    this.duration = AppMotion.base,
  });

  final Widget child;
  final double offsetY;
  final double scaleFrom;
  final Duration duration;

  @override
  State<RevealOnMount> createState() => _RevealOnMountState();
}

class _RevealOnMountState extends State<RevealOnMount>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.duration,
  );

  @override
  void initState() {
    super.initState();
    _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (AppMotion.reduced(context)) return widget.child;
    return AnimatedBuilder(
      animation: _c,
      child: widget.child,
      builder: (context, child) {
        final e = AppMotion.easeOutQuint.transform(_c.value);
        return Opacity(
          opacity: e,
          child: Transform.translate(
            offset: Offset(0, widget.offsetY * (1 - e)),
            child: Transform.scale(
              scale: widget.scaleFrom + (1 - widget.scaleFrom) * e,
              child: child,
            ),
          ),
        );
      },
    );
  }
}
