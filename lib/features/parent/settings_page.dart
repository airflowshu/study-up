import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/breakpoints.dart';
import '../../core/theme.dart';
import '../../data/cloud/sync_service.dart';
import '../../data/cloud/update_service.dart';
import '../../data/repository.dart';
import '../../models/models.dart';
import '../../state/app_state.dart';
import '../../widgets/common.dart';
import '../../widgets/update_gate.dart';

/// 家长端设置：家庭信息、孩子管理、身份切换。
/// 同步是自动的，这里只在异常时给一条提示。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.device});

  final DeviceType device;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _repo = Repository.instance;
  bool _checkingUpdate = false;

  @override
  void initState() {
    super.initState();
    // 这个数字只在同步结束时刷新，中途打开设置页可能读到旧值
    unawaited(SyncService.instance.refreshPending());
    // 版本号要异步读，先取一次，取到后靠 listenable 刷新
    unawaited(UpdateService.instance.ensureLoaded());
  }

  Future<void> _checkUpdate() async {
    setState(() => _checkingUpdate = true);
    final result = await UpdateService.instance.check();
    if (!mounted) return;
    setState(() => _checkingUpdate = false);
    if (result == UpdateCheckResult.available) {
      final release = UpdateService.instance.available;
      if (release != null) await showUpdateDialog(context, release);
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result == UpdateCheckResult.upToDate ? '已经是最新版本' : '检查失败，稍后再试',
        ),
      ),
    );
  }

  /// 底部版本区：版本号 + 检查更新入口。
  ///
  /// 不做成设置项列表里的一行，是因为它不属于「配置」，属于「关于」；
  /// 放在最底部、字号最小，符合用户对版本信息的预期位置。
  Widget _updateSection() {
    return AnimatedBuilder(
      animation: UpdateService.instance,
      builder: (ctx, _) {
        final svc = UpdateService.instance;
        final release = svc.available;
        return Column(
          children: [
            Text(
              '家庭作业 v${svc.currentVersion}',
              style: TextStyle(fontSize: 11, color: AppColors.textTertiary),
            ),
            TextButton(
              onPressed: _checkingUpdate ? null : _checkUpdate,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                minimumSize: const Size(0, 32),
              ),
              child: Text(
                _checkingUpdate
                    ? '检查中…'
                    : (release != null
                        ? '有新版本 v${release.versionName}'
                        : '检查更新'),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: release != null
                      ? AppColors.primaryInk
                      : AppColors.textTertiary,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 同步状态条：正常时返回空，不给界面留占位。
  ///
  /// 只保留两种需要家长知道的状态：
  /// - 有数据还没传上去（离线期间布置的作业，孩子那边还看不到）
  /// - 同步失败（需要重试或检查网络）
  ///
  /// 不显示请求次数、流量、上次成功时间——那是开发者的账本，不是家长的信息。
  Widget _syncNotice(AppState state) {
    return AnimatedBuilder(
      animation: SyncService.instance,
      builder: (ctx, _) {
        final sync = SyncService.instance;
        final failed = sync.phase == SyncPhase.failed;
        final pending = sync.pendingCount;
        if (!failed && pending == 0) return const SizedBox.shrink();

        final syncing = sync.phase == SyncPhase.syncing;
        final authLost = failed && sync.lastFailureWasAuthMissing;
        final String text;
        if (failed) {
          text = sync.message.isEmpty ? '同步失败' : sync.message;
        } else if (syncing) {
          text = '正在上传 $pending 条…';
        } else {
          text = '$pending 条待上传，联网后会自动补上';
        }

        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: InkWell(
            // 会话失效时用户点的是「重新登录」，要绕过静默续期的退避窗口
            onTap: failed
                ? () => state.syncNow(forceRelogin: authLost)
                : null,
            borderRadius: BorderRadius.circular(AppRadius.sm),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: failed
                    ? AppColors.danger.withValues(alpha: 0.06)
                    : AppColors.border.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: Row(
                children: [
                  Icon(
                    failed
                        ? (authLost
                            ? Icons.lock_outline_rounded
                            : Icons.cloud_off_rounded)
                        : Icons.cloud_upload_outlined,
                    size: 16,
                    color: failed ? AppColors.danger : AppColors.textSecondary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      text,
                      style: TextStyle(
                        fontSize: 12,
                        color: failed ? AppColors.danger : AppColors.textSecondary,
                      ),
                    ),
                  ),
                  if (failed)
                    Text(
                      authLost ? '点击重新登录' : '点击重试',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.danger,
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _addChild() async {
    final state = AppStateScope.read(context);
    final nameCtrl = TextEditingController();
    var colorIndex = state.children.length % 6;

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('添加孩子'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: nameCtrl,
                autofocus: true,
                maxLength: 10,
                decoration: const InputDecoration(
                  labelText: '孩子的名字',
                  hintText: '例如：小宇',
                  counterText: '',
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '头像颜色',
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 10,
                children: [
                  for (var i = 0; i < AppColors.childPalette.length; i++)
                    GestureDetector(
                      onTap: () => setLocal(() => colorIndex = i),
                      child: Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: AppColors.childPalette[i],
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: colorIndex == i
                                ? AppColors.textPrimary
                                : Colors.transparent,
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                '孩子在自己手机上输入这个名字就能进入。',
                style: TextStyle(
                  fontSize: 11,
                  height: 1.5,
                  color: AppColors.textTertiary,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(80, 40)),
              onPressed: () async {
                final name = nameCtrl.text.trim();
                if (name.isEmpty) return;
                final exists = await _repo.childNameExists(name);
                if (exists) {
                  if (ctx.mounted) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      const SnackBar(content: Text('这个名字已经有了，换一个')),
                    );
                  }
                  return;
                }
                await state.addChild(name: name, colorIndex: colorIndex);
                if (ctx.mounted) Navigator.pop(ctx, true);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (result == true) setState(() {});
  }

  Future<void> _editChild(Child child) async {
    final state = AppStateScope.read(context);
    final nameCtrl = TextEditingController(text: child.name);
    var colorIndex = child.colorIndex;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('编辑孩子'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: nameCtrl,
                maxLength: 10,
                decoration: const InputDecoration(
                  labelText: '名字',
                  counterText: '',
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                children: [
                  for (var i = 0; i < AppColors.childPalette.length; i++)
                    GestureDetector(
                      onTap: () => setLocal(() => colorIndex = i),
                      child: Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: AppColors.childPalette[i],
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: colorIndex == i
                                ? AppColors.textPrimary
                                : Colors.transparent,
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: ctx,
                  builder: (c2) => AlertDialog(
                    title: const Text('删除这个孩子？'),
                    content: const Text('他名下的作业记录会一起删掉。'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(c2, false),
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.danger,
                          minimumSize: const Size(80, 40),
                        ),
                        onPressed: () => Navigator.pop(c2, true),
                        child: const Text('删除'),
                      ),
                    ],
                  ),
                );
                if (ok == true) {
                  await state.removeChild(child.id);
                  if (ctx.mounted) Navigator.pop(ctx);
                }
              },
              child: Text('删除',
                  style: TextStyle(color: AppColors.danger)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(80, 40)),
              onPressed: () async {
                final name = nameCtrl.text.trim();
                if (name.isEmpty) return;
                final exists =
                    await _repo.childNameExists(name, exceptId: child.id);
                if (exists) {
                  if (ctx.mounted) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      const SnackBar(content: Text('这个名字已经有了')),
                    );
                  }
                  return;
                }
                await state.updateChild(
                  child.copyWith(name: name, colorIndex: colorIndex),
                );
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    setState(() {});
  }

  Future<void> _copyCode(String code) async {
    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('家庭码已复制')));
  }

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final family = state.family;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        _sectionCard(
          title: '家庭',
          children: [
            _row('家庭名称', family?.name ?? '未创建'),
            const Divider(height: 24),
            Row(
              children: [
                SizedBox(
                  width: 80,
                  child: Text('家庭码',
                      style: TextStyle(
                          fontSize: 13, color: AppColors.textSecondary)),
                ),
                Expanded(
                  child: Text(
                    family?.code ?? '—',
                    style: TextStyle(
                      fontSize: 18,
                      letterSpacing: 4,
                      fontWeight: FontWeight.w600,
                      color: AppColors.seed,
                    ),
                  ),
                ),
                IconButton(
                  onPressed:
                      family == null ? null : () => _copyCode(family.code),
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  tooltip: '复制',
                ),
              ],
            ),
            Text(
              '家里两个孩子重名时，孩子端会要求补这串码。',
              style: TextStyle(fontSize: 11, color: AppColors.textTertiary),
            ),
          ],
        ),
        const SizedBox(height: 14),
        _sectionCard(
          title: '孩子',
          trailing: TextButton.icon(
            onPressed: _addChild,
            icon: const Icon(Icons.add, size: 16),
            label: const Text('添加'),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              textStyle: const TextStyle(fontSize: 13),
            ),
          ),
          children: [
            if (state.children.isEmpty)
              Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  '还没有添加孩子，先加一个才能布置作业',
                  style:
                      TextStyle(fontSize: 12, color: AppColors.textTertiary),
                ),
              )
            else
              for (final c in state.children)
                InkWell(
                  onTap: () => _editChild(c),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      children: [
                        ChildAvatar(child: c, size: 34),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(c.name,
                              style: const TextStyle(fontSize: 14)),
                        ),
                        Icon(Icons.chevron_right,
                            size: 18, color: AppColors.textTertiary),
                      ],
                    ),
                  ),
                ),
          ],
        ),
        const SizedBox(height: 14),
        _sectionCard(
          title: '外观',
          children: [
            _themeModeSelector(state),
            const SizedBox(height: 8),
            Text(
              state.themeMode == AppThemeMode.system
                  ? '跟随系统的深色模式自动切换'
                  : '固定使用${state.themeMode.label}，不随系统变化',
              style: TextStyle(fontSize: 11, color: AppColors.textTertiary),
            ),
          ],
        ),
        const SizedBox(height: 14),
        // 同步状态只在「有东西没传上去」或「传失败了」时出现一条，
        // 正常时完全不占位。同步本身是自动的，不需要用户点按钮。
        _syncNotice(state),
        _sectionCard(
          title: '身份',
          children: [
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => state.switchToChildView(),
                icon: const Icon(Icons.swap_horiz, size: 18),
                label: const Text('切换为孩子的界面'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 44),
                  foregroundColor: AppColors.textPrimary,
                  side: BorderSide(color: AppColors.border),
                ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('重新开始？'),
                      content: const Text('会清空本机的家庭和作业记录，不能撤销。'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('取消'),
                        ),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: AppColors.danger,
                            minimumSize: const Size(80, 40),
                          ),
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('清空'),
                        ),
                      ],
                    ),
                  );
                  if (ok == true) await state.resetAll();
                },
                child: Text('清空本机数据',
                    style: TextStyle(color: AppColors.danger, fontSize: 13)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _updateSection(),
      ],
    );
  }

  /// 外观三选一：跟随系统 / 浅色 / 深色。
  ///
  /// 用分段控件而不是开关：开关只能表达两种状态，而「跟随系统」是第三种，
  /// 且是默认值——用开关会逼用户在两个固定值里选，等于砍掉默认行为。
  Widget _themeModeSelector(AppState state) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppColors.surface3,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        children: [
          for (final mode in AppThemeMode.values)
            Expanded(
              child: GestureDetector(
                onTap: () => state.setThemeMode(mode),
                behavior: HitTestBehavior.opaque,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: state.themeMode == mode
                        ? AppColors.card
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(AppRadius.sm - 1),
                    boxShadow:
                        state.themeMode == mode ? AppShadow.s1 : null,
                  ),
                  child: Text(
                    mode.label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: state.themeMode == mode
                          ? AppColors.textPrimary
                          : AppColors.textSecondary,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _row(String label, String value) {    return Row(
      children: [
        SizedBox(
          width: 80,
          child: Text(label,
              style: TextStyle(
                  fontSize: 13, color: AppColors.textSecondary)),
        ),
        Expanded(
          child: Text(value,
              style: const TextStyle(fontSize: 13)),
        ),
      ],
    );
  }

  Widget _sectionCard({
    required String title,
    required List<Widget> children,
    Widget? trailing,
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
              const Spacer(),
              if (trailing != null) trailing,
            ],
          ),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }
}
