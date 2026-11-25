import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/theme.dart';
import 'features/child/child_shell.dart';
import 'features/onboarding/role_select_page.dart';
import 'features/parent/parent_shell.dart';
import 'state/app_state.dart';
import 'widgets/sync_notice_bar.dart';
import 'widgets/update_gate.dart';

class HomeworkApp extends StatelessWidget {
  const HomeworkApp({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    // 外层订阅一次：切换外观时 MaterialApp 必须整体重建，
    // 才能把新的 theme / darkTheme 下发下去。
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) => AppStateScope(
        state: state,
        child: MaterialApp(
          title: '家庭作业',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: switch (state.themeMode) {
            AppThemeMode.system => ThemeMode.system,
            AppThemeMode.light => ThemeMode.light,
            AppThemeMode.dark => ThemeMode.dark,
          },
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          // 包在 Navigator 外面：这样 push 出来的编辑页、详情页也能看到离线提示，
          // 而不是只有 tab 首页有。用户在编辑页保存时断网，正是最需要知道的时候。
          builder: (context, child) =>
              _AppFrame(child: child ?? const SizedBox.shrink()),
          home: const UpdateGate(child: _Root()),
        ),
      ),
    );
  }
}

/// 全屏外壳：顶部全局同步提示条 + 下方路由内容。
///
/// 提示条自己让出状态栏高度，所以下面要 removeTop，否则会多留一条白边。
/// edge-to-edge 之后状态栏是透明的，外层这层底色就是状态栏看到的颜色。
class _AppFrame extends StatelessWidget {
  const _AppFrame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.pageBg,
      child: Column(
        children: [
          const SyncNoticeBar(),
          Expanded(
            child: MediaQuery.removePadding(
              context: context,
              removeTop: true,
              child: child,
            ),
          ),
        ],
      ),
    );
  }
}

/// 根路由：按登录状态直接决定显示哪个界面。
/// 用状态驱动而不是 Navigator 跳转，避免身份切换后栈里残留旧页面。
class _Root extends StatelessWidget {
  const _Root();

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);

    if (!state.ready) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    switch (state.role) {
      case Role.parent:
        return const ParentShell();
      case Role.child:
        return const ChildShell();
      case Role.none:
        return const RoleSelectPage();
    }
  }
}
