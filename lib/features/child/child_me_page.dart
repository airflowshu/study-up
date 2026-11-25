import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/cloud/update_service.dart';
import '../../models/models.dart';
import '../../state/app_state.dart';
import '../../widgets/common.dart';
import '../../widgets/update_gate.dart';

/// 孩子端「我的」：看看自己是谁、退出登录。
class ChildMePage extends StatelessWidget {
  const ChildMePage({super.key, required this.child});

  final Child child;

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
      children: [
        Center(
          child: Column(
            children: [
              ChildAvatar(child: child, size: 72),
              const SizedBox(height: 12),
              Text(
                child.name,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                state.family?.name ?? '',
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 32),
        Container(
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            children: [
              ListTile(
                leading: Icon(Icons.family_restroom,
                    size: 20, color: AppColors.textSecondary),
                title: const Text('所属家庭', style: TextStyle(fontSize: 14)),
                trailing: Text(
                  state.family?.name ?? '—',
                  style: TextStyle(
                      fontSize: 13, color: AppColors.textSecondary),
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: Icon(Icons.info_outline,
                    size: 20, color: AppColors.textSecondary),
                title: const Text('版本', style: TextStyle(fontSize: 14)),
                trailing: AnimatedBuilder(
                  animation: UpdateService.instance,
                  builder: (_, __) => Text(
                    UpdateService.instance.currentVersion,
                    style: TextStyle(
                        fontSize: 13, color: AppColors.textSecondary),
                  ),
                ),
                onTap: () async {
                  final result = await UpdateService.instance.check();
                  if (!context.mounted) return;
                  if (result == UpdateCheckResult.available) {
                    final release = UpdateService.instance.available;
                    if (release != null) {
                      await showUpdateDialog(context, release);
                    }
                    return;
                  }
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        result == UpdateCheckResult.upToDate
                            ? '已经是最新版本'
                            : '检查失败，稍后再试',
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        OutlinedButton.icon(
          onPressed: () async {
            final ok = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('退出登录？'),
                content: const Text('退出后要重新输入名字才能进来。'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    style: FilledButton.styleFrom(
                        minimumSize: const Size(80, 40)),
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('退出'),
                  ),
                ],
              ),
            );
            if (ok == true) await state.logoutChild();
          },
          icon: const Icon(Icons.logout, size: 18),
          label: const Text('退出登录'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 46),
            foregroundColor: AppColors.danger,
            side: BorderSide(color: AppColors.border),
          ),
        ),
        const SizedBox(height: 28),
        Center(
          child: Text(
            '作业会每天更新，记得写完打勾',
            style: TextStyle(fontSize: 11, color: AppColors.textTertiary),
          ),
        ),
      ],
    );
  }
}
