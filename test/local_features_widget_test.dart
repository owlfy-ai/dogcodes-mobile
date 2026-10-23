import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/app.dart';
import 'package:dogcodes_app/core/host_hub.dart';
import 'package:dogcodes_app/core/security/secret_storage.dart';
import 'package:dogcodes_app/data/local_workspace.dart';
import 'package:dogcodes_app/features/settings/preferences_page.dart';
import 'attachment_fixture.dart';
import 'composer_state_test.dart' show composerHub;
import 'turn_actions_widget_test.dart' show tapVisible;

class AttachmentSelector extends FileSelectorPlatform {
  @override
  Future<List<XFile>> openFiles({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async => [
    XFile.fromData(
      Uint8List.fromList(utf8.encode('attachment text')),
      path: 'task.txt',
    ),
  ];
}

Future<HostHub> setup(WidgetTester tester, AttachmentLink link) async {
  await tester.binding.setSurfaceSize(const Size(390, 850));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final hub = composerHub(LocalWorkspace.memory(), MemorySecretStorage());
  await hub.load(connect: false);

  await hub.attach(hub.hosts.single, link);

  await tester.pumpWidget(DogCodesApp(hub: hub));
  await tester.pumpAndSettle();
  return hub;
}

void main() {
  testWidgets(
    'fresh PC timeline replaces a cached timeline even if its sequence is lower',
    (tester) async {
      final link = AttachmentLink();
      final hub = await setup(tester, link);
      await hub.local.cacheTimeline(
        hub.hosts.single.id,
        't2',
        {
          'items': [
            {'itemId': 'old', 'kind': 'assistant_message', 'text': '过期缓存'},
          ],
          'lastSequence': 99999,
        },
        DateTime.now(),
        hub.local.cacheEpoch,
      );
      await tester.tap(find.text('修复移动端布局'));
      await tester.pumpAndSettle();
      expect(find.text('过期缓存', findRichText: true), findsNothing);
      expect(
        find.text('我会先检查登录逻辑，再处理错误状态。', findRichText: true),
        findsOneWidget,
      );
      expect(link.sends, isEmpty);
      await tester.pumpWidget(const SizedBox());
      hub.dispose();
    },
  );
  testWidgets(
    'select phone file, restore it after closing the page, and send its verified PC reference',
    (tester) async {
      final previous = FileSelectorPlatform.instance;
      FileSelectorPlatform.instance = AttachmentSelector();
      addTearDown(() => FileSelectorPlatform.instance = previous);
      final link = AttachmentLink();
      final hub = await setup(tester, link);
      await tester.tap(find.text('修复移动端布局'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).last, '检查附件');
      await tapVisible(tester, find.text('添加附件'));

      await tapVisible(tester, find.text('手机文件'));

      expect(find.text('task.txt'), findsOneWidget);
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('修复移动端布局'));
      await tester.pumpAndSettle();
      expect(find.text('检查附件'), findsOneWidget);
      expect(find.text('task.txt'), findsOneWidget);

      await tester.tap(find.byTooltip('发送'));

      await tester.pumpAndSettle();
      expect(link.sends.length, 1);
      expect(
        link.sends.single['input']['attachments'].single['name'],
        'task.txt',
      );
      expect(
        link.sends.single['input']['attachments'].single['integrity']['sha256'],
        isNotEmpty,
      );
      expect(find.text('task.txt'), findsNothing);
      expect(find.text('检查附件'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      hub.dispose();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'offline cached conversation opens without RPC; edits stay drafts',
    (tester) async {
      final link = AttachmentLink();
      final hub = await setup(tester, link);
      await hub.local.cacheTimeline(
        hub.hosts.single.id,
        't2',
        {
          'items': [
            {
              'itemId': 'cached-answer',
              'turnId': 'old',
              'kind': 'assistant_message',
              'text': '已缓存的回答',
            },
          ],
          'lastSequence': 2,
        },
        DateTime.utc(2026, 10, 21, 10),
        hub.local.cacheEpoch,
      );
      unawaited(hub.disconnect(hub.hosts.single));
      await tester.pumpAndSettle();
      await tester.tap(find.text('修复移动端布局'));
      await tester.pumpAndSettle();

      expect(find.text('已缓存的回答', findRichText: true), findsOneWidget);
      expect(find.textContaining('离线缓存 · 内容同步于'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, '重连后再发送');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<IconButton>(
              find
                  .ancestor(
                    of: find.byTooltip('发送'),
                    matching: find.byType(IconButton),
                  )
                  .first,
            )
            .onPressed,
        isNull,
      );
      expect(link.sends, isEmpty);
      await tester.pumpWidget(const SizedBox());
      hub.dispose();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'clearing cache from settings preserves drafts and paired computer',
    (tester) async {
      final hub = await setup(tester, AttachmentLink());
      final h = hub.hosts.single,
          key = draftKey(hub.hosts.single.id, 'p1', 't2');
      await hub.local.saveDraft(key, {'text': 'keep me', 'attachments': []});
      await hub.local.cacheTimeline(
        h.id,
        't2',
        {'items': [], 'lastSequence': 1},
        DateTime.now(),
        hub.local.cacheEpoch,
      );
      final navigator = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );
      navigator.push(
        MaterialPageRoute<void>(builder: (_) => const PreferencesPage()),
      );
      await tester.pumpAndSettle();
      await tapVisible(tester, find.text('清除缓存'));
      await tester.tap(find.text('清除'));
      await tester.pumpAndSettle();
      expect((await hub.local.draft(key))!['text'], 'keep me');
      expect((await hub.local.cacheUsage()).sessions, 0);
      expect(hub.hosts.length, 1);
      await tester.pumpWidget(const SizedBox());
      hub.dispose();
      expect(tester.takeException(), isNull);
    },
  );
}
