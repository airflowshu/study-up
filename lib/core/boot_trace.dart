import 'package:flutter/foundation.dart';

/// 启动链路打点。
///
/// 只在 `--dart-define=SYNC_TRACE=true` 时输出，正式包零开销、零日志。
///
/// 存在的理由：用户感知的「打开 App 要七八秒」是多段拼起来的
/// （读库迁移 → 初始化 → 首帧 → 后台同步 → 图片下载），
/// 只看同步那一层会误判。这里给整条链路一个统一的时间原点。
final _sw = Stopwatch();
bool _started = false;

const bootTraceEnabled = bool.fromEnvironment('SYNC_TRACE');

void bootStart() {
  if (!bootTraceEnabled || _started) return;
  _started = true;
  _sw.start();
}

void bootMark(String label) {
  if (!bootTraceEnabled || !_started) return;
  debugPrint('[BOOT] ${_sw.elapsedMilliseconds.toString().padLeft(5)}ms $label');
}
