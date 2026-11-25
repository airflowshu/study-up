import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 一套具名语义色。
///
/// 为什么不是直接用 `ColorScheme`：这个 App 的配色里有一批
/// Material 没有对应槽位的语义（卡内次级底、已完成底、学科色），
/// 全部硬塞进 ColorScheme 只会让调用点变成 `scheme.surfaceContainerHigh`
/// 这种看不懂的名字。这里保持自己的命名，深浅两套各自完整。
class AppPalette {
  const AppPalette({
    required this.primary,
    required this.primaryInk,
    required this.primarySoft,
    required this.primaryBorder,
    required this.onAccent,
    required this.pageBg,
    required this.card,
    required this.navBg,
    required this.inputFill,
    required this.surface2,
    required this.surface3,
    required this.border,
    required this.borderStrong,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.textDisabled,
    required this.doneBg,
    required this.success,
    required this.successInk,
    required this.successSoft,
    required this.warning,
    required this.warningInk,
    required this.warningSoft,
    required this.danger,
    required this.dangerInk,
    required this.dangerSoft,
    required this.gradientA,
    required this.gradientB,
  });

  final Color primary;

  /// 主色用在**文字和图标**上时的色号，需要比 [primary] 更深/更亮一档
  /// 才能压得住底色。浅色下更深，深色下更亮。
  final Color primaryInk;
  final Color primarySoft;
  final Color primaryBorder;

  /// 压在主色块上的前景色（按钮文字、图标）。
  /// 浅色主色配白字；深色主题的主色偏亮，再配白字对比度不够，改用深色字。
  final Color onAccent;

  final Color pageBg;
  final Color card;
  final Color navBg;
  final Color inputFill;

  /// 次级底：卡片内的浅底块、分段控件轨道、头像底等。
  final Color surface2;

  /// 更深的次级底：进度条轨道、未选中块。
  final Color surface3;

  final Color border;
  final Color borderStrong;

  /// 文字四级。
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;
  final Color textDisabled;

  /// 已完成卡片底，不再靠整卡 opacity 变淡。
  final Color doneBg;

  final Color success;
  final Color successInk;
  final Color successSoft;
  final Color warning;
  final Color warningInk;
  final Color warningSoft;
  final Color danger;
  final Color dangerInk;
  final Color dangerSoft;

  /// 浅蓝紫渐变卡片的起止色（今日概览、统计块）。
  final Color gradientA;
  final Color gradientB;
}

/// 浅色：原本就是这套，不动。
const _lightPalette = AppPalette(
  primary: Color(0xFF5B6BF5),
  primaryInk: Color(0xFF4453D8),
  primarySoft: Color(0xFFEDF0FF),
  primaryBorder: Color(0xFFDDE3F7),
  onAccent: Color(0xFFFFFFFF),
  pageBg: Color(0xFFF4F6FB),
  card: Color(0xFFFFFFFF),
  navBg: Color(0xFFFFFFFF),
  inputFill: Color(0xFFFFFFFF),
  surface2: Color(0xFFF7F8FC),
  surface3: Color(0xFFEEF1F8),
  border: Color(0xFFE6E9F2),
  borderStrong: Color(0xFFD6DBE8),
  textPrimary: Color(0xFF171A22),
  textSecondary: Color(0xFF5B6273),
  textTertiary: Color(0xFF767C8C),
  textDisabled: Color(0xFFA6ACBB),
  doneBg: Color(0xFFFCFCFE),
  success: Color(0xFF10B981),
  successInk: Color(0xFF0E9F6E),
  successSoft: Color(0xFFE7F8F1),
  warning: Color(0xFFF59E0B),
  warningInk: Color(0xFFB26A05),
  warningSoft: Color(0xFFFEF3E2),
  danger: Color(0xFFEF4444),
  dangerInk: Color(0xFFDC2626),
  dangerSoft: Color(0xFFFDECEC),
  gradientA: Color(0xFFF7F9FF),
  gradientB: Color(0xFFEDF0FF),
);

