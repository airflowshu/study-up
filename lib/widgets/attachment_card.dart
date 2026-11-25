import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/theme.dart';
import '../core/utils.dart';
import '../data/cloud/cloud_api.dart';
import '../data/cloud/cloud_config.dart';
import '../models/models.dart';

/// 附件卡片：文件（PDF / DOCX）与链接两种形态。
///
/// 家长端、孩子端、编辑预览三处共用，所以打开逻辑也放在这里，
/// 避免三个地方各写一遍 launchUrl 再各错一遍。
class AttachmentCard extends StatelessWidget {
  const AttachmentCard({
    super.key,
    required this.attachment,
    this.onTap,
    this.dense = false,
    this.enabled = true,
  });

  final Attachment attachment;

  /// 传了就走调用方的逻辑（比如孩子端要先检查有没有同步过）。
  final VoidCallback? onTap;

  /// 摘要卡里用：整体矮一些，缩略图小一号。
  final bool dense;

  /// 列表摘要里不响应点击——那里整张卡是「进详情」，
  /// 附件再叠一层打开文件，会让用户点哪儿都像点错了。
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final a = attachment;
    return Material(
      color: AppColors.card,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: InkWell(
        onTap: enabled ? (onTap ?? () => openAttachment(context, a)) : null,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: AppSpace.md,
            vertical: dense ? AppSpace.sm : 10,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.sm),
            border: Border.all(color: AppColors.border),
          ),
          child: a.isLink ? _buildLink(context) : _buildFile(context),
        ),
      ),
    );
  }

  /// 文件：左图标 + 中间文件名与大小 + 右侧箭头。
  Widget _buildFile(BuildContext context) {
    final accent = _fileColor();
    return Row(
      children: [
        Container(
          width: dense ? 30 : 36,
          height: dense ? 36 : 42,
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(AppRadius.xs),
          ),
          child: Icon(
            _fileIcon(),
            size: dense ? 17 : 20,
            color: accent,
          ),
        ),
        const SizedBox(width: AppSpace.sm + 2),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                attachment.name.isEmpty ? '未命名文件' : attachment.name,
                maxLines: dense ? 1 : 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: dense ? AppText.label : 14,
                  height: 1.35,
                  fontWeight: FontWeight.w500,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                _fileMeta(),
                style: TextStyle(
                  fontSize: AppText.caption,
                  color: AppColors.textTertiary,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: AppSpace.xs),
        Icon(
          Icons.open_in_new_rounded,
          size: 15,
          color: AppColors.textTertiary,
        ),
      ],
    );
  }

  /// 链接：左标题/描述/站点 + 右侧缩略图。
  Widget _buildLink(BuildContext context) {
    final thumb = dense ? 44.0 : 52.0;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                attachment.title.isEmpty ? attachment.url : attachment.title,
                maxLines: dense ? 1 : 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: dense ? AppText.label : 14,
                  height: 1.35,
                  fontWeight: FontWeight.w500,
                  color: AppColors.textPrimary,
                ),
              ),
              if (attachment.desc.isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(
                  attachment.desc,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppText.caption,
                    height: 1.3,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
              const SizedBox(height: 4),
              Row(
                children: [
                  Icon(Icons.link_rounded,
                      size: 12, color: AppColors.textTertiary),
                  const SizedBox(width: 3),
                  Expanded(
                    child: Text(
                      attachment.site.isEmpty
                          ? _hostOf(attachment.url)
                          : attachment.site,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppText.caption,
                        color: AppColors.textTertiary,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (attachment.image.isNotEmpty) ...[
          const SizedBox(width: AppSpace.sm),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.xs),
            child: Image.network(
              attachment.image,
              width: thumb,
              height: thumb,
              fit: BoxFit.cover,
              // 外站图随时可能挂：加载失败就退回一个中性占位，
              // 不能让一片"破图"留在作业正文里
              errorBuilder: (_, __, ___) => _thumbPlaceholder(thumb),
              loadingBuilder: (ctx, child, progress) =>
                  progress == null ? child : _thumbPlaceholder(thumb),
            ),
          ),
        ],
      ],
    );
  }

  Widget _thumbPlaceholder(double size) => Container(
        width: size,
        height: size,
        color: AppColors.border.withValues(alpha: 0.4),
        alignment: Alignment.center,
        child: Icon(Icons.public_rounded,
            size: size * 0.4, color: AppColors.textTertiary),
      );

  IconData _fileIcon() {
    final n = (attachment.name.isEmpty ? attachment.mime : attachment.name)
        .toLowerCase();
    if (n.contains('pdf')) return Icons.picture_as_pdf_rounded;
    if (n.contains('doc')) return Icons.description_rounded;
    return Icons.insert_drive_file_rounded;
  }

  Color _fileColor() {
    final n = (attachment.name.isEmpty ? attachment.mime : attachment.name)
        .toLowerCase();
    if (n.contains('pdf')) return const Color(0xFFE5484D);
    if (n.contains('doc')) return const Color(0xFF2B579A);
    return AppColors.seed;
  }

  /// 「PDF · 288 KB」。大小未知时只显示类型，不写「0 B」。
  String _fileMeta() {
    final n = (attachment.name.isEmpty ? attachment.mime : attachment.name)
        .toLowerCase();
    final type = n.contains('pdf')
        ? 'PDF'
        : n.contains('doc')
            ? 'DOCX'
            : '文件';
    if (attachment.size <= 0) return type;
    return '$type · ${formatBytes(attachment.size)}';
  }

  String _hostOf(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    return host.isEmpty ? url : host;
  }
}

