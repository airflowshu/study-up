import 'package:flutter/material.dart';

/// 启动失败兜底页。
///
/// 为什么需要它：`main()` 里 `await state.init()` 一旦抛异常，后面的 `runApp`
/// 就永远不会执行，屏幕上只剩一片白——没有报错、没有入口、没有日志入口。
/// 用户只能卸载重装，排查也只能靠 adb logcat 连电脑。这类「白屏」本身不带
/// 任何信息，是所有故障形态里最难查的一种。
///
/// 这里把异常原样摊开，并给一个重试入口：本地库读不出来，多半是升级迁移
/// 出错，改好代码后重试就能进去，本地数据还在。
///
/// 刻意不依赖 [AppColors]：调色板是在 `AppState.init()` 里按用户偏好切过去的，
/// 而这里正是 init 失败的现场，全局状态可能是半初始化状态，用默认主题最稳。
class BootFailureApp extends StatelessWidget {
  const BootFailureApp({super.key, required this.error, required this.onRetry});

  final Object error;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 32, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.error_outline, color: Color(0xFFD33A3A), size: 22),
                    SizedBox(width: 8),
                    Text(
                      '启动失败',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1A1A1A),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  '本地数据没能读出来，App 卡在启动前。',
                  style: TextStyle(fontSize: 13, color: Color(0xFF666666)),
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF5F5F7),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFE3E3E8)),
                    ),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        '$error',
                        style: const TextStyle(
                          fontSize: 11,
                          height: 1.5,
                          fontFamily: 'monospace',
                          color: Color(0xFF3A3A3A),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  '云端数据不受影响。请点重试；若反复失败，把上面这段报错发给开发者。',
                  style: TextStyle(fontSize: 12, color: Color(0xFF888888)),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(46),
                    ),
                    onPressed: () => onRetry(),
                    child: const Text('重试'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
