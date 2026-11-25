import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'cloud_api.dart';

/// 云端发布的一条版本记录。
class AppRelease {
  const AppRelease({
    required this.versionName,
    required this.versionCode,
    required this.downloadUrl,
    required this.changelog,
    required this.forceUpdate,
  });

  final String versionName;
  final int versionCode;
  final String downloadUrl;
  final String changelog;

  /// true 时弹窗不可关闭，必须去更新。
  final bool forceUpdate;

  /// 下载地址是不是「文件列表页」而不是 APK 本体。
  ///
  /// NAS 分享出来的链接（飞牛 /s/xxx、各类网盘）返回的是 HTML 页面，
  /// 用户得在页面里再点一次文件名才真正开始下载。界面需要提前说清楚，
  /// 否则点了「立即更新」跳到一个文件列表，用户会以为下错了。
  bool get isDownloadPage {
    final path = downloadUrl.split('?').first.split('#').first.toLowerCase();
    return !path.endsWith('.apk');
  }

  factory AppRelease.fromRow(Map<String, dynamic> r) {
    final name = (r['version_name'] ?? '') as String;
    final code = (r['version_code'] as num?)?.toInt() ?? 0;
    // download_url 支持 {version} / {version_code} 占位符。
    //
    // 发布目录固定时（比如 NAS 上按 homework-1.0.1.apk 命名），表里存模板
    // `https://nas/app/homework-{version}.apk` 即可：每个版本只改 version_name，
    // 不用每次手工拼地址。填完整 URL 也照样能用，不做强制。
    final raw = (r['download_url'] ?? '') as String;
    final url = raw
        .replaceAll('{version}', name)
        .replaceAll('{version_code}', '$code');
    return AppRelease(
      versionName: name,
      versionCode: code,
      downloadUrl: url,
      changelog: (r['changelog'] ?? '') as String,
      forceUpdate: (r['force_update'] ?? false) == true,
    );
  }
}

/// 检查结果。区分「没有新版」和「查不到」——前者可以静默，
/// 后者要能告诉用户「检查失败」而不是骗他说已是最新。
enum UpdateCheckResult { upToDate, available, failed }

/// 版本检查与安装引导。
///
/// 分工：**云端只提供清单，客户端只管打开链接**。
/// 不在 App 内直接下载 APK 并触发安装——那要额外申请
/// REQUEST_INSTALL_PACKAGES 权限、写 FileProvider、处理 Android 8+ 的
/// 未知来源安装授权，任何一环出问题用户只会看到「安装失败」。
/// 交给系统浏览器/下载器，行为可预期，也不用为每个机型单独适配。
class UpdateService extends ChangeNotifier {
  UpdateService._();
  static final UpdateService instance = UpdateService._();

  String _currentVersion = '';
  int _currentVersionCode = 0;
  bool _loaded = false;

  /// 云端查到的新版本，null 表示没有可更新的版本。
  AppRelease? available;

  /// 上次自动检查的时间。启动检查用它做节流。
  DateTime? lastChecked;

  /// 自动检查的节流窗口。
  ///
  /// 只在同一次运行内有效（lastChecked 不落盘）：冷启动会查一次，
  /// 之后切前后台、网络恢复都不会重复查。一次 GET 几百字节，
  /// 为此单独做持久化得不偿失。
  static const _autoCheckInterval = Duration(hours: 6);

  String get currentVersion => _loaded ? _currentVersion : '—';
  int get currentVersionCode => _currentVersionCode;

  /// 读取本机安装包信息。必须在检查之前调用一次。
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    try {
      final info = await PackageInfo.fromPlatform();
      _currentVersion = info.version;
      _currentVersionCode = int.tryParse(info.buildNumber) ?? 0;
    } catch (_) {
      // 个别机型/模拟器取不到包信息，退化成「未知版本」，
      // 不能因此让整个更新功能失效。
      _currentVersion = '';
      _currentVersionCode = 0;
    }
    _loaded = true;

    notifyListeners();
  }

  /// 拉云端最新版本并和本机比对。
  ///
  /// 排序规则：同一平台取 version_code 最大的一条上架记录。
  /// 用 build number 而不是 version_name 比较——字符串比较会在
  /// "1.10.0" 和 "1.9.0" 上判错。
  Future<UpdateCheckResult> check() async {
    await ensureLoaded();
    try {
      // 用匿名查询：版本检查发生在登录之前，用户还没进家庭也得能收到更新提示。
      final rows = await CloudApi.instance.selectPublic(
        'app_releases',
        query: {
          'platform': 'eq.android',
          'is_active': 'eq.true',
          'order': 'version_code.desc',
        },
        limit: 1,
      );
      lastChecked = DateTime.now();
      if (rows.isEmpty) {
        // 一条记录都没有 = 还没发过版，对用户来说等同于已是最新
        available = null;
        notifyListeners();
        return UpdateCheckResult.upToDate;
      }
      final release = AppRelease.fromRow(rows.first);
      if (release.versionCode <= _currentVersionCode) {
        available = null;
        notifyListeners();
        return UpdateCheckResult.upToDate;
      }
      available = release;
      notifyListeners();
      return UpdateCheckResult.available;
    } catch (_) {
      // 网络问题不改变「已发现的更新」，也不弹错误：启动时的静默检查
      // 不该因为没网就弹个窗打扰用户。
      return UpdateCheckResult.failed;
    }
  }

  /// 启动时的静默检查。返回需要提示的新版本，没有则 null。
  Future<AppRelease?> autoCheck() async {
    await ensureLoaded();
    final last = lastChecked;
    if (last != null && DateTime.now().difference(last) < _autoCheckInterval) {
      // 节流窗口内直接复用上次结果，避免频繁重启 App 反复请求
      return available;
    }
    final result = await check();
    return result == UpdateCheckResult.available ? available : null;
  }

  /// 打开下载地址。返回是否成功唤起。
  Future<bool> openDownload() async {
    final url = available?.downloadUrl;
    if (url == null || url.isEmpty) return false;
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }
}
