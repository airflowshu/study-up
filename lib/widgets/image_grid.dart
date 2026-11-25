import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../core/breakpoints.dart';
import '../core/theme.dart';
import '../data/cloud/cloud_api.dart';
import '../data/cloud/cloud_config.dart';

/// 一张图的引用。家长端是本机文件绝对路径，
/// 孩子端是云存储 key，统一用 `cloud:` 前缀区分。
bool isCloudRef(String ref) => ref.startsWith('cloud:');

String cloudKeyOf(String ref) => ref.substring('cloud:'.length);

/// 云端图片的磁盘缓存。
///
/// 之前直接用 `Image.network`，只有内存缓存：App 一关就没了，
/// 第二天打开同一份作业，几张图全部重新下一遍。家长一天看十次历史，
/// 那份流量是白烧的。这里按 key 落盘，同一张图一辈子只下载一次。
///
/// 刻意不引 `cached_network_image`：它的缓存策略对我们这种
/// 「public 桶 + 永久不变 key」的场景是多余的，自己实现反而可控。
class CloudImageCache {
  CloudImageCache._();

  static Directory? _dir;

  /// 同一张图被多个 Widget 同时请求时只发一次网络请求。
  static final Map<String, Future<File?>> _inflight = {};

  /// 缓存上限，超了从最旧的开始删。
  static const int _maxBytes = 200 * 1024 * 1024;
  static const int _maxAgeDays = 60;

  static Future<Directory> _ensureDir() async {
    final cached = _dir;
    if (cached != null) return cached;
    final tmp = await getTemporaryDirectory();
    // 按服务器指纹分目录：换过服务器时，同一个 cloud key 不应该命中旧图。
    // 只按 key 命名的话，key 形态又恰好一致（都是 UUID），就会显示出上一台服务器的内容。
    final d = Directory('${tmp.path}/cloud_images/${CloudConfig.cacheScope}');
    if (!d.existsSync()) d.createSync(recursive: true);
    _dir = d;
    _prune(d);
    return d;
  }

  /// key 里只有字母数字和 `/`，换成下划线即可当文件名。
  static String _fileName(String key) =>
      key.replaceAll('/', '_').replaceAll(':', '_');

  static File _fileFor(Directory d, String key) =>
      File('${d.path}/${_fileName(key)}');

  /// 已经缓存的直接给，没有返回 null（不触发下载）。
  static File? peek(String key) {
    final d = _dir;
    if (d == null) return null;
    final f = _fileFor(d, key);
    if (f.existsSync() && f.lengthSync() > 0) return f;
    return null;
  }

  /// 拿缓存文件，没有就下载。下载失败返回 null，由调用方回退到直接走网络。
  static Future<File?> get(String key) async {
    final d = await _ensureDir();
    final existing = _fileFor(d, key);
    if (existing.existsSync() && existing.lengthSync() > 0) return existing;

    final running = _inflight[key];
    if (running != null) return running;

    final fut = _download(key, existing);
    _inflight[key] = fut;
    try {
      return await fut;
    } finally {
      _inflight.remove(key);
    }
  }

  static Future<File?> _download(String key, File target) async {
    try {
      // 走 CloudApi 而不是裸 http.get：复用它的超时、错误归一和流量记账。
      // 图片是流量最大的一块，绕过它会让设置页的数字明显偏小。
      final bytes = await CloudApi.instance.downloadImage(key);
      if (bytes.isEmpty) return null;
      // 先写临时文件再改名，避免下到一半被杀留下半张图
      final tmp = File('${target.path}.part');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(target.path);
      return target;
    } catch (_) {
      return null;
    }
  }

  /// 按「超 60 天」和「超 200MB」双重条件清理，只在启动后第一次用时跑一遍。
  static void _prune(Directory d) {
    try {
      final now = DateTime.now();
      final entries = d
          .listSync()
          .whereType<File>()
          .map((f) => (f, f.statSync()))
          .toList();
      var total = 0;
      for (final e in entries) {
        total += e.$2.size;
      }
      // 按修改时间从旧到新
      entries.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
      for (final e in entries) {
        final tooOld =
            now.difference(e.$2.modified).inDays > _maxAgeDays;
        if (!tooOld && total <= _maxBytes) break;
        total -= e.$2.size;
        try {
          e.$1.deleteSync();
        } catch (_) {
          // 单个文件删不掉不影响其它
        }
      }
    } catch (_) {
      // 清理失败无所谓，不影响看图
    }
  }
}

