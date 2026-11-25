import 'package:flutter_test/flutter_test.dart';
import 'package:homework_app/models/models.dart';

/// 合并后「展示用引用」：本地有原图用路径，否则走云端 key。
List<String> _refs(List<ImageSlot> slots) =>
    [for (final s in slots) s.ref];

void main() {
  group('mergeCloudSlots：云端作业与本机原图合并', () {
    test('两边条数一致：本机原图全部沿用', () {
      final slots = mergeCloudSlots(['/p1', '/p2'], ['k1', 'k2']);
      expect(_refs(slots), ['/p1', '/p2']);
    });

    test('本机少一张：缺的那格走云端，前面的不受牵连', () {
      // 老逻辑比总数（1 != 2）会把 /p1 也一起清掉
      final slots = mergeCloudSlots(['/p1'], ['k1', 'k2']);
      expect(_refs(slots), ['/p1', 'cloud:k2']);
    });

    test('本机多一张：多出来的槽位丢掉（家长在别处删过图）', () {
      final slots = mergeCloudSlots(['/p1', '/p2', '/p3'], ['k1', 'k2']);
      expect(_refs(slots), ['/p1', '/p2']);
    });

    test('云端中间有个空 key：后面的图不许前移', () {
      // [图1][图2][图3] 里的第 3 张必须还是第 3 张
      final slots = mergeCloudSlots(['/p1', '/p2', '/p3'], ['k1', '', 'k3']);
      expect(_refs(slots), ['/p1', '/p2', '/p3']);
      expect(slots.map((s) => s.key).toList(), ['k1', '', 'k3']);
    });

    test('本机一格原图都没有（换设备）：整条走云端', () {
      final slots = mergeCloudSlots(const [], ['k1', 'k2']);
      expect(_refs(slots), ['cloud:k1', 'cloud:k2']);
    });

    test('本机某格是空串（图本来就在云端）：该格回落云端', () {
      final slots = mergeCloudSlots(['', '/p2'], ['k1', 'k2']);
      expect(_refs(slots), ['cloud:k1', '/p2']);
    });

    test('云端一条图都没有（图被删光）：不再留本地原图', () {
      final slots = mergeCloudSlots(['/p1', '/p2'], const []);
      expect(slots, isEmpty);
    });
  });

  group('dropEmptyTailSlots：只收尾部彻底空的槽位', () {
    test('尾部「图、key 都没有」的槽位收掉', () {
      final kept = dropEmptyTailSlots(const [
        ImageSlot('/p1', 'k1'),
        ImageSlot('', ''),
      ]);
      expect(_refs(kept), ['/p1']);
    });

    test('尾部那格本机还有原图：不许收', () {
      // 云端第二格丢了 key，本机原图还在，收掉就把家长拍的照弄没了
      final kept = dropEmptyTailSlots(const [
        ImageSlot('', 'k1'),
        ImageSlot('/p2', ''),
      ]);
      expect(_refs(kept), ['cloud:k1', '/p2']);
    });

    test('中间的空槽保留：不能让后面的图前移', () {
      final kept = dropEmptyTailSlots(const [
        ImageSlot('/p1', 'k1'),
        ImageSlot('', ''),
        ImageSlot('/p3', 'k3'),
      ]);
      expect(_refs(kept), ['/p1', '', '/p3']);
    });
  });
}
