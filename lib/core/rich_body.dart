/// 图文混排正文。
///
/// 正文仍然是**一段纯文本**，图片的位置用行内标记 `[图3]` 表示（3 = 第 3 张图）。
///
/// 为什么用可见标记，而不是「图片序号 + 字符偏移」：
/// 标记本身就是几个字符，选中、删除、剪切、粘贴、撤销全都天然生效。
/// 家长想把一张图从末尾挪到第二段后面，只要把那几个字符剪过去就行，
/// 既不用做拖拽交互，也不会因为改了正文文字让偏移量失效。
///
/// 标记只存在本地和云端的一条 `content` 字段里，数据库不用改结构；
/// 老数据没有标记时，图片按顺序排在正文末尾，表现和升级前一致。
library;

/// 严格合法的标记
final RegExp kImageMarker = RegExp(r'\[图(\d{1,3})\]');

/// 宽松版：连写坏的标记一起认（`[图1`、`[图12]`）。
///
/// 必须带数字。家长正文里出现「[图片]」这种写法很常见
/// （「口头作业请见图片」就常写成「[图片]」），一旦把 `[图` 也当成标记，
/// 正文会被吃成「片]」，所以这里只认 `[图` 后面紧跟数字的。
final RegExp _markerOrFragment = RegExp(r'\[图(\d{1,3})\]?');

/// 生成标记，[index] 从 1 开始。
String imageMarker(int index) => '[图$index]';

/// 待补图占位。
///
/// 微信/QQ 把一条图文消息「复制」到剪贴板时，图片并不会跟着进剪贴板，
/// 只在文字里留一个字面的 `[图片]`。这几个字没法变成图，但它是**图片原来
/// 所在的位置**：家长之后从相册补图时，把新图落到这儿，位置天然是对的。
final RegExp kImageHole = RegExp(r'\[图片\]');

/// 占位文字的长度（`[图片]` 共 4 个字符）。
const int kImageHoleLength = 4;

/// 正文里待补图的占位，按出现顺序返回起始下标。
List<int> imageHoles(String content) => [
      for (final m in kImageHole.allMatches(content)) m.start,
    ];

/// 输入框高亮用：合法标记与待补占位一起匹配，靠分组区分样式。
final RegExp kMarkerOrHole = RegExp(r'\[图(\d{1,3})\]|\[图片\]');

/// 补位结果。
class HoleFill {
  const HoleFill(this.text, this.filled);

  final String text;

  /// 实际填掉了几个占位
  final int filled;
}

/// 把正文里前 [count] 个 `[图片]` 占位依次换成从 [firstIndex] 起的图片标记。
///
/// 微信复制图文消息时，图片位置只剩一个字面 `[图片]`；家长之后从相册补图，
/// 新图正好该落回这些位置。占位不够就只填现有的，多出来的图由调用方另行处理。
/// 标记单独占一行，和正文挤在一起不好看。
HoleFill fillImageHoles(String content, int firstIndex, int count) {
  final holes = imageHoles(content);
  if (holes.isEmpty || count <= 0) return HoleFill(content, 0);
  final use = holes.length < count ? holes.length : count;
  var text = content;
  // 从后往前替换，前面占位的位置不受影响
  for (var i = use - 1; i >= 0; i--) {
    final pos = holes[i];
    final end = pos + kImageHoleLength;
    final marker = imageMarker(firstIndex + i);
    final prevCh = pos > 0 ? text[pos - 1] : '\n';
    final nextCh = end < text.length ? text[end] : '\n';
    final chunk = '${prevCh == '\n' ? '' : '\n'}$marker'
        '${nextCh == '\n' ? '' : '\n'}';
    text = text.substring(0, pos) + chunk + text.substring(end);
  }
  return HoleFill(text, use);
}

/// 正文字数：标记不算字数。
int plainLength(String content) =>
    content.replaceAll(_markerOrFragment, '').replaceAll(RegExp(r'\s'), '').length;