/// 深色：不是把浅色反相，而是重新定一套。
///
/// 三条原则：
/// 1. 层级靠**亮度差**而不是阴影——深色下阴影几乎看不见，卡片的边界由
///    pageBg < card < surface2 < surface3 的递进关系撑起来。
/// 2. 主色整体提亮约 12%，否则 #5B6BF5 压在 #101218 上会发灰。
/// 3. 强调色的 softly 版本一律降饱和、降亮度，避免在暗底上发光刺眼。
const _darkPalette = AppPalette(
  primary: Color(0xFF7C8AFF),
  primaryInk: Color(0xFF9AA5FF),
  primarySoft: Color(0xFF232A45),
  primaryBorder: Color(0xFF2E3655),
  onAccent: Color(0xFF10121A),
  pageBg: Color(0xFF101218),
  card: Color(0xFF181B23),
  navBg: Color(0xFF181B23),
  inputFill: Color(0xFF1E212A),
  surface2: Color(0xFF1E212A),
  surface3: Color(0xFF262A35),
  border: Color(0xFF2A2E3A),
  borderStrong: Color(0xFF3A3F4D),
  textPrimary: Color(0xFFECEEF4),
  textSecondary: Color(0xFFA7AEBE),
  textTertiary: Color(0xFF8A91A1),
  textDisabled: Color(0xFF5D6474),
  doneBg: Color(0xFF15171E),
  success: Color(0xFF34D399),
  successInk: Color(0xFF4ADE80),
  successSoft: Color(0xFF122F26),
  warning: Color(0xFFFBBF24),
  warningInk: Color(0xFFFCD34D),
  warningSoft: Color(0xFF33270E),
  danger: Color(0xFFF87171),
  dangerInk: Color(0xFFFCA5A5),
  dangerSoft: Color(0xFF331B1B),
  gradientA: Color(0xFF1A1E2B),
  gradientB: Color(0xFF212639),
);

/// 全局配色。
///
/// **为什么是静态可变而不是 `Theme.of(context)`**：
/// 改造前全项目 266 处直接引用 `AppColors.xxx`，改成 context 取色要动
/// 每一个调用点，收益只是「更 Flutter」，代价是几百处改动带来的回归风险。
/// 这里保留原有调用形式，把「当前是哪一套」做成类级别的状态，
/// 由 [use] 在主题变化时统一切换。
///
/// 代价是：**任何含动态色的 widget 都不能是 const**，否则 widget 实例相等，
/// Element 会跳过 rebuild，颜色就停在旧值上。项目里凡是 const 构造里引用了
/// 动态色的地方都已经去掉 const。
///
/// 切换时机由 AppState 控制，见 `applyThemeMode`。
class AppColors {
  AppColors._();

  static AppPalette _palette = _lightPalette;

  /// 当前生效的亮度。深色主题下为 [Brightness.dark]。
  static Brightness brightness = Brightness.light;

  static bool get isDark => brightness == Brightness.dark;

  /// 切换到指定亮度对应的调色板。只改内存，不负责触发重建。
  static void use(Brightness b) {
    brightness = b;
    _palette = b == Brightness.dark ? _darkPalette : _lightPalette;
  }

  /// 当前调色板，给需要整体取色的地方（例如自定义绘制）用。
  static AppPalette get palette => _palette;

  /// 主色（蓝紫）。seed 保留为别名——老代码里 AppColors.seed 还到处在用。
  static Color get seed => _palette.primary;
  static Color get primary => _palette.primary;

  /// 主色用在**文字和图标**上时要更深/更亮一档，否则对比度不够。
  static Color get primaryInk => _palette.primaryInk;
  static Color get primarySoft => _palette.primarySoft;
  static Color get primaryBorder => _palette.primaryBorder;

  /// 压在主色/强调色块上的前景色。
  static Color get onAccent => _palette.onAccent;

  static Color get pageBg => _palette.pageBg;
  static Color get card => _palette.card;
  static Color get navBg => _palette.navBg;
  static Color get inputFill => _palette.inputFill;

  /// 次级底：卡片内的浅底块、分段控件轨道、头像底等，统一取代原先散落的
  /// #F2F3F7 / #EDEFF5 / #EDF1FF / #F7F9FF。
  static Color get surface2 => _palette.surface2;

  /// 更深的次级底：进度条轨道、未选中块。
  static Color get surface3 => _palette.surface3;

  static Color get border => _palette.border;
  static Color get borderStrong => _palette.borderStrong;

