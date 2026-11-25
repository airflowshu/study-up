import 'package:flutter_test/flutter_test.dart';
import 'package:homework_app/core/rich_body.dart';

void main() {
  group('parseBody', () {
    test('标记把正文切成「文字 / 图片组 / 文字」', () {
      final blocks = parseBody('AAAA\n[图1]\n[图2]\n3', 2);
      expect(blocks.length, 3);
      expect(blocks[0].text, 'AAAA');
      expect(blocks[1].images, [1, 2]);
      expect(blocks[2].text, '3');
    });

    test('老数据没有标记时，图片排在正文后面', () {
      final blocks = parseBody('练习册 P32', 2);
      expect(blocks.length, 2);
      expect(blocks[0].text, '练习册 P32');
      expect(blocks[1].images, [1, 2]);
    });

    test('纯图作业只有图片块', () {
      final blocks = parseBody('[图1]', 1);
      expect(blocks.length, 1);
      expect(blocks[0].images, [1]);
    });

    test('序号越界的标记当普通文字留着，图补在末尾', () {
      final blocks = parseBody('前[图9]后', 2);
      expect(blocks.length, 2);
      expect(blocks[0].text, '前[图9]后');
      expect(blocks[1].images, [1, 2]);
    });

    test('正文里的「[图片]」不会被当成标记吃掉', () {
      const text = '2.口头作业，请见图片\n3.预习【湖水 名胜】[图片][图片]';
      final blocks = parseBody(text, 2);
      expect(blocks.length, 2);
      expect(blocks[0].text, contains('[图片][图片]'));
      expect(blocks[1].images, [1, 2]);
    });

    test('重复引用同一张图只保留第一次', () {
      final blocks = parseBody('[图1]\n中\n[图1]', 1);
      final images = blocks.where((b) => b.isImage).expand((b) => b.images);
      expect(images.toList(), [1]);
    });

    test('同一行里的连续图片合成一组（才能折叠成「展开 N」）', () {
      final blocks = parseBody('前[图1][图2][图3]后', 3);
      expect(blocks.length, 3);
      expect(blocks[1].images, [1, 2, 3]);
    });
  });

  group('normalizeBody', () {
    test('缺的标记补在末尾，图不会丢', () {
      expect(normalizeBody('正文', 2), '正文\n[图1][图2]');
    });

    test('半个标记不当作标记，图补到末尾', () {
      expect(normalizeBody('正文[图', 1), '正文[图\n[图1]');
    });

    test('重复标记只留一个', () {
      expect(normalizeBody('[图1]\n正文\n[图1]', 1), '[图1]\n正文');
    });

    test('正文为空时只剩标记', () {
      expect(normalizeBody('', 1), '[图1]');
    });
  });

  group('removeImageMarker', () {
    test('删掉第 1 张，后面的序号整体前移', () {
      expect(removeImageMarker('A[图1]B[图2]C', 1), 'AB[图1]C');
    });

    test('删掉最后一张只去掉标记', () {
      expect(removeImageMarker('A[图1]B[图2]', 2), 'A[图1]B');
    });
  });

  group('plainText / plainLength', () {
    test('摘要里不出现标记，也不留空行', () {
      expect(plainText('AAAA\n[图1]\n[图2]\n3'), 'AAAA\n3');
    });

    test('字数不算标记', () {
      expect(plainLength('AAAA[图1]'), 4);
    });
  });

  group('HTML 里的图片位置', () {
    const html = '<p>第一段：练习册 P32-34 全部做完。</p>'
        '<img src="https://x/1.jpg">'
        '<p>第二段：错题本订正到第 12 页。</p>'
        '<img src="https://x/2.jpg">';

    test('能算出每张图夹在哪段文字之后', () {
      final body = parseHtmlBody(html);
      expect(body.imageOffsets.length, 2);

      const pasted = '第一段：练习册 P32-34 全部做完。\n第二段：错题本订正到第 12 页。';
      final rel = mapHtmlImageOffsets(body, pasted);
      expect(rel.length, 2);
      // 第 1 张图在第一段之后：从该位置往后的正文应当是第二段
      expect(pasted.substring(rel[0]).trimLeft().startsWith('第二段'), isTrue);
      // 第 2 张图在最后
      expect(rel[1], pasted.length);
    });

    test('HTML 文字和粘贴文字对不上时返回空，交由调用方兜底', () {
      final body = parseHtmlBody(html);
      expect(mapHtmlImageOffsets(body, '完全不一样的内容'), isEmpty);
    });
  });

  group('粘贴范围', () {
    test('能定位新插入的一段文字', () {
      const prev = 'AAAA\nBBBB';
      const next = 'AAAA\n新粘进来的几句\nBBBB';
      // 等价于编辑页里的 _insertedRange
      var prefix = 0;
      while (prefix < prev.length && prev[prefix] == next[prefix]) {
        prefix++;
      }
      var suffix = 0;
      while (suffix < prev.length - prefix &&
          prev[prev.length - 1 - suffix] == next[next.length - 1 - suffix]) {
        suffix++;
      }
      expect(next.substring(prefix, next.length - suffix), '新粘进来的几句\n');
    });
  });

  // 微信复制图文消息时，图片不进剪贴板，只在文字里留一个 [图片]。
  // 从相册补图要落回这些位置，这一组盯的就是「补位不乱、序号不乱」。
  group('fillImageHoles', () {
    test('找出所有占位的位置', () {
      const s = '甲[图片]乙[图片]丙';
      expect(imageHoles(s), [1, 6]);
    });

    test('单个占位在行中间：图单独占一行，前后文字都保留', () {
      final r = fillImageHoles('观看入口见海报[图片]@全体成员', 1, 1);
      expect(r.filled, 1);
      expect(r.text, '观看入口见海报\n[图1]\n@全体成员');
    });

    test('多个占位按顺序补，序号跟着占位走', () {
      final r = fillImageHoles('第一段[图片]第二段[图片]第三段', 1, 2);
      expect(r.filled, 2);
      expect(r.text, '第一段\n[图1]\n第二段\n[图2]\n第三段');
      // 相邻两个占位各占一行，中间的换行不会凭空多出来
      final r2 = fillImageHoles('甲[图片]乙[图片]丙', 3, 2);
      expect(r2.text, '甲\n[图3]\n乙\n[图4]\n丙');
    });

    test('占位比图多：只填空出来的，其余占位原样留着', () {
      final r = fillImageHoles('A[图片]B[图片]C', 3, 1);
      expect(r.filled, 1);
      expect(r.text, 'A\n[图3]\nB[图片]C');
    });

    test('占位在行首和行尾时不额外加空行', () {
      expect(fillImageHoles('[图片]ABC', 1, 1).text, '[图1]\nABC');
      expect(fillImageHoles('ABC[图片]', 1, 1).text, 'ABC\n[图1]');
    });

    test('已有 [图N] 标记和占位共存，只动占位，序号接着编', () {
      final r = fillImageHoles('A[图1]B[图片]C', 2, 1);
      expect(r.text, 'A[图1]B\n[图2]\nC');
    });

    test('没有占位就原样返回，交给调用方按光标插', () {
      final r = fillImageHoles('abc', 1, 2);
      expect(r.filled, 0);
      expect(r.text, 'abc');
    });
  });

  group('高亮匹配', () {
    test('合法标记靠分组区分，[图片] 不分组', () {
      final marks = kMarkerOrHole.allMatches('A[图1]B[图片]C[图12]').toList();
      expect(marks.length, 3);
      expect(marks[0].group(1), '1');
      expect(marks[1].group(1), isNull);
      expect(marks[2].group(1), '12');
    });
  });
}
