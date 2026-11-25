import 'dart:io';

import 'package:flutter/services.dart';

/// 剪贴板探查结果。
///
/// Flutter 自带的 `Clipboard.getData` 只有纯文本，安卓上复制多张图片时
/// 剪贴板里装的是若干 `content://` URI，Dart 侧看不到，只能走原生通道。
class ClipPayload {
  const ClipPayload({
    required this.hasImages,
    required this.imageCount,
    required this.fingerprint,
    required this.hasText,
    required this.text,
    required this.uris,
    required this.ageMs,
    required this.html,
  });

  final bool hasImages;
  final int imageCount;

  /// 内容指纹（时间戳 + URI 列表 + 文本哈希），用于判断「这份剪贴板是否已经导入过」。
  final String fingerprint;
  final bool hasText;
  final String text;

  /// 图片 URI，可能是 content:// 也可能是 file://
  final List<String> uris;

  /// 剪贴板被写入距今多久。刚复制完的才算「新鲜」，避免把手里的旧图误插进来。
  final int ageMs;

  /// 剪贴板里的 HTML 原文（有些来源会带）。
  /// 网页、备忘录、WPS 这类来源会把 `<img>` 在正文中的位置一起复制过来，
  /// 有这份 HTML 才能把图片还原到原来的段落之间；只有 URI 列表就做不到。
  /// 多个 item 的 HTML 用 `<!--SPLIT-->` 分隔。
  final String html;

  static const none = ClipPayload(
    hasImages: false,
    imageCount: 0,
    fingerprint: '',
    hasText: false,
    text: '',
    uris: [],
    ageMs: 1 << 62,
    html: '',
  );

  bool get isFresh => ageMs < 120000; // 2 分钟内复制过

  factory ClipPayload.fromMap(Map<Object?, Object?> m) {
    final rawUris = m['uris'];
    return ClipPayload(
      hasImages: m['hasImages'] == true,
      imageCount: (m['imageCount'] as num?)?.toInt() ?? 0,
      fingerprint: (m['fingerprint'] ?? '') as String,
      hasText: m['hasText'] == true,
      text: (m['text'] ?? '') as String,
      uris: rawUris is List
          ? rawUris.whereType<String>().toList(growable: false)
          : const [],
      ageMs: (m['ageMs'] as num?)?.toInt() ?? (1 << 62),
      html: (m['html'] ?? '') as String,
    );
  }
}

/// 剪贴板图片读取 + 落地。
///
/// 只支持 Android（本项目仅发布安卓）；其它平台一律返回空，调用方按「没有图片」处理。
class ClipboardPaste {
  ClipboardPaste._();

  static final ClipboardPaste instance = ClipboardPaste._();

  static const _channel = MethodChannel('com.shuge.homework_app/clipboard');

  bool _unsupported = false;

  ClipPayload? _cached;
  DateTime? _cachedAt;

  /// 轻量探查，不落盘不解码，可以高频调用（内部有 1 秒缓存）。
  Future<ClipPayload?> peek({bool force = false}) async {
    if (_unsupported) return null;
    if (!Platform.isAndroid) return null;

    final now = DateTime.now();
    final c = _cached;
    if (!force && c != null && _cachedAt != null) {
      if (now.difference(_cachedAt!) < const Duration(seconds: 1)) return c;
    }
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>('peek');
      final p = raw == null ? null : ClipPayload.fromMap(raw);
      _cached = p;
      _cachedAt = now;
      return p;
    } on MissingPluginException {
      // 旧包 / 非安卓：通道不存在，后续不再重试
      _unsupported = true;
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// 把剪贴板里的图片读出来，压缩后落到缓存目录。返回本地文件路径（JPEG）。
  ///
  /// [uris] 为空时由原生层自己再取一遍剪贴板；传入 peek 拿到的 URIs 可以保证
  /// 「提示里显示几张就导入几张」，不会因为剪贴板在两次调用之间变化而错位。
  Future<List<String>> importImages({
    List<String>? uris,
    int maxSide = 1600,
    int quality = 85,
  }) async {
    if (_unsupported || !Platform.isAndroid) return const [];
    try {
      final res = await _channel.invokeMethod<List<Object?>>('import', {
        'uris': uris ?? const <String>[],
        'maxSide': maxSide,
        'quality': quality,
      });
      return res?.whereType<String>().toList(growable: false) ?? const [];
    } on MissingPluginException {
      _unsupported = true;
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  /// 读一个文件的轻量指纹（长度 + 头部 64KB 的 FNV-1a），用于导入去重。
  /// 图片本身只有几百 KB，读一遍的代价远小于重复上传。
  Future<String> signatureOf(String path) async {
    try {
      final f = File(path);
      if (!f.existsSync()) return '';
      final len = await f.length();
      final raf = await f.open();
      try {
        final head = await raf.read(len < 65536 ? len : 65536);
        final h = _fnv1a(head);
        return '$len:$h';
      } finally {
        await raf.close();
      }
    } catch (_) {
      return '';
    }
  }

  static int _fnv1a(Uint8List bytes) {
    var hash = 0xcbf29ce484222325;
    for (final b in bytes) {
      hash = (hash ^ b) * 0x100000001b3;
    }
    return hash;
  }
}