  /// 文字四级。
  static Color get textPrimary => _palette.textPrimary;
  static Color get textSecondary => _palette.textSecondary;
  static Color get textTertiary => _palette.textTertiary;
  static Color get textDisabled => _palette.textDisabled;

  /// 已完成/未完成底：已完成卡片用这一档，不再靠整卡 opacity 变淡。
  static Color get doneBg => _palette.doneBg;

  static Color get success => _palette.success;
  static Color get successInk => _palette.successInk;
  static Color get successSoft => _palette.successSoft;
  static Color get warning => _palette.warning;
  static Color get warningInk => _palette.warningInk;
  static Color get warningSoft => _palette.warningSoft;
  static Color get danger => _palette.danger;
  static Color get dangerInk => _palette.dangerInk;
  static Color get dangerSoft => _palette.dangerSoft;

  static Color get gradientA => _palette.gradientA;
  static Color get gradientB => _palette.gradientB;

  /// 学科固定配色，保证同一学科各页面颜色一致。
  ///
  /// 主色换成蓝紫后，语文与科学这两支冷色要跟它拉开：
  /// 语文走更饱和的正蓝、科学走更深的紫，避免和主色在色相上撞车。
  ///
  /// 这组**不随明暗切换**：八个色相在深浅两种底上都够鲜明，
  /// 强行做两套只会让家长在两端看到不同的学科色，反而失去识别意义。
  static const subjectPalette = <String, Color>{
    '语文': Color(0xFF2F7FF3),
    '数学': Color(0xFF10B981),
    '英语': Color(0xFFF59E0B),
    '科学': Color(0xFF7C3AED),
    '道法': Color(0xFFEF4444),
    '体育': Color(0xFF06B6D4),
    '美术': Color(0xFFEC4899),
    '音乐': Color(0xFF14B8A6),
  };

  /// 孩子头像的备选底色。同上，不随明暗切换。
  static const childPalette = <Color>[
    Color(0xFF5B6BF5),
    Color(0xFF10B981),
    Color(0xFFF59E0B),
    Color(0xFF7C3AED),
    Color(0xFFEC4899),
    Color(0xFF06B6D4),
  ];

  static Color ofSubject(String subject) =>
      subjectPalette[subject] ?? const Color(0xFF767C8C);

  /// 深色下头像底色整体压暗，否则纯色圆盘在暗背景上过于跳。
  static Color childColor(int index) {
    final base = childPalette[index % childPalette.length];
    if (!isDark) return base;
    return Color.alphaBlend(Colors.black.withValues(alpha: 0.22), base);
  }
}

/// 圆角五档。原先 6/8/10/12/14/16/20 七档并存，同类控件边界模糊。
class AppRadius {
  static const double xs = 6; // 标签、徽标
  static const double sm = 10; // 输入框、图块
  static const double md = 14; // 卡片、按钮
  static const double lg = 20; // 大容器、底部弹层
  static const double full = 999; // 胶囊、进度条
}

/// 间距：一律 4 的倍数。页面边距 16、卡片间距 12、分区之间 24。
class AppSpace {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

/// 阴影三级。原先全 App 无阴影，灰底上的白卡全靠 1px 描边撑边界。
///
/// 深色下阴影本身看不出来，卡片边界靠 border 与 card/pageBg 的亮度差，
/// 这里不额外做两套：深浅共用同一组阴影不会出错，只是深色下不起作用。
class AppShadow {
  static const s1 = <BoxShadow>[
    BoxShadow(color: Color(0x0D171A16), blurRadius: 2, offset: Offset(0, 1)),
  ];
  static const s2 = <BoxShadow>[
    BoxShadow(color: Color(0x14171A16), blurRadius: 12, offset: Offset(0, 4)),
  ];
  static const s3 = <BoxShadow>[
    BoxShadow(color: Color(0x24171A16), blurRadius: 28, offset: Offset(0, 10)),
  ];
}

/// 字号六档（原先 11/12/13/14/15/16/17/20/22 九档，相邻档肉眼无差别）。
class AppText {
  static const double caption = 11; // 辅助说明、字数、徽标
  static const double label = 13; // 标签、次级信息
  static const double body = 15; // 正文、输入框、列表标题
  static const double title = 17; // 页面标题、详情正文
  static const double headline = 22; // 区块大标题（孩子端今日）
  static const double display = 32; // 统计数字
}

/// 系统状态栏样式。深色主题要浅色图标，否则时间和电量在深底上看不见。
SystemUiOverlayStyle appOverlayStyle() => SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness:
          AppColors.isDark ? Brightness.light : Brightness.dark, // Android
      statusBarBrightness:
          AppColors.isDark ? Brightness.dark : Brightness.light, // iOS
      systemNavigationBarColor: AppColors.pageBg,
      systemNavigationBarIconBrightness:
          AppColors.isDark ? Brightness.light : Brightness.dark,
    );

