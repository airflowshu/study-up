import 'package:flutter/material.dart';

import '../../core/breakpoints.dart';
import '../../core/theme.dart';
import '../../state/app_state.dart';
import 'child_login_page.dart';
import 'create_family_page.dart';

/// 启动页：选身份。已登录过则直接进对应界面（由 App 根据状态决定是否显示本页）。
class RoleSelectPage extends StatelessWidget {
  const RoleSelectPage({super.key});

  @override
  Widget build(BuildContext context) {
    final device = deviceTypeOf(MediaQuery.sizeOf(context).width);
    final state = AppStateScope.of(context);

    final brand = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: AppColors.seed,
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Icon(Icons.menu_book_rounded,
              color: AppColors.onAccent, size: 30),
        ),
        const SizedBox(height: 20),
        Text(
          '家庭作业',
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '家长布置，孩子查看\n今天要做什么，打开就知道',
          style: TextStyle(
            fontSize: 14,
            height: 1.6,
            color: AppColors.textSecondary,
          ),
        ),
      ],
    );

    final actions = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _RoleCard(
          icon: Icons.edit_note_rounded,
          color: AppColors.seed,
          title: '我是家长',
          subtitle: '布置作业、管理孩子、看完成情况',
          onTap: () => _enterParent(context, state),
        ),
        const SizedBox(height: 14),
        _RoleCard(
          icon: Icons.child_care_rounded,
          color: AppColors.success,
          title: '我是孩子',
          subtitle: '输入名字，查看今天的作业',
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ChildLoginPage()),
            );
          },
        ),
        const SizedBox(height: 18),
        Text(
          '数据先存本机，联网后自动同步',
          style: TextStyle(fontSize: 12, color: AppColors.textTertiary),
        ),
      ],
    );

    if (device == DeviceType.expanded) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 64),
            child: Row(
              children: [
                Expanded(child: brand),
                const SizedBox(width: 64),
                SizedBox(width: 380, child: actions),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 56, 24, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              brand,
              const SizedBox(height: 44),
              actions,
            ],
          ),
        ),
      ),
    );
  }
}

/// 进入家长端。已有家庭时要过一道家庭码，避免孩子退出后直接钻进家长端。
Future<void> _enterParent(BuildContext context, AppState state) async {
  if (!state.hasFamily) {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const CreateFamilyPage()),
    );
    return;
  }
  if (await state.parentVerified) {
    await state.setRole(Role.parent);
    return;
  }

  final controller = TextEditingController();
  String? error;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        title: const Text('输入家庭码'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '家庭码在家长端「设置」里，6 位字符。验证一次后就不用再输了。',
              style: TextStyle(
                fontSize: 12,
                height: 1.6,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: controller,
              autofocus: true,
              maxLength: 6,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                hintText: '例如 7K3M9Q',
                counterText: '',
                errorText: error,
              ),
              onSubmitted: (_) async {
                final r = await state.verifyParent(code: controller.text);
                if (ctx.mounted) Navigator.pop(ctx, r);
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(88, 40)),
            onPressed: () async {
              final r = await state.verifyParent(code: controller.text);
              if (!r) {
                setLocal(() => error = '家庭码不对');
                return;
              }
              if (ctx.mounted) Navigator.pop(ctx, true);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    ),
  );
  if (ok == true) await state.setRole(Role.parent);
}

class _RoleCard extends StatelessWidget {
  const _RoleCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.card,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: Icon(icon, color: color, size: 26),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right,
                  color: AppColors.textTertiary, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}
