// 数据实体。字段命名与需求文档 8.3 的数据模型保持一致，
// 便于后续把本地库替换成云端时一一对应。

import 'dart:convert';

/// 作业附件：一个文件（PDF / DOCX）或者一张链接卡片。
///
/// 为什么一个类装两种形态，而不是拆成两个子类：
/// - 两种形态在库里、云端都是同一段 JSON，拆开后序列化要写两套；
/// - 渲染只有一处分支，模型层的类型严格度换不来什么。
///
/// [key] 是云端对象 key，[localPath] 只有发起上传的那台家长设备才有；
/// 孩子端拿到的永远是 key，点开时按需下载或交给浏览器。
class Attachment {
  const Attachment({
    required this.kind,
    this.id = '',
    this.key = '',
    this.localPath = '',
    this.name = '',
    this.size = 0,
    this.mime = '',
    this.url = '',
    this.title = '',
    this.desc = '',
    this.site = '',
    this.image = '',
  });

  /// 'file' 或 'link'
  final String kind;

  /// 创建时生成的稳定 id，只用来拼云端对象 key。
  ///
  /// 不能用「列表下标」拼 key：家长删掉第 2 个附件后，原来的第 3 个会顶到
  /// 下标 1 上，下一个版本用同一个 key 上传，就会把旧文件内容留在云端。
  final String id;

  /// 云端对象 key，仅 file 用。空串表示还没传上去。
  final String key;

  /// 本地文件绝对路径，仅发起上传的家长设备有。
  final String localPath;

  /// 文件名（含扩展名）
  final String name;

  /// 字节数，用来在卡片上显示「288 KB」
  final int size;

  /// 上传时用的 MIME，决定卡片图标
  final String mime;

  /// 以下五个仅 link 用
  final String url;
  final String title;
  final String desc;
  final String site;
  final String image;

  bool get isFile => kind == 'file';

  bool get isLink => kind == 'link';

  /// 还差一次上传：有本地文件，但云端还没有 key。
  bool get needsUpload => isFile && key.isEmpty && localPath.isNotEmpty;

  /// 云端能看到的全部字段。localPath 是设备私有信息，不上传。
  Map<String, Object?> toMap() => {
        'kind': kind,
        if (id.isNotEmpty) 'id': id,
        if (key.isNotEmpty) 'key': key,
        if (localPath.isNotEmpty) 'localPath': localPath,
        if (name.isNotEmpty) 'name': name,
        if (size > 0) 'size': size,
        if (mime.isNotEmpty) 'mime': mime,
        if (url.isNotEmpty) 'url': url,
        if (title.isNotEmpty) 'title': title,
        if (desc.isNotEmpty) 'desc': desc,
        if (site.isNotEmpty) 'site': site,
        if (image.isNotEmpty) 'image': image,
      };

  /// 去掉 localPath 的版本，用于上云。
  Map<String, Object?> toCloudMap() => toMap()..remove('localPath');

  factory Attachment.fromMap(Map<String, Object?> m) => Attachment(
        kind: (m['kind'] as String?) ?? 'file',
        id: (m['id'] as String?) ?? '',
        key: (m['key'] as String?) ?? '',
        localPath: (m['localPath'] as String?) ?? '',
        name: (m['name'] as String?) ?? '',
        size: (m['size'] as num?)?.toInt() ?? 0,
        mime: (m['mime'] as String?) ?? '',
        url: (m['url'] as String?) ?? '',
        title: (m['title'] as String?) ?? '',
        desc: (m['desc'] as String?) ?? '',
        site: (m['site'] as String?) ?? '',
        image: (m['image'] as String?) ?? '',
      );

  Attachment copyWith({
    String? id,
    String? key,
    String? localPath,
    String? name,
    int? size,
    String? mime,
    String? url,
    String? title,
    String? desc,
    String? site,
    String? image,
  }) =>
      Attachment(
        kind: kind,
        id: id ?? this.id,
        key: key ?? this.key,
        localPath: localPath ?? this.localPath,
        name: name ?? this.name,
        size: size ?? this.size,
        mime: mime ?? this.mime,
        url: url ?? this.url,
        title: title ?? this.title,
        desc: desc ?? this.desc,
        site: site ?? this.site,
        image: image ?? this.image,
      );

