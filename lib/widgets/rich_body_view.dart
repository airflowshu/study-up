import 'package:flutter/material.dart';

import '../core/rich_body.dart';
import '../core/theme.dart';
import 'image_grid.dart';
import 'image_stack.dart';

enum RichImageLayout {
  /// 详情页：多图铺成网格，一眼看全
  grid,

  /// 卡片 / 窄容器：多图叠成一小摞，点「展开 N」
  folded,
}

/// 图文混排正文：按正文里的 `[图n]` 标记把图片插回原来的位置。
///
/// 没有标记的老作业，图片照样按顺序排在文字后面，与升级前一致。
class RichBody extends StatelessWidget {
  const RichBody({
    super.key,
    required this.content,
    required this.images,
    this.style,
    this.layout = RichImageLayout.grid,
    this.singleImageWidth = 240,
    this.blockSpacing = 10,
  });

  final String content;
  final List<String> images;
  final TextStyle? style;
  final RichImageLayout layout;

  /// 单张内嵌图的最大宽度（高度按 3:4 走，家长拍的多是竖版作业页）
  final double singleImageWidth;
  final double blockSpacing;

  @override
  Widget build(BuildContext context) {
    final blocks = parseBody(content, images.length);
    if (blocks.isEmpty) return const SizedBox.shrink();

    final base = style ?? const TextStyle(fontSize: 14, height: 1.6);

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth.isFinite ? constraints.maxWidth : 320.0;
        final children = <Widget>[];
        for (final b in blocks) {
          if (children.isNotEmpty) {
            children.add(SizedBox(height: blockSpacing));
          }
          if (b.isImage) {
            children.add(_imageBlock(context, b.images, maxWidth));
          } else {
            children.add(Text(b.text, style: base));
          }
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: children,
        );
      },
    );
  }

  Widget _imageBlock(BuildContext context, List<int> indexes, double maxWidth) {
    final refs = [for (final i in indexes) images[i - 1]];
    if (indexes.length == 1) {
      final w = maxWidth < singleImageWidth ? maxWidth : singleImageWidth;
      return _SingleImage(
        ref: refs.first,
        width: w,
        onTap: () => openImageViewer(context, images, indexes.first - 1),
      );
    }
    if (layout == RichImageLayout.folded) {
      return StackedImages(images: refs, tile: 92);
    }
    return ImageGrid(images: refs, maxColumns: 6);
  }
}

class _SingleImage extends StatelessWidget {
  const _SingleImage({
    required this.ref,
    required this.width,
    required this.onTap,
  });

  final String ref;
  final double width;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // 固定 3:4 的框：图片加载前后高度不变，列表不会跳。
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: Container(
          width: width,
          height: width * 4 / 3,
          color: AppColors.surface2,
          child: buildImageRef(ref, thumbWidth: (width * 2).round()),
        ),
      ),
    );
  }
}

/// 卡片里用的纯文字预览：去掉标记、截断。图片另行折叠展示。
String richPreviewText(String content) => plainText(content);

/// 行内标记在输入框里的配色（编辑器用）
///
/// 做成 getter 而不是 const：主色跟着明暗主题走，高亮底色也要跟着变，
/// 否则深色背景下那层淡蓝底会糊成一片。
TextStyle get kMarkerSpanStyle => TextStyle(
      color: AppColors.primaryInk,
      fontWeight: FontWeight.w600,
      backgroundColor: AppColors.primary.withValues(alpha: 0.14),
    );

/// 待补图的 `[图片]` 占位：橙色，一眼看出这儿还缺一张图，
/// 从相册补图时会自动填进这个位置。
TextStyle get kHoleSpanStyle => TextStyle(
      color: AppColors.isDark ? AppColors.warningInk : const Color(0xFFC77700),
      fontWeight: FontWeight.w600,
      backgroundColor: AppColors.warning.withValues(alpha: 0.15),
    );
