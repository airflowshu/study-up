import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../data/cloud/sync_service.dart';
import '../state/app_state.dart';

/// 全局同步提示条，挂在所有页面之上（家长端、孩子端共用）。
///
/// 只在三种情况下出现：
/// - **设备离线**：改动先落本地，联网后自动补，用户不需要做任何事
/// - **登录已失效**：云端会话没了，右侧「重新登录」会让 App 用本地家庭码续期
/// - **同步失败**：云端真的出问题了，右侧给一个「重试」入口
///
/// 一切正常时高度只等于状态栏，配合上层 `MediaQuery.removePadding(removeTop: true)`，
/// 保证「有提示」和「没提示」两种状态下页面布局都不跳动。
class SyncNoticeBar extends StatelessWidget {
  const SyncNoticeBar({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    // 除了 AppState（网络状态），还要监听同步器：孩子端某些路径是直接调
    // SyncService.syncAll 的，不会经过 AppState.notifyListeners。
    return AnimatedBuilder(
      animation: SyncService.instance,
      builder: (ctx, _) {
        final notice = state.syncNotice;
        final top = MediaQuery.of(ctx).padding.top;
        if (notice == null) {
          // 没有提示时只让出状态栏高度，底色由外层 Column 铺（见 app.dart）
          return SizedBox(height: top);
        }

        final offline = notice.kind == SyncNoticeKind.offline;
        final authLost = notice.kind == SyncNoticeKind.authLost;
        final bg = offline ? AppColors.warningSoft : AppColors.dangerSoft;
        final fg = offline ? AppColors.warningInk : AppColors.dangerInk;

        // 让出状态栏高度，提示条从状态栏下沿开始——
        // 跟着系统状态栏染色会让人以为整个 App 出了故障，实际只是没网。
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(height: top),
            Material(
              color: bg,
              child: InkWell(
                // 离线时不给重试入口：网都没有，点什么都是白点
                onTap: offline
                    ? null
                    // 登录失效走 force：用户明确点了，就别再被静默续期的退避挡住
                    : () => state.syncNow(forceRelogin: authLost),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      Icon(
                        offline
                            ? Icons.wifi_off_rounded
                            : authLost
                                ? Icons.lock_outline_rounded
                                : Icons.cloud_off_rounded,
                        size: 15,
                        color: fg,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          notice.text,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.3,
                            color: fg,
                          ),
                        ),
                      ),
                      if (!offline) ...[
                        const SizedBox(width: 8),
                        Text(
                          authLost ? '重新登录' : '重试',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: fg,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