/// 去掉标记的纯文字，列表摘要用。
/// 标记独占一行时删完会留下空行，摘要只有两三行，空行会白占高度，
/// 所以这里把空行一并压掉。
String plainText(String content) {
  final s = content.replaceAll(_markerOrFragment, '');
  final lines = s
      .replaceAll(RegExp(r'\r\n?'), '\n')
      .split('\n')
      .map((l) => l.replaceAll(RegExp(r'[ \t]+'), ' ').trim())
      .where((l) => l.isNotEmpty);
  return lines.join('\n').trim();
}

/// 排版单元：要么是一段文字，要么是一组连续的图片。
class BodyBlock {
  const BodyBlock.text(this.text) : images = const [];

  const BodyBlock.images(this.images) : text = '';

  final String text;

  /// 1 开始的图片序号，连续多张时合成一组
  final List<int> images;

  bool get isImage => images.isNotEmpty;
}

/// 把正文拆成「文字 / 图片组」的序列。
/// [imageCount] 是实际图片张数。序号越界、重复的标记当普通文字留着，
/// 不删 —— 正文是家长写的，宁可多显示几个字也不能悄悄吞掉。
List<BodyBlock> parseBody(String content, int imageCount) {
  final blocks = <BodyBlock>[];
  final buf = StringBuffer();
  final seen = <int>{};
  var group = <int>[];

  void flushText() {
    final s = _tidy(buf.toString());
    buf.clear();
    if (s.isNotEmpty) blocks.add(BodyBlock.text(s));
  }

  void flushGroup() {
    if (group.isEmpty) return;
    blocks.add(BodyBlock.images(group));
    group = [];
  }

  var cursor = 0;
  for (final m in _markerOrFragment.allMatches(content)) {
    final between = content.substring(cursor, m.start);
    cursor = m.end;
    buf.write(between);
    final idx = int.tryParse(m.group(1) ?? '') ?? 0;

    if (idx < 1 || idx > imageCount || !seen.add(idx)) {
      // 不是有效标记：原样留在正文里
      buf.write(m.group(0));
      continue;
    }
    if (group.isEmpty) {
      // 图片前的文字先出块
      flushText();
    } else if (between.trim().isEmpty) {
      // 和上一张紧挨着（中间只有空白）：并进同一组，才能折叠成「展开 N」
      buf.clear();
    } else {
      flushGroup();
      flushText();
    }
    group.add(idx);
  }
  buf.write(content.substring(cursor));
  flushGroup();
  flushText();

  // 正文里没出现的图（老数据、标记被删坏）统一补在末尾，绝不丢图
  final missing = [
    for (var k = 1; k <= imageCount; k++)
      if (!seen.contains(k)) k
  ];
  if (missing.isNotEmpty) blocks.add(BodyBlock.images(missing));
  return blocks;
}

String _tidy(String s) {
  var t = s.replaceAll(RegExp(r'\r\n?'), '\n');
  // 行内多余空格保留一个，行首行尾的空格去掉
  t = t
      .split('\n')
      .map((l) => l.replaceAll(RegExp(r'[ \t]+'), ' ').trim())
      .join('\n');
  return t.replaceAll(RegExp(r'^\n+|\n+$'), '');
}

/// 保存前整理正文：
/// - 合法标记保留（重复的只留第一个）
/// - 序号越界的标记当普通文字留着，不删用户写的字
/// - 没有被标记引用的图片，在末尾补上标记（保证「每张图都在正文里有一处位置」）
///
/// 这样无论用户怎么把手抖删成半个标记，都不会出现「图在、位置丢了」。
String normalizeBody(String content, int imageCount) {
  final buf = StringBuffer();
  final seen = <int>{};
  var cursor = 0;
  for (final m in _markerOrFragment.allMatches(content)) {
    buf.write(content.substring(cursor, m.start));
    cursor = m.end;
    final idx = int.tryParse(m.group(1) ?? '') ?? 0;
    if (idx >= 1 && idx <= imageCount) {
      // 重复的只留第一个
      if (seen.add(idx)) buf.write(imageMarker(idx));
    } else {
      // 序号越界的当普通文字留着
      buf.write(m.group(0));
    }
  }
  buf.write(content.substring(cursor));

  var out = buf.toString().replaceAll(RegExp(r'[ \t]+\n'), '\n').trim();
  final missing = [
    for (var k = 1; k <= imageCount; k++)
      if (!seen.contains(k)) k
  ];
  if (missing.isNotEmpty) {
    final tail = missing.map(imageMarker).join('');
    out = out.isEmpty ? tail : '$out\n$tail';
  }
  return out;
}