/// 云端图片：先看磁盘缓存，没有再下载。
class CachedCloudImage extends StatefulWidget {
  const CachedCloudImage({
    super.key,
    required this.cloudKey,
    this.fit = BoxFit.cover,
    this.thumbWidth,
    this.fallback,
  });

  final String cloudKey;
  final BoxFit fit;
  final int? thumbWidth;
  final Widget Function()? fallback;

  @override
  State<CachedCloudImage> createState() => _CachedCloudImageState();
}

class _CachedCloudImageState extends State<CachedCloudImage> {
  File? _file;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    // 命中缓存时同步取出，首帧就能画出来，不闪一下占位
    _file = CloudImageCache.peek(widget.cloudKey);
    if (_file == null) _load();
  }

  Future<void> _load() async {
    final f = await CloudImageCache.get(widget.cloudKey);
    if (!mounted) return;
    setState(() {
      _file = f;
      _failed = f == null;
    });
  }

  Widget _placeholder() => Container(
        color: AppColors.surface2,
        alignment: Alignment.center,
        child: const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 1.6),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final f = _file;
    if (f != null) {
      return Image.file(
        f,
        fit: widget.fit,
        cacheWidth: widget.thumbWidth,
        errorBuilder: (_, __, ___) =>
            widget.fallback?.call() ??
            Icon(Icons.broken_image_outlined,
                size: 18, color: AppColors.textTertiary),
      );
    }
    if (_failed) {
      return widget.fallback?.call() ??
          Container(
            color: AppColors.surface3,
            alignment: Alignment.center,
            child: Icon(Icons.broken_image_outlined,
                size: 18, color: AppColors.textTertiary),
          );
    }
    return _placeholder();
  }
}

/// 取一张图对应的 ImageProvider（云端 ref 先落到磁盘缓存）。
/// 看图页面要靠它拿到图片原始宽高，才能算「双击后填满宽度」的缩放比例。
Future<ImageProvider?> imageProviderOf(String ref) async {
  if (isCloudRef(ref)) {
    final f = await CloudImageCache.get(cloudKeyOf(ref));
    return f == null ? null : FileImage(f);
  }
  final f = File(ref);
  return f.existsSync() ? FileImage(f) : null;
}

/// 按引用渲染图片：本地走文件，云端走向磁盘缓存的网络图。
/// [thumbWidth] 给了就按宽度解码，图片多时省内存。
Widget buildImageRef(
  String ref, {
  BoxFit fit = BoxFit.cover,
  int? thumbWidth,
  Widget Function()? onError,
}) {
  Widget fallback() =>
      onError?.call() ??
      Container(
        color: AppColors.surface3,
        alignment: Alignment.center,
        child: Icon(Icons.broken_image_outlined,
            size: 18, color: AppColors.textTertiary),
      );

  if (isCloudRef(ref)) {
    return CachedCloudImage(
      cloudKey: cloudKeyOf(ref),
      fit: fit,
      thumbWidth: thumbWidth,
      fallback: fallback,
    );
  }

  final file = File(ref);
  if (!file.existsSync()) return fallback();
  return Image.file(
    file,
    fit: fit,
    cacheWidth: thumbWidth,
    errorBuilder: (_, __, ___) => fallback(),
  );
}

/// 自适应图片网格：列数按可用宽度算，图片不限张数也不会撑爆布局。
class ImageGrid extends StatelessWidget {
  const ImageGrid({
    super.key,
    required this.images,
    this.maxColumns = 8,
    this.spacing = 6,
    this.trailing,
    this.onRemove,
  });

  final List<String> images;
  final int maxColumns;
  final double spacing;

  /// 末尾追加的控件（如「+ 添加」），只在编辑态传。
  final Widget? trailing;

  /// 给了就在每张图右上角画「×」，只在编辑态传。
  final void Function(int index)? onRemove;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cols = imageColumnsFor(constraints.maxWidth).clamp(2, maxColumns);
        final total = images.length + (trailing != null ? 1 : 0);
        if (total == 0) return const SizedBox.shrink();
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (var i = 0; i < images.length; i++)
              _Thumb(
                path: images[i],
                size: (constraints.maxWidth - spacing * (cols - 1)) / cols,
                badge: (i + 1).toString(),
                onTap: () => _openPreview(context, i),
                onRemove:
                    onRemove == null ? null : () => onRemove!.call(i),
              ),
            if (trailing != null)
              SizedBox(
                width: (constraints.maxWidth - spacing * (cols - 1)) / cols,
                height: (constraints.maxWidth - spacing * (cols - 1)) / cols,
                child: trailing,
              ),
          ],
        );
      },
    );
  }

  void _openPreview(BuildContext context, int index) =>
      openImageViewer(context, images, index);
}

