import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homework_app/data/repository.dart';
import 'package:homework_app/features/parent/homework_edit_page.dart';
import 'package:homework_app/models/models.dart';
import 'package:homework_app/state/app_state.dart';
import 'package:homework_app/widgets/image_grid.dart';

/// 1×1 的 PNG，测试里当「家长拍的一张作业照」。
final Uint8List _png = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, //
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, //
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, //
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, //
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, //
  0x42, 0x60, 0x82, //
]);

late Directory _tmp;

/// 落一张真图，返回路径。
String _image(String name) {
  final f = File('${_tmp.path}/$name.png');
  f.writeAsBytesSync(_png);
  return f.path;
}

Homework _hw({
  required List<String> images,
  required List<String> keys,
  required String content,
}) =>
    Homework(
      id: 'hw-test-1',
      childId: 'child-1',
      date: '2026-10-30',
      subject: '语文',
      content: content,
      images: images,
      imageKeys: keys,
      isDone: false,
      createdAt: 1,
      updatedAt: 1,
    );

/// 把编辑页挂起来。模拟家长端首页点「编辑」进来的那条路径。
Future<void> _pumpEdit(WidgetTester tester, Homework hw) async {
  await tester.pumpWidget(
    AppStateScope(
      state: AppState(Repository.instance),
      child: MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(size: Size(420, 900)),
          child: HomeworkEditPage(
            childId: hw.childId,
            date: DateTime(2026, 10, 30),
            existing: hw,
          ),
        ),
      ),
    ),
  );
  // 只泵两帧：不 pumpAndSettle，免得等云端图片下载
  await tester.pump();
  await tester.pump();
}

/// 编辑页图片区当前持有的图片引用（槽位对齐后的结果）。
List<String> _gridRefs() {
  final grid = find.byType(ImageGrid).evaluate().first.widget as ImageGrid;
  return grid.images;
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    _tmp = Directory.systemTemp.createTempSync('hw_edit_test');
    // 云端图片缓存要用临时目录，测试环境没有真插件，给它一个
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => _tmp.path,
    );
  });

  testWidgets('本机有原图：进编辑页图片要回显', (tester) async {
    final p1 = _image('a');
    await _pumpEdit(
      tester,
      _hw(
        images: [p1],
        keys: const [],
        content: '练习册 P32\n[图1]\n',
      ),
    );

    expect(_gridRefs(), [p1]);
    expect(find.byType(Image), findsOneWidget, reason: '本地原图应渲染成图片');
    expect(find.textContaining('共 1 张'), findsOneWidget);
  });

  testWidgets('本机有原图 + 云端也有 key：两张都在', (tester) async {
    final p1 = _image('b');
    final p2 = _image('c');
    await _pumpEdit(
      tester,
      _hw(
        images: [p1, p2],
        keys: const ['k1', 'k2'],
        content: '第一段\n[图1]\n第二段\n[图2]\n',
      ),
    );

    expect(_gridRefs(), [p1, p2]);
    expect(find.byType(Image), findsNWidgets(2));
    expect(find.textContaining('共 2 张'), findsOneWidget);
  });

  testWidgets('两列不等长（本机只有第一张原图）：槽位不丢，第二张走云端',
      (tester) async {
    final p1 = _image('d');
    await _pumpEdit(
      tester,
      _hw(
        images: [p1],
        keys: const ['k1', 'k2'],
        content: 'A\n[图1]\nB\n[图2]\n',
      ),
    );

    expect(_gridRefs(), [p1, 'cloud:k2'], reason: '少一个槽位 [图N] 就会指错图');
    expect(find.byType(Image), findsOneWidget);
    expect(find.byType(CachedCloudImage), findsOneWidget);
  });

  testWidgets('本机完全没有原图（换设备/重装）：图片仍按云端 key 回显',
      (tester) async {
    await _pumpEdit(
      tester,
      _hw(
        images: const [],
        keys: const ['k1', 'k2'],
        content: 'A\n[图1]\nB\n[图2]\n',
      ),
    );

    expect(_gridRefs(), ['cloud:k1', 'cloud:k2']);
    expect(find.byType(CachedCloudImage), findsNWidgets(2));
  });

  testWidgets('正文回显不出错：老作业没有标记时自动补在末尾', (tester) async {
    final p1 = _image('e');
    await _pumpEdit(
      tester,
      _hw(images: [p1], keys: const ['k1'], content: '老作业，没有位置标记'),
    );

    // 内容照常回显，末尾补出 [图1]
    final editable =
        tester.widget<EditableText>(find.byType(EditableText).first);
    expect(editable.controller.text, '老作业，没有位置标记\n[图1]');
    expect(_gridRefs(), [p1]);
  });
}
