import 'dart:convert';
import 'dart:io';

const _weekdays = ['一', '二', '三', '四', '五', '六', '日'];

/// 统一用 yyyy-MM-dd 作为作业的日期键，保证字符串排序即时间排序。
String dateKey(DateTime d) {
  final m = d.month.toString().padLeft(2, '0');
  final day = d.day.toString().padLeft(2, '0');
  return '${d.year}-$m-$day';
}

String todayKey() => dateKey(DateTime.now());

DateTime parseDateKey(String key) {
  final parts = key.split('-');
  return DateTime(
    int.parse(parts[0]),
    int.parse(parts[1]),
    int.parse(parts[2]),
  );
}

/// 例：10月30日 周五
String humanDate(DateTime d) {
  final w = _weekdays[d.weekday - 1];
  return '${d.month}月${d.day}日 周$w';
}

String humanDateFromKey(String key) => humanDate(parseDateKey(key));

/// 例：2026年10月
String monthLabel(DateTime d) => '${d.year} 年 ${d.month} 月';

/// 相对日期描述，用于历史列表分组标题。
String relativeDate(String key) {
  final d = parseDateKey(key);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final diff = today.difference(DateTime(d.year, d.month, d.day)).inDays;
  if (diff == 0) return '今天';
  if (diff == 1) return '昨天';
  if (diff == 2) return '前天';
  if (diff == -1) return '明天';
  return humanDate(d);
}

// ---------------- 时长格式 ----------------
//
// 展示口径（家长端）：按 10 秒粒度累加、向下取整到分钟。
// 所以 50 秒会显示「不到 1 分」——这正是想要的说法，
// 比「0 分」诚实，也不会被读成「这科没学」。

/// 紧凑格式，用于列表和汇总：`18 分` / `1 小时 12 分` / `不到 1 分`
String formatDuration(int seconds) {
  if (seconds <= 0) return '不到 1 分';
  if (seconds < 60) return '不到 1 分';
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  if (h == 0) return '$m 分';
  if (m == 0) return '$h 小时';
  return '$h 小时 $m 分';
}

/// 当日明细才用到的精确格式：`18 分 32 秒` / `1 小时 12 分 05 秒`
String formatDurationLong(int seconds) {
  if (seconds <= 0) return '不到 1 分';
  if (seconds < 60) return '不到 1 分';
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  final ss = s.toString().padLeft(2, '0');
  if (h == 0) return '$m 分 $ss 秒';
  return '$h 小时 $m 分 $ss 秒';
}

/// 表格里的钟点格式：`13:40` / `1:12:05`
String formatClock(int seconds) {
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  return h == 0 ? '$mm:$ss' : '$h:$mm:$ss';
}

/// 时刻（毫秒）→ `10:12`
String formatTimeOfDay(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}';
}

/// 向下取整到分钟，用于「日均」这类派生指标。
int wholeMinutes(int seconds) => seconds ~/ 60;

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}

/// 图片以 JSON 数组字符串存库，避免额外建表。
String encodeImages(List<String> images) => jsonEncode(images);

List<String> decodeImages(String raw) {
  if (raw.isEmpty) return const [];
  try {
    final list = jsonDecode(raw) as List<dynamic>;
    return list.map((e) => e.toString()).toList();
  } catch (_) {
    return const [];
  }
}

int fileSizeOf(String path) {
  try {
    final f = File(path);
    return f.existsSync() ? f.lengthSync() : 0;
  } catch (_) {
    return 0;
  }
}