/// 打开一个附件。
///
/// 统一走系统浏览器（externalApplication）：
/// - PDF 在 Chrome 里能直接预览；
/// - DOCX 会被下载，再由系统提示用 WPS / Word 打开。
/// 不在应用内做下载管理：那要 FileProvider、安装来源授权、逐机型适配，
/// 换来的体验提升很有限，出问题却很难排查。
Future<void> openAttachment(BuildContext context, Attachment a) async {
  if (a.isLink) {
    final uri = Uri.tryParse(a.url);
    if (uri == null) {
      _toast(context, '这个链接不完整');
      return;
    }
    var ok = false;
    try {
      ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      ok = false;
    }
    if (!ok && context.mounted) _toast(context, '打不开，检查一下手机里有没有浏览器');
    return;
  }

  // 文档走「先下到本地，再交给系统应用」。
  //
  // 原来直接把这个地址丢给浏览器：X浏览器这类国产浏览器一律当下载处理，
  // 还要用户再点一次「确定」，下下来的文件名是 att-xxxx（没有扩展名），
  // 孩子那边基本等于打不开。自己在 App 里下完再 open 才可控。
  final needDownload = a.localPath.isEmpty || !File(a.localPath).existsSync();
  if (needDownload && a.key.isNotEmpty) _toast(context, '正在下载…');
  final local = await _localCopyOf(a);
  if (local != null) {
    final r = await OpenFilex.open(local);
    if (r.type == ResultType.done) return;
    if (context.mounted) {
      _toast(context, '手机里没有能打开 ${p.extension(local)} 的应用');
    }
    return;
  }

  // 本地拿不到（没同步过 / 网络失败）就退回浏览器，至少给条活路
  if (a.key.isEmpty) {
    _toast(context, '这个附件还没同步到云端，等联网后再试');
    return;
  }
  var ok = false;
  try {
    ok = await launchUrl(
      Uri.parse(CloudConfig.imageUrl(a.key)),
      mode: LaunchMode.externalApplication,
    );
  } catch (_) {
    ok = false;
  }
  if (!ok && context.mounted) _toast(context, '打不开，检查一下网络或浏览器');
}

/// 拿到附件在本机的副本；拿不到返回 null。
///
/// 家长端自己发的附件本来就在本机（localPath），直接用它；
/// 孩子端只有云端 key，第一次点需要下载，之后命中缓存。
Future<String?> _localCopyOf(Attachment a) async {
  if (a.localPath.isNotEmpty && File(a.localPath).existsSync()) {
    return a.localPath;
  }
  if (a.key.isEmpty) return null;

  try {
    final dir = Directory(p.join((await getTemporaryDirectory()).path, 'att'));
    if (!dir.existsSync()) dir.createSync(recursive: true);

    // 用原始文件名存：系统靠扩展名决定交给哪个应用，
    // 也会把它显示在「最近文件」里，att-xxxx 那种名字孩子看不懂。
    var name = a.name.trim().isEmpty ? p.basename(a.key) : a.name.trim();
    final keyExt = p.extension(a.key);
    if (p.extension(name).isEmpty && keyExt.isNotEmpty) name = '$name$keyExt';
    final target = File(p.join(dir.path, name.replaceAll('/', '_')));

    if (target.existsSync() && (a.size <= 0 || target.lengthSync() == a.size)) {
      return target.path;
    }
    final bytes = await CloudApi.instance.downloadImage(a.key);
    await target.writeAsBytes(bytes, flush: true);
    return target.path;
  } catch (_) {
    return null;
  }
}

void _toast(BuildContext context, String msg) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(msg),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ));
}

/// 附件行：纵向排列，间距统一。
class AttachmentList extends StatelessWidget {
  const AttachmentList({
    super.key,
    required this.attachments,
    this.dense = false,
    this.max,
    this.enabled = true,
  });

  final List<Attachment> attachments;
  final bool dense;

  /// 摘要卡里只露前 N 个，剩下的折成一行「还有 N 个」。
  final int? max;

  /// 见 [AttachmentCard.enabled]。
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (attachments.isEmpty) return const SizedBox.shrink();
    final limit = max ?? attachments.length;
    final shown = attachments.take(limit).toList();
    final rest = attachments.length - shown.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < shown.length; i++) ...[
          if (i > 0) const SizedBox(height: AppSpace.sm - 2),
          AttachmentCard(
            attachment: shown[i],
            dense: dense,
            enabled: enabled,
          ),
        ],
        if (rest > 0) ...[
          const SizedBox(height: AppSpace.sm - 2),
          Text(
            '还有 $rest 个附件',
            style: TextStyle(
              fontSize: AppText.caption,
              color: AppColors.textTertiary,
            ),
          ),
        ],
      ],
    );
  }
}
