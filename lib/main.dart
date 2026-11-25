import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'app.dart';
import 'core/boot_trace.dart';
import 'data/cloud/update_service.dart';
import 'data/local_db.dart';
import 'data/repository.dart';
import 'state/app_state.dart';
import 'widgets/boot_failure.dart';

Future<void> main() async {
  bootStart();
  WidgetsFlutterBinding.ensureInitialized();
  bootMark('binding ready');

  _tuneImageCache();

  // 让内容铺到状态栏下面。
  //
  // 不开这个的话，系统状态栏是一块不透明的独立窗口，盖在 Flutter 之上：
  // 页面里画什么颜色它都看不见，底色完全由窗口主题决定。这台机器开了深色模式，
  // 状态栏就变成一条黑边，和界面完全脱节。
  //
  // 开启之后状态栏透明，页面自己画底色（见 AppColors.pageBg）。
  // 图标亮度不在这里写死：它取决于用户选的外观，由 AppState.init() 里的
  // _syncPalette() 统一下发，避免启动时先亮后暗闪一下。
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  // 日历与日期选择器需要中文本地化数据
  await initializeDateFormatting('zh_CN');

  await _bootstrap();
}

/// 收紧图片内存缓存。
///
/// Flutter 默认是 100MB / 1000 张，两个都很松：
///
///   - 按 100MB 算，一张 2275×1280 的图解码成位图约 11.6MB（不是文件大小，
///     是 width × height × 4 字节），能同时驻留 9 张大图。孩子来回翻页时
///     这个数在 2-3GB 内存的平板上偏大，纯属白占。
///   - 按 1000 张算更离谱：缩略图虽然只有几十 KB，但数量攒够 1000 张才逐出，
///     而实际一屏最多看十几张。
///
/// 压到 50MB / 60 张：全尺寸图能留 4 张左右，翻页时相邻图仍在，不会反复重解码；
/// 退出看图后多余的会被 LRU 逐出。
///
/// 注意：这是**内存缓存**，不是磁盘缓存。磁盘那份在 CloudImageCache 里，
/// 不受这里影响 —— 逐出后再次打开会重新从磁盘读，不产生网络请求。
void _tuneImageCache() {
  PaintingBinding.instance.imageCache
    ..maximumSizeBytes = 50 << 20 // 50MB
    ..maximumSize = 60;
}

/// 启动流程。
///
/// 单独抽出来是为了能被失败页的「重试」按钮再调一次。
///
/// 这里必须兜住异常：`state.init()` 里第一步就是开本地库，迁移一出错
/// （典型是 ALTER 撞上已存在的列），异常会一路冒到 zone 外，
/// 下面的 `runApp` 根本不执行，屏幕上是纯白一片，什么线索都没有。
/// 兜住之后至少能看见是哪条 SQL 挂了。
Future<void> _bootstrap() async {
  final state = AppState(Repository.instance);
  try {
    // 从 CloudBase 迁到自托管后端后，本地存量数据全部作废（旧家庭 id、旧 token、
    // 旧作业都指向另一套后端）。这一步必须早于 state.init()，
    // 否则会先按旧数据把界面拼出来再被打断。
    await LocalDb.instance.migrateToNewBackend();
    bootMark('db migrated');

    await state.init();
    bootMark('state.init done');

    // 版本号先读出来：设置页和孩子端「我的」都要显示，
    // 晚读会让这两处先闪一下占位符。
    // 放在 init 之后：包信息读不到不算致命，别让它拖垮启动。
    await UpdateService.instance.ensureLoaded();
    bootMark('update service loaded');

    runApp(HomeworkApp(state: state));
    bootMark('runApp called');
  } catch (e) {
    runApp(BootFailureApp(error: e, onRetry: _bootstrap));
  }
}
