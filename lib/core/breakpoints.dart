/// 屏幕断点。判定只看可用宽度，不看 orientation —— 平板分屏、小窗、
/// 折叠屏展开时 orientation 值不可靠，宽度才是唯一可信依据。
class Breakpoints {
  static const double compactMax = 600;
  static const double expandedMin = 840;
}

enum DeviceType { compact, medium, expanded }

DeviceType deviceTypeOf(double width) {
  if (width < Breakpoints.compactMax) return DeviceType.compact;
  if (width < Breakpoints.expandedMin) return DeviceType.medium;
  return DeviceType.expanded;
}

/// 内容最大行宽。一行字横跨 1280dp 极难阅读，超出时居中留白。
const double kMaxReadingWidth = 720;

/// 图片网格列数：随可用宽度自适应，且限制在 2–8 列之间。
int imageColumnsFor(double availableWidth) {
  final n = (availableWidth / 140).floor();
  return n.clamp(2, 8);
}
