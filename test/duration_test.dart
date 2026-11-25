import 'package:flutter_test/flutter_test.dart';
import 'package:homework_app/core/utils.dart';

/// 时长展示口径的回归测试。
///
/// 这些规则是产品需求里明确写死的（需求说明书第 19 章），
/// 改格式函数时必须一起改这里，否则家长端会出现「0 分」这类误导性文案。
void main() {
  group('紧凑格式 formatDuration', () {
    test('不足 1 分钟说「不到 1 分」，不说 0 分', () {
      expect(formatDuration(0), '不到 1 分');
      expect(formatDuration(10), '不到 1 分');
      expect(formatDuration(59), '不到 1 分');
    });

    test('1 分钟到 1 小时', () {
      expect(formatDuration(60), '1 分');
      expect(formatDuration(18 * 60), '18 分');
      expect(formatDuration(59 * 60 + 59), '59 分');
    });

    test('整小时不带「0 分」', () {
      expect(formatDuration(3600), '1 小时');
      expect(formatDuration(2 * 3600), '2 小时');
    });

    test('小时 + 分钟', () {
      expect(formatDuration(3600 + 12 * 60), '1 小时 12 分');
      expect(formatDuration(12 * 3600 + 40 * 60), '12 小时 40 分');
    });
  });

  group('明细格式 formatDurationLong', () {
    test('带秒，秒补零', () {
      expect(formatDurationLong(18 * 60 + 32), '18 分 32 秒');
      expect(formatDurationLong(12 * 60 + 5), '12 分 05 秒');
      expect(formatDurationLong(3600 + 12 * 60 + 5), '1 小时 12 分 05 秒');
    });

    test('不足 1 分钟同样说「不到 1 分」', () {
      expect(formatDurationLong(45), '不到 1 分');
    });
  });

  group('钟点格式 formatClock', () {
    test('不到一小时只到分', () {
      expect(formatClock(13 * 60 + 40), '13:40');
      expect(formatClock(4 * 60 + 52), '04:52');
    });

    test('超过一小时带小时', () {
      expect(formatClock(3600 + 12 * 60 + 5), '1:12:05');
    });
  });

  group('时刻 formatTimeOfDay', () {
    test('毫秒转 HH:mm', () {
      final ms = DateTime(2026, 10, 30, 19, 4).millisecondsSinceEpoch;
      expect(formatTimeOfDay(ms), '19:04');
    });
  });

  group('日期键', () {
    test('dateKey / parseDateKey 互逆', () {
      final d = DateTime(2026, 10, 30);
      expect(dateKey(d), '2026-10-30');
      expect(parseDateKey('2026-10-30'), d);
    });

    test('月末用次月第 0 天算，不用判断大小月', () {
      expect(dateKey(DateTime(2026, 2 + 1, 0)), '2026-02-28');
      expect(dateKey(DateTime(2024, 2 + 1, 0)), '2024-02-29');
      expect(dateKey(DateTime(2026, 12 + 1, 0)), '2026-12-31');
    });
  });
}
