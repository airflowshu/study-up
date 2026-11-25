import 'package:flutter/material.dart';

import '../core/breakpoints.dart';
import '../core/motion.dart';
import '../core/theme.dart';

class NavItem {
  const NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
  });

  final IconData icon;
  final IconData activeIcon;
  final String label;
}

/// 三档响应式外壳。
/// compact（<600dp）：底部导航 + 单列
/// medium（600–839dp）：底部导航 + 内容 560dp 居中
/// expanded（≥840dp）：左侧 NavigationRail + 内容自行分栏
class ResponsiveScaffold extends StatelessWidget {
  const ResponsiveScaffold({
    super.key,
    required this.title,
    required this.items,
    required this.index,
    required this.onChanged,
    required this.builder,
    this.actions,
    this.railLeading,
    this.floatingActionButton,
  });

  final String title;
  final List<NavItem> items;
  final int index;
  final ValueChanged<int> onChanged;
  final Widget Function(BuildContext context, DeviceType device) builder;
  final List<Widget>? actions;
  final Widget? railLeading;
  final Widget? floatingActionButton;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final device = deviceTypeOf(width);

    if (device == DeviceType.expanded) {
      return Scaffold(
        floatingActionButton: floatingActionButton,
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: index,
              onDestinationSelected: onChanged,
              leading: railLeading ??
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    child: Text(
                      title,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
              destinations: [
                for (final item in items)
                  NavigationRailDestination(
                    icon: Icon(item.icon),
                    selectedIcon: Icon(item.activeIcon),
                    label: Text(item.label),
                  ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: _content(context, device)),
          ],
        ),
      );
    }

    return Scaffold(
      floatingActionButton: floatingActionButton,
      appBar: AppBar(title: Text(title), actions: actions),
      body: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: device == DeviceType.medium ? 560 : double.infinity,
          ),
          child: _content(context, device),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: onChanged,
        destinations: [
          for (final item in items)
            NavigationDestination(
              icon: Icon(item.icon),
              selectedIcon: Icon(item.activeIcon),
              label: item.label,
            ),
        ],
      ),
    );
  }

  /// 页签切换的过渡。
  ///
  /// **只做「进」不做「出」**，这是真机测出来的结论：
  /// 用 AnimatedSwitcher 做交叉淡入时，两屏各占一半不透明度叠在一起，
  /// 列表和图表糊成一团双影（连拍里抓到的就是一帧两页叠字）。而真正做成
  /// 「先出后进」又会留一段空屏闪一下。
  ///
  /// 现在的做法：旧屏直接撤掉，新屏从下方 10dp 淡入归位。画面上永远只有
  /// 一层内容，既没有双影也没有空帧，还跟上「点下去就该换」的直觉。
  ///
  /// key 挂 [index]：同一个页面重复构建时不重播，换页签才播。
  Widget _content(BuildContext context, DeviceType device) {
    final page = builder(context, device);
    if (AppMotion.reduced(context)) return page;
    return KeyedSubtree(
      key: ValueKey<int>(index),
      child: RevealOnMount(
        duration: AppMotion.base,
        offsetY: 10,
        // 整屏缩放会让人以为页面在飞，这里只要位移和透明度。
        scaleFrom: 1,
        child: page,
      ),
    );
  }
}
