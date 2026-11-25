/// 后端配置。
///
/// 从 CloudBase 迁到家里的 NAS 之后，这里从「拼 CloudBase 的网关域名」
/// 变成「一个可以直接配置的地址」。
///
/// 地址是**编译期常量**，不是运行时可改的：
/// 换服务器意味着换数据源，本地 token、本地缓存、本地作业全都对不上，
/// 与其留一个能被填错的输入框，不如在构建时钉死。
/// 发版时用 `flutter build apk --dart-define=API_BASE=https://你的域名` 覆盖。
class CloudConfig {
  CloudConfig._();

  /// 服务根地址。默认值是占位符，正式包必须用 --dart-define 传真实域名。
  static const String baseUrl = String.fromEnvironment(
    'API_BASE',
    defaultValue: 'https://homework.example.com',
  );

  /// 图片存储桶。服务端只有这一个业务桶，路径里仍保留这段以对齐原有协议。
  static const String bucket = 'homework';

  /// 表数据接口根地址
  static String get restUrl => '$baseUrl/v1/rdb/rest';

  /// 图片直链。服务端公开读，不签名、不带 token，靠 key 里的 UUID 不可枚举防扫。
  static String imageUrl(String key) =>
      '$baseUrl/v1/storages/object/$bucket/$key';

  /// 图片磁盘缓存的命名空间。
  ///
  /// 缓存文件名只用 cloud key，不含 host —— 如果换过服务器而 key 又碰巧相同，
  /// 就会显示出上一台服务器上的图。给目录加一层服务器指纹，换服务端即换目录。
  static String get cacheScope {
    final host = Uri.tryParse(baseUrl)?.host ?? baseUrl;
    var hash = 0x811c9dc5; // FNV-1a，够用且跨进程稳定
    for (final unit in host.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  /// 地址是否还是占位符。设置页据此提示「本次安装没有配置服务器」。
  static bool get isPlaceholder => baseUrl.contains('example.com');
}