/// 全屏看图。网格缩略图和折叠卡片都走这里，保证点开体验一致。
void openImageViewer(BuildContext context, List<String> images, int index) {
  Navigator.of(context).push(
    PageRouteBuilder(
      opaque: false,
      barrierColor: Colors.black,
      pageBuilder: (_, __, ___) => _PhotoViewer(
        images: images,
        initialIndex: index,
      ),
    ),
  );
}

class _Thumb extends StatelessWidget {
  const _Thumb({
    required this.path,
    required this.size,
    this.onTap,
    this.onRemove,
    this.badge,
  });

  final String path;
  final double size;
  final VoidCallback? onTap;
  final VoidCallback? onRemove;

  /// 左上角序号，和正文里的 [图N] 对应
  final String? badge;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: onTap,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.sm),
                child: buildImageRef(
                  path,
                  thumbWidth: (size * 2).round(),
                ),
              ),
            ),
          ),
          if (badge != null)
            Positioned(
              left: 4,
              top: 4,
              child: IgnorePointer(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: const Color(0xB31A1D26),
                    borderRadius: BorderRadius.circular(AppRadius.xs),
                  ),
                  child: Text(
                    badge!,
                    style: const TextStyle(
                      fontSize: 10,
                      height: 1.2,
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          if (onRemove != null)
            Positioned(
              right: 2,
              top: 2,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onRemove,
                child: Container(
                  width: 20,
                  height: 20,
                  decoration: const BoxDecoration(
                    color: Color(0xCC1A1D26),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.close,
                      size: 13, color: Colors.white),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 全屏看图。
///
/// 交互按微信那套来：
/// - **单击图片直接退出**，不用去右上角找关闭按钮
/// - **双击在两种状态间切换**：整图（contain）↔ 宽度填满（横屏时图片上下都能看）
///   填满之后单指上下拖动看图片的不同高度段
/// - 双指仍可自由缩放
/// - 没放大时左右滑动切上一张 / 下一张
class _PhotoViewer extends StatefulWidget {
  const _PhotoViewer({required this.images, required this.initialIndex});

  final List<String> images;
  final int initialIndex;

  @override
  State<_PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<_PhotoViewer> {
  late final PageController _controller =
      PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 放大状态下横向滑动切图。越界就不动，不绕回第一张。
  void _swipeTo(int delta) {
    final next = _index + delta;
    if (next < 0 || next >= widget.images.length) return;
    if (!_controller.hasClients) return;
    _controller.animateToPage(
      next,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          PageView.builder(
            controller: _controller,
            itemCount: widget.images.length,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (_, i) => _ZoomableImage(
              key: ValueKey(widget.images[i]),
              ref: widget.images[i],
              onTap: () => Navigator.of(context).pop(),
              onSwipe: widget.images.length > 1 ? _swipeTo : null,
            ),
          ),
          if (widget.images.length > 1)
            Positioned(
              bottom: 28,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(AppRadius.full),
                  ),
                  child: Text(
                    '${_index + 1} / ${widget.images.length}',
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 全屏看图时的解码宽度上限（物理像素）。
///
/// 一张位图占的内存是 `宽 × 高 × 4 字节`，跟文件大小无关。作业图常见两种来源：
///
///   - 手机拍的照：4000×3000，解码后 **48MB**
///   - 截图/微信图：2275×1280，解码后 **11.6MB**
///
/// 3200 这个值的取法：
///   - 低于它 → 不动。2275 宽的截图原样解码，放大看文字不受影响，
///     这正是最常看的类型，不能为了省内存牺牲清晰度。
///   - 高于它 → 按 3200 解。4000 宽的手机照位图从 48MB 降到 31MB，
///     在 6 倍放大的极限情况下也只损失一点点细节，肉眼基本无感。
///
/// 另外它给 ImageCache 兜了底：没有这个上限时，一张 8000×6000 的图解码要
/// 192MB，会一次性把 50MB 的缓存撑爆并逐出全部其它图。
const int _kZoomDecodeWidth = 3200;

class _ZoomableImage extends StatefulWidget {
  const _ZoomableImage({
    super.key,
    required this.ref,
    required this.onTap,
    this.onSwipe,
  });

  final String ref;
  final VoidCallback onTap;

  /// 放大到横向已无余地时，横向滑动改为切图：`-1` 上一张，`1` 下一张。
  final void Function(int delta)? onSwipe;

  @override
  State<_ZoomableImage> createState() => _ZoomableImageState();
}

class _ZoomableImageState extends State<_ZoomableImage>
    with SingleTickerProviderStateMixin {
  ImageProvider? _provider;
  ImageStream? _stream;
  ImageStreamListener? _listener;

  /// 图片原始像素尺寸，算缩放比例要用
  Size? _pixelSize;
  bool _failed = false;

  final _tc = TransformationController();
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  Animation<Matrix4>? _tween;

  /// 是否处于放大状态。放大后才允许拖动，否则左右滑动手势要留给翻页。
  bool _zoomed = false;

  /// 本次手势里累计的横向位移，以及是否已经翻过页（一次手势只翻一张）。
  double _swipeX = 0;
  bool _swipeConsumed = false;

  @override
  void initState() {
    super.initState();
    _anim.addListener(() {
      final t = _tween;
      if (t != null) _tc.value = t.value;
    });
    _resolve();
  }

  @override
  void dispose() {
    final l = _listener;
    if (l != null) _stream?.removeListener(l);
    _anim.dispose();
    _tc.dispose();
    super.dispose();
  }

  Future<void> _resolve() async {
    final raw = await imageProviderOf(widget.ref);
    if (!mounted) return;
    if (raw == null) {
      setState(() => _failed = true);
      return;
    }

    // 原图比 _kZoomDecodeWidth 宽才缩，否则原样（resizeIfNeeded 内部会判断）。
    // 必须把缩过之后的 provider 存进 _provider：build 里用的是它，
    // 存原图等于白缩，两份位图会各占一份内存。
    final p = ResizeImage.resizeIfNeeded(_kZoomDecodeWidth, null, raw);

    final stream = p.resolve(const ImageConfiguration());
    late ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        if (!mounted) return;
        setState(() {
          _provider = p;
          // 这里拿到的是**解码后**的尺寸。宽高比跟原图一致，
          // 下面的 fit / content 计算只依赖比例，所以不影响布局。
          _pixelSize = Size(
            info.image.width.toDouble(),
            info.image.height.toDouble(),
          );
        });
      },
      onError: (e, st) {
        if (mounted) setState(() => _failed = true);
      },
    );
    _stream = stream;
    _listener = listener;
    stream.addListener(listener);
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: const Center(
          child: Icon(Icons.broken_image_outlined,
              color: Colors.white54, size: 48),
        ),
      );
    }
    final ps = _pixelSize;
    final provider = _provider;
    if (ps == null || provider == null) {
      return const Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white38),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, c) {
        final vp = Size(c.maxWidth, c.maxHeight);
        final fit = math.min(vp.width / ps.width, vp.height / ps.height);
        final content = Size(ps.width * fit, ps.height * fit);

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          onDoubleTap: () => _toggleZoom(vp, content),
          child: InteractiveViewer(
            transformationController: _tc,
            minScale: 1,
            maxScale: 6,
            // 没放大时不抢横向手势，交给 PageView 翻页
            panEnabled: _zoomed,
            scaleEnabled: true,
            // InteractiveViewer 的边界是按 child 的**布局尺寸**算的，而我们的 child 是整个
            // 视口、图片居中摆在里面，左右本来就有留白。它拦不住「在留白里横向拖」，
            // 横屏双击填满后仍能拖出黑边。这里关掉它的内建边界，换成按图片实际
            // 可视矩形自己钳制（见 _clampMatrix）。
            boundaryMargin: const EdgeInsets.all(double.infinity),
            onInteractionStart: (_) {
              _swipeX = 0;
              _swipeConsumed = false;
            },
            onInteractionUpdate: (d) {
              _clampMatrix(vp, content);
              _maybeSwipe(vp, content, d.focalPointDelta.dx);
            },
            onInteractionEnd: (_) {
              _clampMatrix(vp, content);
              _syncZoomMode();
            },
            child: SizedBox(
              width: vp.width,
              height: vp.height,
              child: Center(
                child: SizedBox(
                  width: content.width,
                  height: content.height,
                  child: Image(
                    image: provider,
                    fit: BoxFit.fill,
                    gaplessPlayback: true,
                    filterQuality: FilterQuality.medium,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 放大后横向已经拖不动了（双击填满的竖图），此时横向滑动应当切上/下一张。
  ///
  /// 棘手之处：放大后单指手势被 InteractiveViewer 接管，PageView 根本收不到，
  /// 光靠钳制只会「拖不动也不翻页」。所以在这里把横向位移自己攒起来，
  /// 过阈值就主动翻一页。横向还有平移余地时（放大的横图）不拦，照常平移。
  void _maybeSwipe(Size vp, Size content, double dx) {
    if (_swipeConsumed || widget.onSwipe == null || dx == 0) return;
    final s = _tc.value.getMaxScaleOnAxis();
    if (content.width * s > vp.width + 1) return;
    _swipeX += dx;
    if (_swipeX.abs() < 64) return;
    final dir = _swipeX < 0 ? 1 : -1;
    _swipeX = 0;
    _swipeConsumed = true;
    widget.onSwipe!(dir);
  }

  /// 手势结束后刷新一次状态：`_zoomed` 决定要不要吃掉横向手势，
  /// 缩放比变了则重算「还要不要自己接管纵向」。两者都只影响 build 的入参，
  /// 所以统一 setState 重算一次即可。
  void _syncZoomMode() {
    final z = _tc.value.getMaxScaleOnAxis() > 1.01;
    setState(() => _zoomed = z);
  }

  /// 把变换矩阵的平移量钳制在「图片不能露出背景」的范围内。
  ///
  /// 规则跟微信一致：
  /// - 缩放后的图片比视口窄 → 那一轴没有可拖的余地，钉死在居中
  /// - 比视口宽 → 允许平移，但图片边缘不能进到视口内部（左右拖到边就停）
  ///
  /// 横屏竖图双击填满后，横向刚好等于视口宽，于是横向被锁死、只剩上下能拖，
  /// 正是要看图片不同高度时该有的手感。
  void _clampMatrix(Size vp, Size content) {
    final m = _tc.value;
    final s = m.getMaxScaleOnAxis();
    if (s <= 0 || content.width <= 0 || content.height <= 0) return;

    final e = _clampAxis(m.storage[12], s, vp.width, content.width);
    final f = _clampAxis(m.storage[13], s, vp.height, content.height);
    if ((e - m.storage[12]).abs() < 0.5 && (f - m.storage[13]).abs() < 0.5) {
      return;
    }
    _tc.value = m.clone()
      ..setEntry(0, 3, e)
      ..setEntry(1, 3, f);
  }

  /// 单轴钳制。[offset] 是矩阵在该轴的平移量（`storage[12]` / `storage[13]`）。
  ///
  /// 图片在 child 里居中，缩放 s 后它的左/右边缘相对 offset 分别是
  /// `s*(vp-content)/2` 和 `s*(vp+content)/2`，据此反推 offset 的合法区间。
  double _clampAxis(double offset, double s, double vp, double content) {
    final left = s * (vp - content) / 2;
    final right = s * (vp + content) / 2;
    final minOffset = vp - right; // 右边缘贴住视口右边
    final maxOffset = -left; // 左边缘贴住视口左边
    if (minOffset > maxOffset) {
      // 内容比视口窄：可拖空间为负，直接钉在居中
      return vp * (1 - s) / 2;
    }
    return offset.clamp(minOffset, maxOffset);
  }

  /// 双击：整图 ↔ 宽度填满。
  ///
  /// 「填满」= 把图片缩放到横向刚好铺满屏幕，此时竖图的高度会超出屏幕，
  /// 于是单指上下拨就能看图片的上中下不同部分（横屏看作业照片正是这个用法）。
  void _toggleZoom(Size vp, Size content) {
    final current = _tc.value.getMaxScaleOnAxis();
    final Matrix4 target;
    var zoomingIn = false;

    if (current > 1.01) {
      target = Matrix4.identity();
    } else {
      // 横向填满所需倍率；本来就已经填满（宽图）就放大到 2 倍
      var k = vp.width / content.width;
      if (k < 1.02) k = 2.0;
      final canvasW = vp.width * k;
      final canvasH = vp.height * k;
      // 图片在画布里居中，算出「图片左上角对齐视口左上角」需要的位移
      final tx = (canvasW - vp.width) / 2;
      final ty = (canvasH - content.height * k) / 2;
      target = Matrix4.identity()..translate(-tx, -ty)..scale(k);
      zoomingIn = true;
    }

    _tween = Matrix4Tween(begin: _tc.value, end: target)
        .chain(CurveTween(curve: Curves.easeOutCubic))
        .animate(_anim);
    setState(() => _zoomed = zoomingIn);
    _anim
      ..reset()
      ..forward();
  }
}
