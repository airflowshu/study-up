import 'package:flutter_test/flutter_test.dart';
import 'package:homework_app/state/study_timer.dart';

/// 计时引擎的回归测试。
///
/// 计时结果会直接变成家长看到的「孩子这科学了多久」，算错就是给家长
/// 报错误数据，比少记录一条严重得多。所以把最容易出错的几个点钉死：
/// 粒度取整、暂停扣除、上限截断、不足粒度不记录。
void main() {
  const now = 1793348354913; // 固定时刻，避免测试依赖真实时钟

  group('有效秒数 effectiveSeconds', () {
    test('不足一个粒度就不记（10 秒以下不留脏数据）', () {
      expect(
        StudyTimer.effectiveSeconds(
          accumMs: 9000,
          resumedAt: null,
          nowMs: now,
        ),
        0,
      );
      expect(
        StudyTimer.effectiveSeconds(
          accumMs: 0,
          resumedAt: now - 9999,
          nowMs: now,
        ),
        0,
      );
    });

    test('向下取整到 10 秒', () {
      // 118 秒 -> 11 个 10 秒 = 110 秒
      expect(
        StudyTimer.effectiveSeconds(
          accumMs: 118000,
          resumedAt: null,
          nowMs: now,
        ),
        110,
      );
      // 恰好整 10 秒不丢
      expect(
        StudyTimer.effectiveSeconds(
          accumMs: 120000,
          resumedAt: null,
          nowMs: now,
        ),
        120,
      );
    });

    test('正在跑的一段和已累计的相加', () {
      expect(
        StudyTimer.effectiveSeconds(
          accumMs: 60000,
          resumedAt: now - 30000,
          nowMs: now,
        ),
        90,
      );
    });

    test('暂停后 resumedAt 为空，只算已累计的部分', () {
      // 暂停期间（切后台 5 分钟）不计入
      expect(
        StudyTimer.effectiveSeconds(
          accumMs: 60000,
          resumedAt: null,
          nowMs: now + 5 * 60 * 1000,
        ),
        60,
      );
    });

    test('单段超 120 分钟被截断', () {
      // 停了一整天也只能算 120 分钟
      expect(
        StudyTimer.effectiveSeconds(
          accumMs: 0,
          resumedAt: now - 8 * 60 * 60 * 1000,
          nowMs: now,
        ),
        120 * 60,
      );
    });

    test('上限与粒度同时生效时取小的那个', () {
      expect(
        StudyTimer.effectiveSeconds(
          accumMs: 10 * 60 * 60 * 1000,
          resumedAt: null,
          nowMs: now,
          capSeconds: 300,
          granularity: 10,
        ),
        300,
      );
    });

    test('负数与零都不产生记录', () {
      expect(
        StudyTimer.effectiveSeconds(
          accumMs: 0,
          resumedAt: null,
          nowMs: now,
        ),
        0,
      );
      expect(
        StudyTimer.effectiveSeconds(
          accumMs: -5000,
          resumedAt: null,
          nowMs: now,
        ),
        0,
      );
    });
  });

  group('常量口径', () {
    test('粒度 10 秒，上限 120 分钟', () {
      expect(StudyTimer.granularity, 10);
      expect(StudyTimer.maxSeconds, 7200);
    });
  });
}
