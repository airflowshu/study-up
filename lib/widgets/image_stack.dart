import 'package:flutter/material.dart';

import '../core/motion.dart';
import '../core/theme.dart';
import 'image_grid.dart';

/// 多图折叠预览（微信式）：默认叠成一小摞，右下角「展开 N」。
/// 点图直接全屏逐张看，点「展开 N」才在原地铺成网格。
///
/// 单图时不做折叠，就是一张缩略图 —— 免得只有一张图也顶着个「展开 1」。
class StackedImages extends StatefulWidget {
  const StackedImages({
    super.key,
    required this.images,
    this.tile = 84,
    this.maxColumns = 5,
  });

  final List<String> images;
  final double tile;

  /// 展开后网格最多几列
  final int maxColumns;

  @override
  State<StackedImages> createState() => _StackedImagesState();
}

class _StackedImagesState extends State<StackedImages> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    if (widget.images.isEmpty) return const SizedBox.shrink();
    // 不用 AnimatedSize：它依赖 ticker，放在卡片列表里偶发首帧高度为 0，
    // 表现为「图片区整个不见」。折叠/展开直接切换，代价小且稳。
    //
    // 尺寸保持硬切（不碰布局），但让新到的那一版淡入 170ms：
    // 硬切会让整块内容「啪」一下换掉，淡入之后读起来是「换了一版」。
    return RevealOnMount(
      // key 变了才会重播——同一个 key 下反复 setState 不会闪。
      key: ValueKey(_expanded),
      duration: AppMotion.quick,
      offsetY: 0,
      scaleFrom: 0.97,
      child: _expanded ? _expandedGrid() : _collapsed(),
    );
  }

  // ---------------- 折叠态 ----------------

  Widget _collapsed() {
    final images = widget.images;
    if (images.length == 1) {
      return _thumbTile(0, widget.tile);
    }

    final depth = images.length >= 3 ? 3 : 2;
    final step = (widget.tile * 0.07).clamp(3.0, 8.0);
    final total = widget.tile + step * (depth - 1);

    return SizedBox(
      width: total,
      height: total,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // 后面的纸片从深到浅铺，露出右下两条边
          for (var i = depth - 1; i >= 1; i--)
            Positioned(
              left: step * i,
              top: step * i,
              child: Container(
                width: widget.tile,
                height: widget.tile,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  border: Border.all(color: AppColors.border),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x0F000000),
                      blurRadius: 3,
                      offset: Offset(0, 1),
                    ),
                  ],
                ),
              ),
            ),
          Positioned(left: 0, top: 0, child: _thumbTile(0, widget.tile)),
          Positioned(
            left: widget.tile - 46,
            top: widget.tile - 20,
            child: _expandBadge(images.length),
          ),
        ],
      ),
    );
  }

  Widget _thumbTile(int index, double size) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => openImageViewer(context, widget.images, index),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: SizedBox(
          width: size,
          height: size,
          child: buildImageRef(
            widget.images[index],
            thumbWidth: (size * 2).round(),
          ),
        ),
      ),
    );
  }

  Widget _expandBadge(int count) {
    return Semantics(
      button: true,
      label: '展开 $count 张图片',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _expanded = true),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
          decoration: BoxDecoration(
            color: const Color(0xD91A1D26),
            borderRadius: BorderRadius.circular(AppRadius.xs),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '展开',
                style: TextStyle(
                  fontSize: 10,
                  color: Colors.white,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 2),
              Text(
                '$count',
                style: const TextStyle(
                  fontSize: 10,
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------- 展开态 ----------------

  Widget _expandedGrid() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ImageGrid(images: widget.images, maxColumns: widget.maxColumns),
        const SizedBox(height: 4),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _expanded = false),
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.unfold_less,
                    size: 13, color: AppColors.textSecondary),
                SizedBox(width: 3),
                Text(
                  '收起',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