  /// 把库里/云端的一列 JSON 解析成列表，任何畸形都退回空列表。
  static List<Attachment> parseList(Object? raw) {
    if (raw == null) return const [];
    List<dynamic>? arr;
    if (raw is List) {
      arr = raw;
    } else if (raw is String && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) arr = decoded;
      } catch (_) {
        return const [];
      }
    }
    if (arr == null) return const [];
    final out = <Attachment>[];
    for (final e in arr) {
      if (e is Map) out.add(Attachment.fromMap(e.cast<String, Object?>()));
    }
    return out;
  }

  static String encodeList(List<Attachment> list) =>
      jsonEncode([for (final a in list) a.toMap()]);
}

class Family {
  final String id;
  final String code; // 6 位家庭码，孩子同名时用于消歧
  final String name;
  final int createdAt;

  const Family({
    required this.id,
    required this.code,
    required this.name,
    required this.createdAt,
  });

  Map<String, Object?> toMap() => {
        'id': id,
        'code': code,
        'name': name,
        'created_at': createdAt,
      };

  factory Family.fromMap(Map<String, Object?> m) => Family(
        id: m['id'] as String,
        code: m['code'] as String,
        name: m['name'] as String,
        createdAt: m['created_at'] as int,
      );
}

class Child {
  final String id;
  final String familyId;
  final String name; // 同家庭内唯一
  final int colorIndex;
  final int createdAt;

  const Child({
    required this.id,
    required this.familyId,
    required this.name,
    required this.colorIndex,
    required this.createdAt,
  });

  Map<String, Object?> toMap() => {
        'id': id,
        'family_id': familyId,
        'name': name,
        'color_index': colorIndex,
        'created_at': createdAt,
      };

  factory Child.fromMap(Map<String, Object?> m) => Child(
        id: m['id'] as String,
        familyId: m['family_id'] as String,
        name: m['name'] as String,
        colorIndex: m['color_index'] as int,
        createdAt: m['created_at'] as int,
      );

  Child copyWith({String? name, int? colorIndex}) => Child(
        id: id,
        familyId: familyId,
        name: name ?? this.name,
        colorIndex: colorIndex ?? this.colorIndex,
        createdAt: createdAt,
      );
}

/// 一段「孩子打开某科作业到退出」的计时记录。
///
/// 之所以按段存而不是只存一个总数：家长端的当日明细要展示「每次进入」的时间段，
/// 而且孩子设备可能中途杀掉进程，按段落库丢的也只是最后这一小段。
///
/// [date] 记的是**作业所属的日期**（作业的 date），不是打开那天的日期——
/// 孩子晚上 11 点补前天的作业，时长应该算在前天那科上。
class HomeworkSession {
  final String id;
  final String childId;

  /// 所属家庭。云端 homework_sessions.family_id 必填（NOT NULL），
  /// 以前没写这个字段，导致云端该列全是空串；现在从作业带下来。
  final String familyId;
  final String homeworkId;
  final String date; // yyyy-MM-dd，跟作业的 date 一致
  final String subject;
  final int startAt; // 毫秒
  final int? endAt; // 毫秒；null 表示这一段还没结束（后台被杀）
  final int seconds; // 有效秒数，已扣掉切后台的时间
  final int createdAt;
  final int updatedAt;
  final bool pendingSync;

  const HomeworkSession({
    required this.id,
    required this.childId,
    this.familyId = '',
    required this.homeworkId,
    required this.date,
    required this.subject,
    required this.startAt,
    this.endAt,
    required this.seconds,
    required this.createdAt,
    required this.updatedAt,
    this.pendingSync = true,
  });

