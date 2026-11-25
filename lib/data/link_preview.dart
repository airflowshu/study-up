import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// 链接卡片的预览信息。
///
/// 全部字段都可能为空——抓到什么算什么，抓不到就由 UI 降级成
/// 「域名 + 完整链接」，绝不让发布流程卡在一次网络请求上。
class LinkPreview {
  const LinkPreview({
    this.title = '',
    this.desc = '',
    this.site = '',
    this.image = '',
  });

  final String title;
  final String desc;
  final String site;
  final String image;

  bool get isEmpty =>
      title.isEmpty && desc.isEmpty && site.isEmpty && image.isEmpty;
}

/// 抓取一次网页的 Open Graph 元信息。
///
/// 三条硬约束，缺一条就会在真实使用里出事：
/// 1. **5 秒超时**——家长在编辑页等着，不能因为对方站点慢把发布卡住；
/// 2. **只读前 256KB**——正文可能几 MB，元信息一定在 `<head>` 里；
/// 3. **任何异常都返回 null**——链接可能是内网地址、可能 403、可能不是 HTML，
///    这些都不是错误，只是没有预览而已。
Future<LinkPreview?> fetchLinkPreview(String url) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;

  final client = http.Client();
  try {
    final req = http.Request('GET', uri)
      // 不少站点对非浏览器 UA 直接 403，用常见桌面 UA 兼容性最好
      ..headers['User-Agent'] =
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/122.0 Safari/537.36'
      ..headers['Accept'] =
          'text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.8'
      ..headers['Accept-Language'] = 'zh-CN,zh;q=0.9';

    final res = await client
        .send(req)
        .timeout(const Duration(seconds: 5));
    if (res.statusCode >= 400) return null;

    final contentType = (res.headers['content-type'] ?? '').toLowerCase();
    // 图片、PDF、压缩包这些没有可抓的 head，直接放弃
    if (contentType.isNotEmpty &&
        !contentType.contains('html') &&
        !contentType.contains('xml') &&
        !contentType.contains('text')) {
      return null;
    }

    const limit = 256 * 1024;
    final buf = BytesBuilder(copy: false);
    await for (final chunk in res.stream.timeout(const Duration(seconds: 5))) {
      buf.add(chunk);
      if (buf.length >= limit) break;
    }
    final html = _decode(buf.takeBytes());
    return _parse(html, uri);
  } catch (_) {
    return null;
  } finally {
    client.close();
  }
}

/// 统一按 UTF-8 宽松解。
///
/// Dart 标准库没有内置 GBK，少数老站点会把标题解成乱码。
/// 权衡后不引入完整编码库：乱码只影响标题美观，链接本身照样能打开，
/// 为这点收益背上几十 KB 的字符表不划算。
String _decode(Uint8List bytes) => utf8.decode(bytes, allowMalformed: true);

LinkPreview _parse(String html, Uri pageUri) {
  final metas = <String, String>{};

  // 逐个 <meta ...> 标签解析：属性顺序各家不同，不能靠位置匹配
  for (final m in RegExp(r'<meta\b[^>]*>', caseSensitive: false)
      .allMatches(html)) {
    final tag = m.group(0) ?? '';
    final key = _attr(tag, 'property') ?? _attr(tag, 'name');
    final content = _attr(tag, 'content');
    if (key == null || content == null || content.isEmpty) continue;
    final k = key.toLowerCase();
    // 先出现的优先：og 一般在前，后面同名的 description 不覆盖
    metas.putIfAbsent(k, () => content);
  }

  String title = metas['og:title'] ?? metas['twitter:title'] ?? '';
  if (title.isEmpty) {
    final t = RegExp(r'<title[^>]*>([\s\S]*?)</title>', caseSensitive: false)
        .firstMatch(html);
    title = t?.group(1) ?? '';
  }

  final desc = metas['og:description'] ??
      metas['twitter:description'] ??
      metas['description'] ??
      '';

  var image = metas['og:image'] ??
      metas['og:image:url'] ??
      metas['twitter:image'] ??
      '';
  // 相对路径要补全，否则孩子端 Image.network 直接 400
  if (image.isNotEmpty && !image.startsWith('http')) {
    image = pageUri.resolve(image).toString();
  }

  final site = metas['og:site_name'] ?? pageUri.host;

  return LinkPreview(
    title: _clean(title),
    desc: _clean(desc),
    site: _clean(site),
    image: image.trim(),
  );
}

/// 取标签里的某个属性值，单双引号都认。
String? _attr(String tag, String name) {
  final m = RegExp(
    '''$name\\s*=\\s*(?:"([^"]*)"|'([^']*)')''',
    caseSensitive: false,
  ).firstMatch(tag);
  if (m == null) return null;
  return _entities(m.group(1) ?? m.group(2) ?? '');
}

/// 折叠空白 + 常见实体还原。标题里带换行会让卡片高度乱跳。
String _clean(String s) =>
    _entities(s).replaceAll(RegExp(r'\s+'), ' ').trim();

String _entities(String s) {
  if (!s.contains('&')) return s;
  return s
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&nbsp;', ' ');
}

/// 从一段文本里抠出第一个 http(s) 链接。
/// 家长往往连着一句话一起粘：「今天的作业 https://xxx 做完拍照」。
String? extractUrl(String text) {
  final m = RegExp(r'https?://[^\s，。；、）)\]】"<>]+').firstMatch(text);
  if (m == null) return null;
  var url = m.group(0)!;
  // 句末标点常被一起带进来
  url = url.replaceFirst(RegExp(r'[.,;:!?]+$'), '');
  return url;
}
