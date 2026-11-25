import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../data/cloud/update_service.dart';

/// 启动时的静默版本检查。
///
/// 为什么不放在 `AppState.init()`：那里没有 BuildContext，弹不了窗。
/// 这里包在 Navigator 之内，既能拿到 context，也只在根部挂一次。
class UpdateGate extends StatefulWidget {
  const UpdateGate({super.key, required this.child});

  final Widget child;

  @override
  State<UpdateGate> createState() => _UpdateGateState();
}

class _UpdateGateState extends State<UpdateGate> {
  @override
  void initState() {
    super.initState();
    // 等首帧画完再查：启动瞬间网络正忙着同步，别抢带宽，
    // 也别让一个更新弹窗盖住用户刚打开就要看的内容。
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  Future<void> _check() async {
    await Future<void>.delayed(const Duration(seconds: 3));
    if (!mounted) return;
    final release = await UpdateService.instance.autoCheck();
    if (release == null || !mounted) return;
    await showUpdateDialog(context, release);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 更新提示弹窗。设置页手动检查后也复用这一个。
///
/// [AppRelease.forceUpdate] 为真时：点遮罩、返回键都关不掉，只留「立即更新」。
Future<void> showUpdateDialog(BuildContext context, AppRelease release) {
  return showDialog<void>(
    context: context,
    barrierDismissible: !release.forceUpdate,
    builder: (ctx) {
      final current = UpdateService.instance.currentVersion;
      final changelog = release.changelog.trim();
      return PopScope(
        canPop: !release.forceUpdate,
        child: AlertDialog(
          title: Text(
            release.forceUpdate
                ? '需要更新到 ${release.versionName}'
                : '发现新版本 ${release.versionName}',
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '当前版本 $current → 新版本 ${release.versionName}',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
                if (changelog.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.surface2,
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    child: Text(
                      changelog,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.6,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                ],
                // 下载地址是文件列表页时，先把「还要点一下文件名」说清楚。
                // 不说的话，用户点完跳到一个文件列表会觉得没反应。
                if (release.isDownloadPage) ...[
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.surface2,
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.download_rounded,
                          size: 16,
                          color: AppColors.textTertiary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '点下方按钮会打开下载页，选文件名含 ${release.versionName} 的那个包，'
                            '下完点一下即可安装。',
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.5,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                if (release.forceUpdate) ...[
                  const SizedBox(height: 12),
                  Text(
                    '这一版包含必须修复的问题，更新后才能继续使用。',
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.5,
                      color: AppColors.textTertiary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            if (!release.forceUpdate)
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('稍后'),
              ),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(96, 42)),
              onPressed: () async {
                final ok = await UpdateService.instance.openDownload();
                if (!ctx.mounted) return;
                if (ok) {
                  // 已经交给浏览器了，弹窗留着只会让用户从浏览器切回来时
                  // 又看见一遍。强制更新场景下次冷启动会重新弹。
                  Navigator.pop(ctx);
                  return;
                }
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(content: Text('打不开下载页，检查一下网络再试')),
                );
              },
              child: Text(release.isDownloadPage ? '去下载' : '立即更新'),
            ),
          ],
        ),
      );
    },
  );
}
