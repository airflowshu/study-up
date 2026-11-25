import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../core/breakpoints.dart';
import '../../core/rich_body.dart';
import '../../core/theme.dart';
import '../../core/utils.dart';
import '../../data/clipboard_paste.dart';
import '../../data/link_preview.dart';
import '../../data/repository.dart';
import '../../models/models.dart';
import '../../state/app_state.dart';
import '../../widgets/attachment_card.dart';
import '../../widgets/common.dart';
import '../../widgets/image_grid.dart';
import '../../widgets/rich_body_view.dart';

const _subjectOptions = ['语文', '数学', '英语', '科学', '道法', '体育', '美术', '音乐'];

/// 新建 / 编辑作业。
/// 关键约束：表单状态全部放在 State 里，横竖屏切换、分屏拖动都不得丢草稿。
class HomeworkEditPage extends StatefulWidget {
  const HomeworkEditPage({
    super.key,
    required this.childId,
    required this.date,
    this.existing,
  });

  final String childId;
  final DateTime date;
  final Homework? existing;

  @override
  State<HomeworkEditPage> createState() => _HomeworkEditPageState();
}

class _HomeworkEditPageState extends State<HomeworkEditPage>
    with WidgetsBindingObserver {
  final _repo = Repository.instance;

  /// 正文里带 `[图N]` 位置标记，所以要自定义 controller 把标记画得显眼一点
  final _contentController = _MarkerController();
  final _customSubjectController = TextEditingController();
  final _picker = ImagePicker();

  late String _subject;
  late DateTime _date;

  /// 图片列表，按槽位对齐：第 i 项是第 i 张图。
  /// 每项是「本地文件路径」，没有本地原图时是空串。
  ///
  /// 为什么要单独存本地路径：作业可能来自别的设备（另一台平板、重装后的新机），
  /// 那种作业本机没有原图，只有云存储 key。早期版本直接读 `images`，
  /// 这类作业一进编辑页图片就全没了。
  late List<String> _images;

  /// 与 _images 等长、按槽位对齐的云端 key。新加的图片先留空，保存后由同步引擎上传填充。
  late List<String> _imageKeys;

  /// 附件与链接卡片。顺序即渲染顺序，统一排在图片之后，不参与正文内联。
  late List<Attachment> _attachments;

  /// 展示用的图片引用：本地有原图就用本地路径，否则用 `cloud:key`。
  /// 下标与 _images 一一对应，`[图N]` 的序号才不会错位。
  ///
  /// 取图口径直接复用模型层的 [alignImageSlots]，跟卡片、详情页是同一套规则，
  /// 不会出现「列表能显示、编辑页不显示」这种两边口径不一致的情况。
  List<String> get _refs => [
        for (final s in alignImageSlots(_images, _imageKeys)) s.ref,
      ];

  /// 「共 N 张 · 大小」那行字。
  ///
  /// 云端图没有本地文件，算不出大小，所以只在有本地原图时才显示体积；
  /// 全是云端图就只报张数，免得显示成误导人的「0 B」。
  String get _imageStat {
    if (_images.isEmpty) return '不限张数';
    final bytes = _images.fold<int>(
      0,
      (s, e) => s + (e.isEmpty ? 0 : fileSizeOf(e)),
    );
    if (bytes <= 0) return '共 ${_images.length} 张';
    return '共 ${_images.length} 张 · ${formatBytes(bytes)}';
  }
  bool _busy = false;
  bool _useCustomSubject = false;

  /// 剪贴板探查结果与导入状态。
  /// 家长从微信/相册「复制」过来的图往往是一串 content://，Flutter 的剪贴板
  /// 只拿得到文字，所以图片交给原生通道读，这里只管展示与去重。
  ClipPayload? _clip;
  bool _clipBusy = false;
  String _clipImportedFp = '';
  String _lastText = '';

  /// 已经提醒过「这份剪贴板只有文字没有图」的那份内容指纹，避免反复弹提示。
  String _holeHintedFp = '';

  /// 最近一次「粘贴」插进来的文字在正文里的范围。
  /// 图片位置要靠它换算：粘进来的第 37 个字处有一张图 →
  /// 换算成正文里的绝对下标，再把 [图N] 写到那儿。
  int? _pasteStart;
  int? _pasteEnd;
  Timer? _pasteDebounce;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final e = widget.existing;
    _subject = e?.subject ?? '语文';
    _date = e == null ? widget.date : parseDateKey(e.date);
    // 逐槽位对齐本地路径与云 key。
    // images 与 imageKeys 是按下标一一对应的两列：本地有原图就填路径，
    // 没有就留空串，只把 key 那一列填上。两列对不齐时以图片总数为准补齐，
    // `[图N]` 的序号才不会错位。
    final local = e?.images ?? const <String>[];
    final keys = e?.imageKeys ?? const <String>[];
    final total = local.length > keys.length ? local.length : keys.length;
    _images = [for (var i = 0; i < total; i++) i < local.length ? local[i] : ''];
    _imageKeys = [for (var i = 0; i < total; i++) i < keys.length ? keys[i] : ''];
    _attachments = List<Attachment>.from(e?.attachments ?? const []);
    // 老作业没有位置标记：补在末尾，图片看着和升级前一样，
    // 但从此每张图都能被拖到正文任意位置。
    _contentController.text = normalizeBody(e?.content ?? '', _images.length);
    _lastText = _contentController.text;
    _useCustomSubject = !_subjectOptions.contains(_subject);
    if (_useCustomSubject) _customSubjectController.text = _subject;

    // 首帧之后再探剪贴板：进页面就能看到「剪贴板里有 3 张图片」的提示
    WidgetsBinding.instance.addPostFrameCallback((_) => _probeClipboard());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从微信复制完切回来，立刻刷新提示
    if (state == AppLifecycleState.resumed) _probeClipboard();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pasteDebounce?.cancel();
    _contentController.dispose();
    _customSubjectController.dispose();
    super.dispose();
  }

  // ---------------- 剪贴板 ----------------

  Future<void> _probeClipboard({bool auto = false, String? pastedText}) async {
    final p = await ClipboardPaste.instance.peek(force: true);
    if (!mounted) return;
    setState(() => _clip = p);
    if (!auto || p == null) return;
    if (!p.hasImages) {
      _hintHoleWithoutImage(p, pastedText);
      return;
    }
    if (p.fingerprint.isNotEmpty && p.fingerprint == _clipImportedFp) return;

    // 判定「这次粘的就是剪贴板里那一份」。
    // 不再用「2 分钟内」这种时间闸门：家长从微信复制完，切到 App、过家庭码、
    // 选学科、点新建，很容易超过两分钟，结果就是明明粘了还要再点一次「粘贴」。
    // 改成看内容对不对得上——粘进来的文字和剪贴板文字一致（或包含），
    // 就是同一份，直接收图。
    //
    // 两个不自动的情况：
    //  - 剪贴板只有图没有文字：没法判断用户是不是要这份，留提示条让他自己点
    //  - 有文字但对不上：说明粘的是别处的内容，把旧图塞进来就是误插
    if (!p.hasText) return;
    if (!_clipTextMatches(p.text, pastedText ?? '')) return;
    await _applyClipImages(p, auto: true, pastedText: pastedText);
  }

  /// 剪贴板里只有文字、图却没跟过来时的说明。
  ///
  /// 微信把一条图文消息「复制」到剪贴板时，图片并不会进剪贴板，只在文字里留一个
  /// 字面的 `[图片]`。这时候 App 什么也不做会让人以为坏了，所以明确说一句，
  /// 顺带告诉他：从相册补的图会自动落回这些 `[图片]` 的位置。
  void _hintHoleWithoutImage(ClipPayload p, String? pastedText) {
    if (pastedText == null || !kImageHole.hasMatch(pastedText)) return;
    if (p.fingerprint.isNotEmpty && p.fingerprint == _holeHintedFp) return;
    _holeHintedFp = p.fingerprint;
    _toast('图片没随文字一起复制过来：来源只给了文字。点「添加」从相册选图，会自动补到 [图片] 的位置');
  }

  /// 剪贴板文本与输入框文本是否是同一份内容。
  /// 忽略空白差异，因为微信复制出来的文本常带首尾空行、段间多余换行。
  bool _clipTextMatches(String clipText, String fieldText) {
    String compact(String s) => s.replaceAll(RegExp(r'\s+'), '');
    final c = compact(clipText);
    final f = compact(fieldText);
    if (c.isEmpty || f.isEmpty) return false;
    if (f == c || f.contains(c)) return true;
    // 用户在输入框里接着敲了字，导致完全相等不成立时，取头部比对
    if (c.length < 4) return false;
    final head = c.length > 24 ? c.substring(0, 24) : c;
    return f.contains(head);
  }

  /// 明确的「粘贴」动作：不看新鲜度，剪贴板里有图就收。
  Future<void> _pasteFromClipboard() async {
    final p = await ClipboardPaste.instance.peek(force: true);
    if (!mounted) return;
    setState(() => _clip = p);
    if (p == null || !p.hasImages) {
      _toast('剪贴板里没有图片');
      return;
    }
    await _applyClipImages(p);
  }

  /// 读取剪贴板图片 → 与已有图片按文件指纹去重 → 追加到列表 → 把位置标记写进正文。
  Future<void> _applyClipImages(
    ClipPayload p, {
    bool auto = false,
    String? pastedText,
  }) async {
    if (_clipBusy) return;
    if (p.fingerprint.isNotEmpty && p.fingerprint == _clipImportedFp) return;

    setState(() => _clipBusy = true);
    final paths = await ClipboardPaste.instance.importImages(uris: p.uris);
    if (!mounted) return;

    if (paths.isEmpty) {
      // 读不出来就把这条提示收掉：多半是来源 App 的 URI 授权已过期，
      // 留着提示条也没用，让家长走相册更直接。
      setState(() {
        _clipBusy = false;
        _clipImportedFp = p.fingerprint;
      });
      if (!auto) _toast('剪贴板里的图片读不出来，试试「从相册选择」');
      return;
    }

    final seen = <String>{};
    for (final img in _images) {
      // 云端图没有本地文件，算不出指纹，跳过（否则会把所有云端图当成同一张）
      if (img.isEmpty) continue;
      final sig = await ClipboardPaste.instance.signatureOf(img);
      if (sig.isNotEmpty) seen.add(sig);
    }
    final added = <String>[];
    for (final path in paths) {
      final sig = await ClipboardPaste.instance.signatureOf(path);
      if (sig.isNotEmpty && seen.contains(sig)) continue;
      if (sig.isNotEmpty) seen.add(sig);
      added.add(path);
    }
    if (!mounted) return;

    if (added.isEmpty) {
      setState(() {
        _clipImportedFp = p.fingerprint;
        _clipBusy = false;
      });
      _toast('这几张图已经在列表里了');
      return;
    }

    final firstIndex = _images.length + 1;
    setState(() {
      _clipImportedFp = p.fingerprint;
      _clipBusy = false;
      _images.addAll(added);
      _imageKeys.addAll(List<String>.filled(added.length, ''));
    });

    final atOrigin = _insertImageMarkers(
      firstIndex: firstIndex,
      count: added.length,
      payload: p,
      pastedText: pastedText,
    );
    _toast(atOrigin
        ? '已粘贴 ${added.length} 张图片，落在原文位置'
        : '已粘贴 ${added.length} 张图片，位置见正文里的 [图N]，可随意挪动');
  }

  /// 把新加的 [count] 张图的位置标记写进正文，返回是否落在了原文位置上。
  ///
  /// 位置来源有三种，按优先级：
  /// 1. **正文里的 `[图片]` 占位**：微信复制图文消息只给文字，图片位置留成
  ///    字面 `[图片]`。家长从相册补的图直接填进这些占位，位置天然正确，
  ///    不用再手动把 `[图N]` 搬到原来的地方。
  /// 2. 剪贴板 HTML（网页、备忘录、WPS 复制）：能算出每张图原来在第几个字之后。
  /// 3. 都没有：插在光标处（或正文末尾）。
  ///
  /// 无论哪种，标记都写进正文，之后家长想挪位置直接挪那几个字符即可。
  bool _insertImageMarkers({
    required int firstIndex,
    required int count,
    ClipPayload? payload,
    String? pastedText,
    int? at,
  }) {
    if (count <= 0) return false;
    var text = _contentController.text;

    // ---- 1) 先补 [图片] 占位 ----
    final hole = fillImageHoles(text, firstIndex, count);
    text = hole.text;
    var filled = hole.filled;

    // ---- 2) 剩下的图按 HTML 位置 / 光标位置插 ----
    // 只补了占位时，光标放到末尾（原文的图本来就在结尾处）
    var caret = text.length;
    final rest = count - filled;
    if (rest > 0) {
      final slots = <int, List<String>>{};
      var byHtml = false;

      final start = _pasteStart;
      final end = _pasteEnd;
      // 已经填过占位就说明正文里图的位置来自文本本身，HTML 那套偏移量
      // 对的是粘贴进来的原文，这会儿正文已经变过，不再混用。
      if (filled == 0 &&
          payload != null &&
          payload.html.isNotEmpty &&
          pastedText != null &&
          pastedText.isNotEmpty &&
          start != null &&
          end != null &&
          end > start) {
        final body = parseHtmlBody(payload.html);
        final rels = mapHtmlImageOffsets(body, pastedText);
        if (rels.length == count) {
          byHtml = true;
          for (var k = 0; k < count; k++) {
            final pos = (start + rels[k]).clamp(0, text.length);
            slots.putIfAbsent(pos, () => []).add(imageMarker(firstIndex + k));
          }
        }
      }

      if (slots.isEmpty) {
        // 填过占位的话，多出来的图跟在正文末尾；否则跟着光标走
        var pos = filled > 0
            ? text.length
            : (at ?? _contentController.selection.baseOffset);
        if (pos < 0 || pos > text.length) pos = text.length;
        slots[pos] = [
          for (var k = 0; k < rest; k++)
            imageMarker(firstIndex + filled + k)
        ];
      }

      // 从后往前插，前面还没处理的偏移量不受影响
      final positions = slots.keys.toList()..sort((a, b) => b.compareTo(a));
      final lastPos = positions.first;
      var out = text;
      var added = 0;
      for (final pos in positions) {
        final block = slots[pos]!.join('\n');
        final prevCh = pos > 0 ? out[pos - 1] : '\n';
        final nextCh = pos < out.length ? out[pos] : '\n';
        final chunk = '${prevCh == '\n' ? '' : '\n'}$block'
            '${nextCh == '\n' ? '' : '\n'}';
        out = out.substring(0, pos) + chunk + out.substring(pos);
        added += chunk.length;
      }
      text = out;
      // 光标落在最后一张图的标记之后，方便接着往下写
      caret = lastPos + added;
      if (byHtml) filled = count;
    }

    _contentController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: caret.clamp(0, text.length)),
    );
    _lastText = text;
    _pasteStart = null;
    _pasteEnd = null;
    setState(() {});
    return filled > 0;
  }

  /// 删掉一张图，同时删掉它在正文里的位置标记，后面的序号整体往前挪。
  void _removeImage(int index0) {
    if (index0 < 0 || index0 >= _images.length) return;
    setState(() {
      _images.removeAt(index0);
      if (index0 < _imageKeys.length) _imageKeys.removeAt(index0);
      final t = removeImageMarker(_contentController.text, index0 + 1);
      final caret = _contentController.selection.baseOffset;
      _contentController.value = TextEditingValue(
        text: t,
        selection: TextSelection.collapsed(
          offset: (caret < 0 ? t.length : caret).clamp(0, t.length),
        ),
      );
      _lastText = t;
    });
  }

  void _onContentChanged(String v) {
    final prev = _lastText;
    _lastText = v;
    setState(() {});

    // 记下这次新插进来的文字在哪儿：图片位置要按它换算成绝对下标
    final range = _insertedRange(prev, v);
    _pasteStart = range?.$1;
    _pasteEnd = range?.$2;

    // 一次补进 4 个字符以上，基本就是粘贴（输入法一次上屏一般 1~3 个字）。
    // 门槛不能太低，否则正常打字也会反复去探剪贴板。
    if ((v.length - prev.length).abs() < 4) return;
    final inserted = range == null || range.$2 <= range.$1
        ? v
        : v.substring(range.$1, range.$2);
    _pasteDebounce?.cancel();
    _pasteDebounce = Timer(const Duration(milliseconds: 250), () {
      _probeClipboard(auto: true, pastedText: inserted);
    });
  }

  /// 找出新文字插在哪：公共前缀 + 公共后缀夹出来的那一段。
  (int, int)? _insertedRange(String prev, String next) {
    if (next.length <= prev.length) return null;
    var prefix = 0;
    while (prefix < prev.length && prev[prefix] == next[prefix]) {
      prefix++;
    }
    var suffix = 0;
    while (suffix < prev.length - prefix &&
        prev[prev.length - 1 - suffix] == next[next.length - 1 - suffix]) {
      suffix++;
    }
    return (prefix, next.length - suffix);
  }

  Future<void> _addImages() async {
    // 先把剪贴板探一遍，让「粘贴剪贴板图片」入口能显示准确张数
    await _probeClipboard();
    if (!mounted) return;
    // 平板横屏用居中对话框，竖屏用底部弹层
    final wide = MediaQuery.sizeOf(context).width >= Breakpoints.expandedMin;
    final source = wide ? await _askSourceDialog() : await _askSourceSheet();
    if (source == null) return;

    List<XFile> picked = [];
    try {
      if (source == ImageSource.camera) {
        final f = await _picker.pickImage(
          source: ImageSource.camera,
          imageQuality: 80,
          maxWidth: 1600,
        );
        if (f != null) picked = [f];
      } else {
        // 不限张数：多选，允许一次选很多张
        picked = await _picker.pickMultiImage(
          imageQuality: 80,
          maxWidth: 1600,
        );
      }
    } on PlatformException catch (e) {
      _toast('打不开相机或相册：${e.message ?? e.code}');
      return;
    }
    if (picked.isEmpty || !mounted) return;

    setState(() => _busy = true);
    final saved = await _persistImages(picked);
    if (!mounted) return;
    final firstIndex = _images.length + 1;
    setState(() {
      _images.addAll(saved);
      _imageKeys.addAll(List<String>.filled(saved.length, ''));
      _busy = false;
    });
    if (saved.isNotEmpty) {
      // 插在光标所在处：光标在段中间就插在段中间，不是一律堆到末尾
      _insertImageMarkers(firstIndex: firstIndex, count: saved.length);
    }
  }

  /// 把选中的图片复制进 App 私有目录。
  /// 系统相册给的往往是缓存路径，随时可能被清理，必须落地。
  Future<List<String>> _persistImages(List<XFile> files) async {
    final dir = await getApplicationDocumentsDirectory();
    final imgDir = Directory(p.join(dir.path, 'homework_images'));
    if (!imgDir.existsSync()) imgDir.createSync(recursive: true);
    final out = <String>[];
    for (final f in files) {
      try {
        final name =
            '${const Uuid().v4()}${p.extension(f.path).isEmpty ? '.jpg' : p.extension(f.path)}';
        final target = p.join(imgDir.path, name);
        await File(f.path).copy(target);
        out.add(target);
      } catch (_) {
        // 单张失败不影响其余图片
      }
    }
    return out;
  }

  // ---------------- 附件与链接 ----------------

  /// 单个附件上限。和服务端 config.maxImageBytes 保持一致，
  /// 在这里先拦一道，免得几十 MB 传上去才被拒。
  static const int _maxAttachmentBytes = 20 * 1024 * 1024;

  String _mimeForExt(String ext) {
    switch (ext.toLowerCase()) {
      case '.pdf':
        return 'application/pdf';
      case '.docx':
        return 'application/vnd.openxmlformats-officedocument'
            '.wordprocessingml.document';
      default:
        return 'application/octet-stream';
    }
  }

  /// 选 PDF / DOCX 并复制进 App 私有目录。
  ///
  /// 必须复制：系统文件选择器给的是 content:// 临时授权，
  /// 进程重启后那个路径就废了，而作业要等着下一次同步上传。
  Future<void> _addFile() async {
    FilePickerResult? res;
    try {
      res = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['pdf', 'docx'],
        allowMultiple: true,
      );
    } catch (e) {
      _toast('打不开文件选择器：$e');
      return;
    }
    if (res == null || res.files.isEmpty) return;

    setState(() => _busy = true);
    final dir = await getApplicationDocumentsDirectory();
    final fileDir = Directory(p.join(dir.path, 'homework_files'));
    if (!fileDir.existsSync()) fileDir.createSync(recursive: true);

    final added = <Attachment>[];
    var skipped = 0;
    for (final f in res.files) {
      if (f.size > _maxAttachmentBytes) {
        skipped++;
        continue;
      }
      try {
        final ext = p.extension(f.name).toLowerCase();
        final target = p.join(fileDir.path, '${const Uuid().v4()}$ext');
        if (f.path != null) {
          await File(f.path!).copy(target);
        } else if (f.bytes != null) {
          // 少数 ROM 只给字节流，没有可用路径
          await File(target).writeAsBytes(f.bytes!, flush: true);
        } else {
          skipped++;
          continue;
        }
        added.add(Attachment(
          kind: 'file',
          id: const Uuid().v4().replaceAll('-', ''),
          localPath: target,
          name: f.name,
          size: f.size,
          mime: _mimeForExt(ext),
        ));
      } catch (_) {
        skipped++;
      }
    }

    if (!mounted) return;
    setState(() {
      _attachments.addAll(added);
      _busy = false;
    });
    if (skipped > 0) {
      _toast('有 $skipped 个文件没加上：超过 20 MB 或读取失败');
    }
  }

  /// 加一张链接卡片：粘贴 URL → 抓标题/描述/缩略图 → 抓不到就只用 URL。
  Future<void> _addLink() async {
    final ctrl = TextEditingController();
    // 剪贴板里有链接就预填，省一次粘贴
    try {
      final clip = await Clipboard.getData(Clipboard.kTextPlain);
      final guess = extractUrl(clip?.text ?? '');
      if (guess != null) ctrl.text = guess;
    } catch (_) {
      // 读不到剪贴板不影响手动输入
    }
    if (!mounted) return;

    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加链接'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                hintText: 'https://…',
                helperText: '会尝试抓取网页标题和缩略图，抓不到就显示链接本身',
                helperMaxLines: 2,
              ),
              onSubmitted: (v) => Navigator.pop(ctx, v),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    if (url == null || !mounted) return;

    final target = extractUrl(url) ?? url.trim();
    final uri = Uri.tryParse(target);
    if (uri == null ||
        !uri.hasScheme ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      _toast('这不是一个有效的网址');
      return;
    }

    setState(() => _busy = true);
    final preview = await fetchLinkPreview(target);
    if (!mounted) return;
    setState(() {
      _attachments.add(Attachment(
        kind: 'link',
        id: const Uuid().v4().replaceAll('-', ''),
        url: target,
        title: preview?.title ?? '',
        desc: preview?.desc ?? '',
        site: preview?.site ?? '',
        image: preview?.image ?? '',
      ));
      _busy = false;
    });
    if (preview == null || preview.isEmpty) {
      _toast('没抓到网页信息，卡片会显示链接地址');
    }
  }

  void _removeAttachment(int index) {
    if (index < 0 || index >= _attachments.length) return;
    setState(() => _attachments.removeAt(index));
  }

  /// 「2 个附件」这样的摘要。
  String get _attachmentStat {
    if (_attachments.isEmpty) return 'PDF / DOCX / 链接';
    return '${_attachments.length} 个';
  }

  Future<ImageSource?> _askSourceDialog() {    return showDialog<ImageSource>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加图片'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _pasteTile(ctx),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('拍照'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册选择'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
  }

  Future<ImageSource?> _askSourceSheet() {
    return showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _pasteTile(ctx),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('拍照'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册选择'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
  }

  /// 剪贴板里有图时才出现的入口
  Widget _pasteTile(BuildContext ctx) {
    final n = _clip?.imageCount ?? 0;
    if (n <= 0) return const SizedBox.shrink();
    return ListTile(
      leading: const Icon(Icons.content_paste_go_outlined),
      title: Text('粘贴剪贴板里的图片（$n 张）'),
      subtitle: const Text('不用再进相册一张张选', style: TextStyle(fontSize: 12)),
      onTap: () {
        Navigator.pop(ctx);
        _pasteFromClipboard();
      },
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _save() async {
    // 存之前整理一遍：写坏的标记清掉、没位置的图补到末尾，保证「图在就一定有位置」。
    // 家长手抖把 [图2] 删掉半个字符也不会丢图。
    final content = normalizeBody(_contentController.text, _images.length);
    final subject = _useCustomSubject
        ? _customSubjectController.text.trim()
        : _subject;
    if (subject.isEmpty) {
      _toast('先选一个学科');
      return;
    }
    if (plainText(content).isEmpty &&
        _images.isEmpty &&
        _attachments.isEmpty) {
      _toast('写点内容，或者加张图片、附件');
      return;
    }
    if (plainLength(content) > 1000) {
      _toast('正文超过 1000 字了，删掉一点再发');
      return;
    }

    setState(() => _busy = true);
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = widget.existing;

    final hw = existing == null
        ? Homework(
            id: const Uuid().v4(),
            childId: widget.childId,
            // family_id 以前从没写过，云端这一列全是空串。
            // 落库就带上，后续按家庭清理 / 收紧行级权限才有依据。
            familyId: AppStateScope.read(context).family?.id ?? '',
            date: dateKey(_date),
            subject: subject,
            content: content,
            images: _images,
            imageKeys: _imageKeys,
            attachments: _attachments,
            isDone: false,
            createdAt: now,
            updatedAt: now,
            pendingSync: true,
          )
        : existing.copyWith(
            // 老作业的 family_id 是空的，编辑一次顺手补上
            familyId: existing.familyId.isNotEmpty
                ? existing.familyId
                : (AppStateScope.read(context).family?.id ?? ''),
            subject: subject,
            content: content,
            images: _images,
            imageKeys: _imageKeys,
            attachments: _attachments,
            updatedAt: now,
            pendingSync: true,
          );

    await _repo.upsertHomework(hw);
    if (!mounted) return;
    // 本地先落地（离线也能用），云端后台补传
    unawaited(AppStateScope.read(context).syncNow());
    Navigator.of(context).pop(true);
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这条作业？'),
        content: const Text('删除后孩子端也看不到了，这一步不能撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.danger,
              minimumSize: const Size(88, 40),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _repo.softDeleteHomework(widget.existing!.id);
    if (!mounted) return;
    unawaited(AppStateScope.read(context).syncNow());
    Navigator.of(context).pop(true);
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      helpText: '布置日期',
      cancelText: '取消',
      confirmText: '确定',
    );
    if (picked != null) setState(() => _date = picked);
  }

  @override
  Widget build(BuildContext context) {
    final device = deviceTypeOf(MediaQuery.sizeOf(context).width);
    final child = AppStateScope.of(context).activeChild;

    final form = _buildForm(child?.name ?? '');

    return Scaffold(
      appBar: AppBar(
        // 删除按钮从这里挪到底部拇指区：顶部小图标太容易误触，
        // 且 destructive 操作应该和「保存」放在一起让人先看到再决定。
        title: Text(_isEdit ? '编辑作业' : '新建作业'),
      ),
      body: device == DeviceType.expanded
          ? SafeArea(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 480,
                    child: Column(
                      children: [
                        Expanded(child: form),
                        _bottomBar(),
                      ],
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(child: _buildPreview(child?.name ?? '')),
                ],
              ),
            )
          : Column(
              children: [
                Expanded(child: form),
                _bottomBar(),
              ],
            ),
    );
  }

  Widget _bottomBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        AppSpace.sm + 2,
        AppSpace.lg,
        AppSpace.md + 2,
      ),
      decoration: BoxDecoration(
        color: AppColors.card,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          if (_isEdit)
            Padding(
              padding: const EdgeInsets.only(right: AppSpace.md),
              child: SizedBox(
                width: 96,
                child: OutlinedButton(
                  onPressed: _busy ? null : _delete,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(50),
                    foregroundColor: AppColors.dangerInk,
                    side: BorderSide(
                      color: AppColors.danger.withValues(alpha: 0.4),
                    ),
                    padding: EdgeInsets.zero,
                    textStyle: const TextStyle(
                      fontSize: AppText.body,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  child: const Text('删除'),
                ),
              ),
            ),
          Expanded(
            child: PrimaryAction(
              label: _isEdit ? '保存修改' : '发布布置',
              busy: _busy,
              onPressed: _save,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildForm(String childName) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        AppSpace.md,
        AppSpace.lg,
        AppSpace.xl,
      ),
      children: [
        SectionCard(
          index: 1,
          title: '给谁 · 哪天',
          child: Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpace.md,
                    vertical: AppSpace.md,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.surface2,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.child_care,
                          size: 18, color: AppColors.textSecondary),
                      const SizedBox(width: AppSpace.sm),
                      Text(
                        childName.isEmpty ? '未选择' : childName,
                        style: const TextStyle(fontSize: AppText.body),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: AppSpace.sm + 2),
              OutlinedButton.icon(
                onPressed: _pickDate,
                icon: const Icon(Icons.calendar_today_outlined, size: 15),
                label: Text(humanDate(_date)),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 50),
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpace.md,
                  ),
                  foregroundColor: AppColors.textPrimary,
                  side: BorderSide(color: AppColors.border),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpace.md),
        SectionCard(
          index: 2,
          title: '学科',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: AppSpace.sm,
                runSpacing: AppSpace.sm,
                children: [
                  for (final s in _subjectOptions)
                    _subjectChip(
                      label: s,
                      selected: !_useCustomSubject && _subject == s,
                      onTap: () => setState(() {
                        _subject = s;
                        _useCustomSubject = false;
                      }),
                    ),
                  _subjectChip(
                    label: '自定义',
                    selected: _useCustomSubject,
                    onTap: () => setState(() => _useCustomSubject = true),
                  ),
                ],
              ),
              if (_useCustomSubject) ...[
                const SizedBox(height: AppSpace.md),
                TextField(
                  controller: _customSubjectController,
                  maxLength: 8,
                  decoration: const InputDecoration(
                    hintText: '输入学科名，例如：书法',
                    counterText: '',
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: AppSpace.md),
        SectionCard(
          index: 3,
          title: '作业内容',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
          controller: _contentController,
          maxLines: 9,
          minLines: 4,
          maxLength: 1400,
          keyboardType: TextInputType.multiline,
          // 计数只算正经文字，标记不算字数
          buildCounter: (
            context, {
            required currentLength,
            required isFocused,
            maxLength,
          }) {
            final n = plainLength(_contentController.text);
            return Text(
              '$n / 1000',
              style: TextStyle(
                fontSize: 11,
                color: n > 1000 ? AppColors.danger : AppColors.textTertiary,
              ),
            );
          },
          decoration: const InputDecoration(
            hintText: '例如：练习册 P32–P34 全部做完，错题订正\n可直接把微信里的作业消息连图一起粘进来',
          ),
          onChanged: _onContentChanged,
          // 长按菜单里补一个「粘贴图片」：文字粘贴走系统，图片走原生通道
          contextMenuBuilder: (context, editableTextState) {
            final items = editableTextState.contextMenuButtonItems;
            final n = _clip?.imageCount ?? 0;
            if (n <= 0) {
              return AdaptiveTextSelectionToolbar.buttonItems(
                anchors: editableTextState.contextMenuAnchors,
                buttonItems: items,
              );
            }
            return AdaptiveTextSelectionToolbar.buttonItems(
              anchors: editableTextState.contextMenuAnchors,
              buttonItems: [
                ...items,
                ContextMenuButtonItem(
                  label: '粘贴图片（$n 张）',
                  onPressed: () {
                    editableTextState.hideToolbar();
                    _pasteFromClipboard();
                  },
                ),
              ],
            );
          },
        ),
              if (_images.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpace.xs),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.drag_handle,
                          size: 13, color: AppColors.textTertiary),
                      const SizedBox(width: AppSpace.xs),
                      Expanded(
                        child: Text(
                          '图片插在光标处；想换位置就把 [图N] 那几个字剪到别的段落后面。'
                          '图片区点 × 删图会连位置一起删。',
                          style: TextStyle(
                            fontSize: AppText.caption,
                            height: 1.5,
                            color: AppColors.textTertiary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: AppSpace.md),
        SectionCard(
          index: 4,
          title: '图片',
          trailing: Text(
            _imageStat,
            style: TextStyle(
              fontSize: AppText.caption,
              color: AppColors.textTertiary,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ImageGrid(
                images: _refs,
                onRemove: _removeImage,
                trailing: _AddImageTile(
                  busy: _busy || _clipBusy,
                  onTap: _addImages,
                ),
              ),
              if (_images.isNotEmpty) ...[
                const SizedBox(height: AppSpace.sm + 2),
                TextButton.icon(
                  onPressed: () => setState(() {
                    _images.clear();
                    _imageKeys.clear();
                    final t = normalizeBody(_contentController.text, 0);
                    _contentController.text = t;
                    _lastText = t;
                  }),
                  icon: const Icon(Icons.delete_sweep_outlined, size: 16),
                  label: const Text('清空全部图片'),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.textSecondary,
                    textStyle: const TextStyle(fontSize: AppText.label),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: AppSpace.md),
        SectionCard(
          index: 5,
          title: '附件与链接',
          trailing: Text(
            _attachmentStat,
            style: TextStyle(
              fontSize: AppText.caption,
              color: AppColors.textTertiary,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_attachments.isNotEmpty) ...[
                for (var i = 0; i < _attachments.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpace.sm - 2),
                    child: Row(
                      children: [
                        Expanded(
                          child: AttachmentCard(attachment: _attachments[i]),
                        ),
                        IconButton(
                          tooltip: '删除',
                          visualDensity: VisualDensity.compact,
                          onPressed: () => _removeAttachment(i),
                          icon: Icon(
                            Icons.close_rounded,
                            size: 16,
                            color: AppColors.textTertiary,
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: AppSpace.xs),
              ],
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : _addFile,
                      icon: const Icon(Icons.attach_file_rounded, size: 17),
                      label: const Text('添加文件'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 42),
                        foregroundColor: AppColors.textPrimary,
                        side: BorderSide(color: AppColors.border),
                        textStyle: const TextStyle(fontSize: AppText.label),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpace.sm),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : _addLink,
                      icon: const Icon(Icons.link_rounded, size: 17),
                      label: const Text('添加链接'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 42),
                        foregroundColor: AppColors.textPrimary,
                        side: BorderSide(color: AppColors.border),
                        textStyle: const TextStyle(fontSize: AppText.label),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpace.sm),
              Text(
                '支持 PDF、DOCX（单个不超过 20 MB）和网页链接。'
                '附件统一排在图片下方，孩子点开时用系统浏览器打开。',
                style: TextStyle(
                  fontSize: AppText.caption,
                  height: 1.5,
                  color: AppColors.textTertiary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPreview(String childName) {
    final subject = _useCustomSubject
        ? _customSubjectController.text.trim()
        : _subject;
    final content = _contentController.text.trim();
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ReadingWidth(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '孩子会看到这样',
              style: TextStyle(fontSize: 12, color: AppColors.textTertiary),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(AppSpace.lg),
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(AppRadius.md),
                border: Border.all(color: AppColors.border),
                boxShadow: AppShadow.s1,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      SubjectTag(subject: subject.isEmpty ? '未选' : subject),
                      const Spacer(),
                      Text(
                        humanDate(_date),
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textTertiary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  if (content.isEmpty &&
                      _images.isEmpty &&
                      _attachments.isEmpty)
                    Text(
                      '（这里显示作业内容）',
                      style: TextStyle(
                        fontSize: 14,
                        color: AppColors.textTertiary,
                      ),
                    )
                  else ...[
                    // 预览就是孩子端看到的样子：图片按 [图N] 的位置混排
                    RichBody(
                      content: content,
                      images: _refs,
                      layout: RichImageLayout.grid,
                      singleImageWidth: 200,
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.7,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    if (_attachments.isNotEmpty) ...[
                      const SizedBox(height: AppSpace.sm),
                      AttachmentList(attachments: _attachments, dense: true),
                    ],
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _subjectChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final color = AppColors.ofSubject(label);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.12) : AppColors.surface2,
          borderRadius: BorderRadius.circular(AppRadius.full),
          border: Border.all(
            color: selected ? color : AppColors.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: AppText.label,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? color : AppColors.textSecondary,
          ),
        ),
      ),
    );
  }
}

/// 正文输入框的 controller：把 `[图N]` 这类位置标记涂成主色＋浅底。
/// 让家长一眼看到「图片位置在这儿」，也明白这几个字可以整块剪走。
///
/// 微信复制图文消息留下的 `[图片]` 占位涂成橙色：这几个字是**图片原来的位置**，
/// 从相册补图时会自动填进去，所以更要让人看见。
class _MarkerController extends TextEditingController {
  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    // 输入法正在组词时交回默认实现，否则候选词的下划线会丢
    if (withComposing &&
        value.composing.isValid &&
        !value.composing.isCollapsed) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final raw = text;
    if (!kMarkerOrHole.hasMatch(raw)) return TextSpan(style: style, text: raw);

    final spans = <TextSpan>[];
    var cursor = 0;
    for (final m in kMarkerOrHole.allMatches(raw)) {
      if (m.start > cursor) {
        spans.add(TextSpan(text: raw.substring(cursor, m.start)));
      }
      // group(1) 有值 = 合法标记 [图N]，否则是待补图的 [图片]
      spans.add(TextSpan(
        text: m.group(0),
        style: m.group(1) != null ? kMarkerSpanStyle : kHoleSpanStyle,
      ));
      cursor = m.end;
    }
    if (cursor < raw.length) {
      spans.add(TextSpan(text: raw.substring(cursor)));
    }
    return TextSpan(style: style, children: spans);
  }
}

class _AddImageTile extends StatelessWidget {
  const _AddImageTile({required this.busy, required this.onTap});

  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: busy ? null : onTap,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface2,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(color: AppColors.borderStrong),
        ),
        child: Center(
          child: busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.add, size: 22, color: AppColors.textTertiary),
                    SizedBox(height: 2),
                    Text(
                      '添加',
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.textTertiary,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