/// 删掉第 [index]（1 开始）张图对应的标记，并把后面的大序号整体减一。
String removeImageMarker(String content, int index) {
  return content.replaceAllMapped(_markerOrFragment, (m) {
    final idx = int.tryParse(m.group(1) ?? '') ?? 0;
    if (idx == index) return '';
    if (idx > index) return imageMarker(idx - 1);
    return m.group(0)!;
  });
}

// ---------------- 剪贴板 HTML → 图片位置 ----------------

/// 从 HTML 里抽出的正文与图片位置。
class HtmlBody {
  const HtmlBody(this.text, this.imageOffsets);

  final String text;

  /// 每张图在 [text] 里的字符下标
  final List<int> imageOffsets;
}

/// 解析剪贴板里的 HTML。网页、备忘录、WPS 复制时会带这份 HTML，
/// 图片在原文第几段后面是能还原的；微信复制不带（html 为空）。
HtmlBody parseHtmlBody(String html) {
  final cleaned = html.replaceAll(
    RegExp(r'<(script|style)[^>]*>[\s\S]*?</\1>', caseSensitive: false),
    '',
  );
  final token = RegExp(
    r'<img\b[^>]*>|<br\s*/?>|</(?:p|div|li|h[1-6]|tr|section|article|blockquote)\s*>|<[^>]+>',
    caseSensitive: false,
  );
  final buf = StringBuffer();
  final offsets = <int>[];
  var cursor = 0;
  for (final m in token.allMatches(cleaned)) {
    buf.write(_decodeEntities(cleaned.substring(cursor, m.start)));
    final tag = m.group(0)!.toLowerCase();
    if (tag.startsWith('<img')) {
      offsets.add(buf.length);
    } else if (tag.startsWith('</') || tag.startsWith('<br')) {
      // 段末补换行，保证图片位置落在段落边界上
      if (buf.isNotEmpty && !buf.toString().endsWith('\n')) buf.write('\n');
    }
    cursor = m.end;
  }
  buf.write(_decodeEntities(cleaned.substring(cursor)));
  return HtmlBody(buf.toString(), offsets);
}

String _decodeEntities(String s) {
  if (!s.contains('&')) return s;
  return s
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');
}

/// 把 HTML 里的图片位置换算成「粘贴进来的那段文字」里的下标。
///
/// 对不上（HTML 文字和实际粘进来的文字不一致）就返回空数组，
/// 调用方退回「全部放在粘贴处末尾」，绝不乱插。
List<int> mapHtmlImageOffsets(HtmlBody body, String pasted) {
  final bodyIdx = <int>[];
  for (var i = 0; i < body.text.length; i++) {
    if (!_isSpace(body.text[i])) bodyIdx.add(i);
  }
  final pastedIdx = <int>[];
  for (var i = 0; i < pasted.length; i++) {
    if (!_isSpace(pasted[i])) pastedIdx.add(i);
  }
  if (bodyIdx.isEmpty || bodyIdx.length != pastedIdx.length) return const [];
  for (var k = 0; k < bodyIdx.length; k++) {
    if (body.text[bodyIdx[k]] != pasted[pastedIdx[k]]) return const [];
  }

  final out = <int>[];
  for (final off in body.imageOffsets) {
    var k = 0;
    while (k < bodyIdx.length && bodyIdx[k] < off) {
      k++;
    }
    out.add(k < pastedIdx.length ? pastedIdx[k] : pasted.length);
  }
  return out;
}

bool _isSpace(String ch) => ch == ' ' || ch == '\n' || ch == '\r' || ch == '\t';