  Map<String, Object?> toMap() => {
        'id': id,
        'child_id': childId,
        'family_id': familyId,
        'homework_id': homeworkId,
        'date': date,
        'subject': subject,
        'start_at': startAt,
        'end_at': endAt,
        'seconds': seconds,
        'created_at': createdAt,
        'updated_at': updatedAt,
        'pending_sync': pendingSync ? 1 : 0,
      };

  factory HomeworkSession.fromMap(Map<String, Object?> m) => HomeworkSession(
        id: m['id'] as String,
        childId: m['child_id'] as String,
        familyId: (m['family_id'] as String?) ?? '',
        homeworkId: m['homework_id'] as String,
        date: m['date'] as String,
        subject: m['subject'] as String,
        startAt: m['start_at'] as int,
        endAt: m['end_at'] as int?,
        seconds: (m['seconds'] as int?) ?? 0,
        createdAt: m['created_at'] as int,
        updatedAt: m['updated_at'] as int,
        pendingSync: (m['pending_sync'] as int?) == 1,
      );
}

/// 一张图在「本地路径 / 云 key」两列里的取值。
///
/// 同一张图有两个可能的来源：
/// - [local]：本机文件绝对路径，只有图片的源头设备（家长这台）才有
/// - [key]：云存储 key，图片传上去之后才有
///
/// 两者至少有一个非空。
class ImageSlot {
  const ImageSlot(this.local, this.key);

  /// 本地绝对路径；本机没有原图时是空串
  final String local;

  /// 云存储 key；还没上传时是空串
  final String key;

  /// 展示用的引用：本地有原图就用路径，否则用 `cloud:key`。
  /// 两个都没有时是空串（占位，保证槽位不丢）。
  String get ref =>
      local.isNotEmpty ? local : (key.isNotEmpty ? 'cloud:$key' : '');
}

/// 把 images 与 imageKeys 两列按槽位对齐。
///
/// 这两列是**平行**的：images[i] 与 imageKeys[i] 说的是同一张图，
/// 一个存本地路径、一个存云 key。列长不一致时以长的为准补空串。
///
/// **槽位一个都不能丢**：正文里的 `[图N]` 是按槽位序号定位的，
/// 少一个槽位，后面所有图片的序号都会整体前移，`[图3]` 就指错图了。
List<ImageSlot> alignImageSlots(List<String> images, List<String> imageKeys) {
  final n = images.length > imageKeys.length ? images.length : imageKeys.length;
  return [
    for (var i = 0; i < n; i++)
      ImageSlot(
        i < images.length ? images[i] : '',
        i < imageKeys.length ? imageKeys[i] : '',
      ),
  ];
}

/// 把云端下发的作业与本机的图片两列合并成槽位序列。
///
/// 规则：**槽位数以云端为准**（家长端是唯一写方，云端就是内容源），
/// 本机第 i 格有原图就继续用本地路径——逐格判断，不比总数。
///
/// 为什么不比总数：只要有一张图上传失败、或某个槽位的 key 为空，条数就对不上，
/// 按总数一刀切会把本机原图**整列清空**。逐格回填则只丢该丢的那一格，
/// 家长这台设备拍的作业照不会因为云端少一个 key 就全没了。
List<ImageSlot> mergeCloudSlots(
  List<String> localImages,
  List<String> cloudKeys,
) {
  return [
    for (var i = 0; i < cloudKeys.length; i++)
      ImageSlot(
        i < localImages.length ? localImages[i] : '',
        cloudKeys[i],
      ),
  ];
}

/// 收掉尾部「既没本地原图、也没云端 key」的空槽。
///
/// 这种槽位留着没意义：编辑页会照着它画一个破图占位。
/// 中间的必须保留——那是一张真实存在过的图（多半是本机还有原图、
/// 云端 key 没传上去），去掉会让后面的 [图N] 整体前移，序号全乱。
List<ImageSlot> dropEmptyTailSlots(List<ImageSlot> slots) {
  var n = slots.length;
  while (n > 0 && slots[n - 1].local.isEmpty && slots[n - 1].key.isEmpty) {
    n--;
  }
  return slots.take(n).toList();
}

class Homework {
  final String id;
  final String childId;

