import 'package:flutter/material.dart';

import '../../core/breakpoints.dart';
import '../../core/theme.dart';
import '../../state/app_state.dart';
import '../../widgets/responsive_scaffold.dart';
import 'history_page.dart';
import 'parent_home_page.dart';
import 'parent_stats_page.dart';
import 'settings_page.dart';

/// 家长端外壳：布置 / 历史 / 统计 / 设置。
class ParentShell extends StatefulWidget {
  const ParentShell({super.key});

  @override
  State<ParentShell> createState() => _ParentShellState();
}

class _ParentShellState extends State<ParentShell> {
  int _index = 0;

  static const _items = [
    NavItem(
      icon: Icons.edit_note_outlined,
      activeIcon: Icons.edit_note_rounded,
      label: '布置',
    ),
    NavItem(
      icon: Icons.history_outlined,
      activeIcon: Icons.history_rounded,
      label: '历史',
    ),
    NavItem(
      icon: Icons.insights_outlined,
      activeIcon: Icons.insights_rounded,
      label: '统计',
    ),
    NavItem(
      icon: Icons.settings_outlined,
      activeIcon: Icons.settings_rounded,
      label: '设置',
    ),
  ];

  static const _titles = ['布置作业', '历史作业', '统计', '设置'];

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final child = state.activeChild;

    // 一个孩子都没有时，先引导去加孩子，避免出现空壳页面
    if (child == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('布置作业')),
        body: SettingsPage(device: deviceTypeOf(MediaQuery.sizeOf(context).width)),
      );
    }

    return ResponsiveScaffold(
      title: _titles[_index],
      items: _items,
      index: _index,
      onChanged: (i) => setState(() => _index = i),
      railLeading: Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Text(
          _titles[_index],
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: AppColors.textSecondary,
          ),
        ),
      ),
      builder: (context, device) {
        switch (_index) {
          case 0:
            return ParentHomePage(device: device);
          case 1:
            return HistoryPage(device: device);
          case 2:
            return ParentStatsPage(device: device);
          default:
            return SettingsPage(device: device);
        }
      },
    );
  }
}
