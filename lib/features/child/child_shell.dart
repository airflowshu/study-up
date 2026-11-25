import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../state/app_state.dart';
import '../../widgets/common.dart';
import '../../widgets/responsive_scaffold.dart';
import 'child_calendar_page.dart';
import 'child_me_page.dart';
import 'child_today_page.dart';

/// 孩子端外壳：今日 / 日历 / 我的。
class ChildShell extends StatefulWidget {
  const ChildShell({super.key});

  @override
  State<ChildShell> createState() => _ChildShellState();
}

class _ChildShellState extends State<ChildShell> {
  int _index = 0;

  static const _items = [
    NavItem(
      icon: Icons.today_outlined,
      activeIcon: Icons.today_rounded,
      label: '今日',
    ),
    NavItem(
      icon: Icons.calendar_month_outlined,
      activeIcon: Icons.calendar_month_rounded,
      label: '日历',
    ),
    NavItem(
      icon: Icons.person_outline,
      activeIcon: Icons.person_rounded,
      label: '我的',
    ),
  ];

  static const _titles = ['今日作业', '作业日历', '我的'];

  @override
  Widget build(BuildContext context) {
    final child = AppStateScope.of(context).loggedChild;
    if (child == null) {
      return const Scaffold(body: EmptyState(title: '登录状态失效，请重新进入'));
    }

    return ResponsiveScaffold(
      title: _titles[_index],
      items: _items,
      index: _index,
      onChanged: (i) => setState(() => _index = i),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 16),
          child: ChildAvatar(child: child, size: 30),
        ),
      ],
      railLeading: Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: ChildAvatar(child: child, size: 34),
      ),
      builder: (context, device) {
        switch (_index) {
          case 0:
            return ChildTodayPage(device: device, child: child);
          case 1:
            return ChildCalendarPage(device: device, child: child);
          default:
            return ChildMePage(child: child);
        }
      },
    );
  }
}

/// 孩子端统一的刷新提示条。
class SyncHint extends StatelessWidget {
  const SyncHint({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.refresh, size: 13, color: AppColors.textTertiary),
          SizedBox(width: 4),
          Text(
            '下拉刷新',
            style: TextStyle(fontSize: 11, color: AppColors.textTertiary),
          ),
        ],
      ),
    );
  }
}