/// 把当前调色板对应的状态栏样式下发给系统。
///
/// 切换主题时必须重发一次：状态栏是系统窗口，不会跟着 Flutter 重建。
void applySystemOverlay() {
  SystemChrome.setSystemUIOverlayStyle(appOverlayStyle());
}

class AppTheme {
  static ThemeData light() => _build(Brightness.light);

  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.primary,
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme.copyWith(
        primary: AppColors.primary,
        onPrimary: AppColors.onAccent,
        surface: AppColors.card,
        onSurface: AppColors.textPrimary,
        error: AppColors.danger,
      ),
      scaffoldBackgroundColor: AppColors.pageBg,
      canvasColor: AppColors.pageBg,
      fontFamily: null,
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.pageBg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        // 系统状态栏是画在 Flutter 之上的不透明层，用 ColoredBox 涂是涂不到的，
        // 只能从这里下发。不写的话系统跟随深色模式，会出现黑底白字，
        // 跟界面完全脱节。
        systemOverlayStyle: appOverlayStyle(),
        titleTextStyle: TextStyle(
          color: AppColors.textPrimary,
          fontSize: AppText.title,
          fontWeight: FontWeight.w600,
        ),
        iconTheme: IconThemeData(color: AppColors.textPrimary),
      ),
      cardTheme: CardTheme(
        color: AppColors.card,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          side: BorderSide(color: AppColors.border),
        ),
      ),
      dialogTheme: DialogTheme(
        backgroundColor: AppColors.card,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: AppColors.card,
        surfaceTintColor: Colors.transparent,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: AppColors.navBg,
        indicatorColor: AppColors.primarySoft,
        elevation: 0,
        height: 62,
        labelTextStyle: WidgetStateProperty.all(
          TextStyle(
            fontSize: AppText.caption,
            fontWeight: FontWeight.w500,
            color: AppColors.textSecondary,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            color: selected ? AppColors.primaryInk : AppColors.textTertiary,
            size: 22,
          );
        }),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: AppColors.navBg,
        indicatorColor: AppColors.primarySoft,
        labelType: NavigationRailLabelType.all,
        unselectedLabelTextStyle: TextStyle(color: AppColors.textSecondary),
        selectedLabelTextStyle: TextStyle(color: AppColors.primaryInk),
      ),
      dividerTheme: DividerThemeData(
        color: AppColors.border,
        thickness: 1,
        space: 1,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(50),
          backgroundColor: AppColors.primary,
          foregroundColor: AppColors.onAccent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          textStyle: const TextStyle(
            fontSize: AppText.body,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(50),
          foregroundColor: AppColors.textPrimary,
          side: BorderSide(color: AppColors.border),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.primaryInk,
          textStyle: const TextStyle(
            fontSize: AppText.label,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.inputFill,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          borderSide: BorderSide(color: AppColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          borderSide: BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          borderSide: BorderSide(color: AppColors.primary, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          borderSide: BorderSide(color: AppColors.danger),
        ),
        hintStyle: TextStyle(color: AppColors.textDisabled),
        labelStyle: TextStyle(color: AppColors.textSecondary),
      ),
      checkboxTheme: CheckboxThemeData(
        side: BorderSide(color: AppColors.borderStrong, width: 1.5),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected)
                ? AppColors.onAccent
                : AppColors.textTertiary),
        trackColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected)
                ? AppColors.primary
                : AppColors.surface3),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: dark ? AppColors.surface3 : const Color(0xFF2B2F3A),
        contentTextStyle: const TextStyle(color: Colors.white),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
      ),
      iconTheme: IconThemeData(color: AppColors.textSecondary),
      extensions: const [],
    );
  }
}