  /// 所属家庭。云端 homework.family_id 是 NOT NULL 列，早期版本从没写入过，
  /// 库里攒了一堆空串；现在落库就带上，便于按家庭清理与收紧行级权限。
  final String familyId;
  final String date; // yyyy-MM-dd
  final String subject;
  final String content;
  final List<String> images; // 本地文件路径，只有家长端（图片源头）有
  final List<String> imageKeys; // 云存储 key，与 images 按下标一一对应

  /// 附件与链接卡片，渲染顺序即列表顺序，统一排在图片之后。
  /// 空列表 = 这条作业没有附件（所有老数据都是这种）。
  final List<Attachment> attachments;
  final bool isDone;
  final int? doneAt;
  final int createdAt;
  final int updatedAt;
  final bool pendingSync; // 家长端离线写入、尚未上传
  final bool isDeleted;

  const Homework({
    required this.id,
    required this.childId,
    this.familyId = '',
    required this.date,
    required this.subject,
    required this.content,
    required this.images,
    this.imageKeys = const [],
    this.attachments = const [],
    required this.isDone,
    this.doneAt,
    required this.createdAt,
    required this.updatedAt,
    this.pendingSync = false,
    this.isDeleted = false,
  });

  /// 界面统一用这个取图。
  /// 本机有原图就用本地路径（家长端）；否则回落到云引用，前缀 `cloud:` 区分。
  ///
  /// 长度等于图片槽位数，与正文里的 `[图N]` 一一对应。
  List<String> get imageRefs =>
      [for (final s in alignImageSlots(images, imageKeys)) s.ref];

  Map<String, Object?> toMap() => {
        'id': id,
        'child_id': childId,
        'family_id': familyId,
        'date': date,
        'subject': subject,
        'content': content,
        'images': images.join('\u0001'),
        'image_keys': imageKeys.join('\u0001'),
        'attachments': Attachment.encodeList(attachments),
        'is_done': isDone ? 1 : 0,
        'done_at': doneAt,
        'created_at': createdAt,
        'updated_at': updatedAt,
        'pending_sync': pendingSync ? 1 : 0,
        'is_deleted': isDeleted ? 1 : 0,
      };

  static List<String> _split(Object? raw) {
    final s = (raw as String?) ?? '';
    return s.isEmpty ? const [] : s.split('\u0001');
  }

  factory Homework.fromMap(Map<String, Object?> m) => Homework(
        id: m['id'] as String,
        childId: m['child_id'] as String,
        familyId: (m['family_id'] as String?) ?? '',
        date: m['date'] as String,
        subject: m['subject'] as String,
        content: m['content'] as String,
        images: _split(m['images']),
        imageKeys: _split(m['image_keys']),
        attachments: Attachment.parseList(m['attachments']),
        isDone: (m['is_done'] as int) == 1,
        doneAt: m['done_at'] as int?,
        createdAt: m['created_at'] as int,
        updatedAt: m['updated_at'] as int,
        pendingSync: (m['pending_sync'] as int) == 1,
        isDeleted: (m['is_deleted'] as int) == 1,
      );

  Homework copyWith({
    String? familyId,
    String? subject,
    String? content,
    List<String>? images,
    List<String>? imageKeys,
    List<Attachment>? attachments,
    bool? isDone,
    int? doneAt,
    bool clearDoneAt = false,
    int? updatedAt,
    bool? pendingSync,
    bool? isDeleted,
  }) =>
      Homework(
        id: id,
        childId: childId,
        familyId: familyId ?? this.familyId,
        date: date,
        subject: subject ?? this.subject,
        content: content ?? this.content,
        images: images ?? this.images,
        imageKeys: imageKeys ?? this.imageKeys,
        attachments: attachments ?? this.attachments,
        isDone: isDone ?? this.isDone,
        doneAt: clearDoneAt ? null : (doneAt ?? this.doneAt),
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        pendingSync: pendingSync ?? this.pendingSync,
        isDeleted: isDeleted ?? this.isDeleted,
      );
}
