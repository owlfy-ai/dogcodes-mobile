import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/app.dart';
import 'package:dogcodes_app/core/secure_host_client.dart';
import 'widget_test.dart' show FakeLink, fakeHub;

class EditableSession extends FakeLink {
  EditableSession() : super('macbook-pro-host');
  String title = '修复移动端布局';
  bool acceptWrites = true;
  final receipts = <String, Map<String, dynamic>>{};
  @override
  Future<dynamic> call(String method, dynamic params) async {
    if (method == 'command_receipt') {
      return receipts[(params[0] as Map)['commandId']];
    }
    if (method == 'execute') {
      final envelope = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(params[0])) as Map,
      );
      executed.add(envelope);
      if (!acceptWrites) throw const RemoteOutcomeUnknown();
      title = envelope['payload']['data']['title'] as String;
      receipts[envelope['commandId'] as String] = {
        'commandId': envelope['commandId'],
        'accepted': true,
      };
      throw const RemoteOutcomeUnknown();
    }
    final result = await super.call(method, params);
    if (method == 'bootstrap') {
      final task = (result['tasks'] as List).singleWhere(
        (t) => t['taskId'] == 't2',
      );
      task['title'] = title;
    }
    return result;
  }
}

void main() {
  testWidgets(
    'not waiting for an unknown rename only clears the phone record',
    (t) async {
      final link = EditableSession()..acceptWrites = false;
      final hub = fakeHub(link);
      try {
        await t.pumpWidget(DogCodesApp(hub: hub));
        await t.pumpAndSettle();
        await t.tap(find.text('修复移动端布局'));
        await t.pumpAndSettle();
        await t.tap(find.byTooltip('更多'));
        await t.pumpAndSettle();
        await t.tap(find.text('重命名'));
        await t.pumpAndSettle();
        await t.enterText(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(TextFormField),
          ),
          '未执行的名称',
        );
        await t.tap(find.widgetWithText(TextButton, '保存'));
        await t.pumpAndSettle();
        expect(find.text('重命名会话：还没收到电脑确认'), findsOneWidget);
        await t.tap(find.text('不再等待'));
        await t.pumpAndSettle();
        await t.tap(find.text('继续等待'));
        await t.pumpAndSettle();
        expect(find.text('重命名会话：还没收到电脑确认'), findsOneWidget);
        await t.tap(find.text('不再等待'));
        await t.pumpAndSettle();
        await t.tap(find.text('确定'));
        await t.pumpAndSettle();
        expect(find.text('重命名会话：还没收到电脑确认'), findsNothing);
        expect(link.executed.length, 1);
        expect(link.title, '修复移动端布局');
      } finally {
        await t.pumpWidget(const SizedBox());
        hub.dispose();
        await t.pump();
      }
    },
  );

  testWidgets(
    'rename dialog survives its closing animation and exposes recovery',
    (t) async {
      final link = EditableSession();
      // Use the same real HostHub/ConversationPage routing as the app.
      final configured = fakeHub(link);
      try {
        await t.pumpWidget(DogCodesApp(hub: configured));
        await t.pumpAndSettle();
        await t.tap(find.text('修复移动端布局'));
        await t.pumpAndSettle();
        await t.tap(find.byTooltip('更多'));
        await t.pumpAndSettle();
        await t.tap(find.text('重命名'));
        await t.pumpAndSettle();
        final editor = find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextFormField),
        );
        await t.enterText(editor, '手机恢复的名称');
        await t.tap(find.widgetWithText(TextButton, '保存'));
        await t.pumpAndSettle();
        expect(
          t.takeException(),
          isNull,
          reason: 'closing dialog must not read a disposed controller',
        );
        expect(link.executed.single['payload']['type'], 'rename_task');
        expect(link.executed.single['expectedStreamVersion'], '2');
        expect(find.text('重命名会话：还没收到电脑确认'), findsOneWidget);
        await t.tap(find.text('重新确认'));
        await t.pumpAndSettle();
        expect(link.executed.length, 1);
        expect(find.text('重命名会话：还没收到电脑确认'), findsNothing);
      } finally {
        await t.pumpWidget(const SizedBox());
        configured.dispose();
        await t.pump();
      }
    },
  );
}
