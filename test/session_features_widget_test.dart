import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/app.dart';
import 'package:dogcodes_app/features/sessions/sessions_page.dart';
import 'widget_test.dart' show FakeLink, fakeHub;

class SessionLink extends FakeLink {
  SessionLink() : super('macbook-pro-host');
  Map<String, dynamic> preferences = {
    'tasks': <String, dynamic>{},
    'projects': {},
    'sorts': {},
    'orders': {},
  };
  int revision = 0;
  final receipts = <String>{};
  Map<String, dynamic>? forkRequest;
  final searches = <Map<String, dynamic>>[];
  @override
  Future<dynamic> call(String method, dynamic params) async {
    if (method == 'history_preferences') {
      return {
        'revision': '$revision',
        'preferences': jsonDecode(jsonEncode(preferences)),
      };
    }
    if (method == 'command_receipt') {
      return receipts.contains(params[0]['commandId'])
          ? {'lastSequence': '90'}
          : null;
    }
    if (method == 'execute' &&
        params[0]['payload']['type'] == 'set_history_preferences') {
      expect(params[0]['expectedStreamVersion'], '$revision');
      preferences = Map<String, dynamic>.from(
        params[0]['payload']['data'] as Map,
      );
      revision++;
      receipts.add(params[0]['commandId'] as String);
      push({
        'eventType': 'preferences.history.updated',
        'streamVersion': '$revision',
        'sequence': '90',
        'payload': preferences,
      });
      return {'lastSequence': '90'};
    }
    if (method == 'fork_task') {
      forkRequest = Map<String, dynamic>.from(params[0] as Map);
      return forkRequest!['newTaskId'];
    }
    if (method == 'fork_receipt') {
      return {'request': forkRequest, 'completed': true, 'taskAvailable': true};
    }
    if (method == 'query_history') {
      searches.add(Map<String, dynamic>.from(params[0] as Map));
      return {
        'items': [
          {
            'sequence': '2',
            'turnId': 'turn2',
            'kind': 'assistant_message',
            'text': '匹配历史正文',
            'occurredAt': 1,
          },
        ],
        'throughSequence': '9',
        'nextCursor': null,
      };
    }
    final value = await super.call(method, params);
    if (method == 'bootstrap' && forkRequest != null) {
      (value['tasks'] as List).add({
        'taskId': forkRequest!['newTaskId'],
        'projectId': 'p1',
        'title': 'Fork 新会话',
        'streamVersion': 1,
        'activePrimaryRun': null,
        'preferredExecutor': FakeLink.executor,
      });
    }
    if (method == 'timeline_snapshot') {
      value['items'] = [
        {
          'itemId': 'u',
          'turnId': 'turn2',
          'kind': 'user_message',
          'text': '原始历史问题',
          'occurredAt': FakeLink.now,
        },
        {
          'itemId': 'a',
          'turnId': 'turn2',
          'kind': 'assistant_message',
          'text': '匹配历史正文',
          'occurredAt': FakeLink.now,
        },
      ];
    }
    return value;
  }
}

Future<void> menu(WidgetTester tester) async {
  final row = find.ancestor(
    of: find.text('修复移动端布局'),
    matching: find.byType(SessionRow),
  );
  await tester.ensureVisible(row);
  await tester.tap(find.descendant(of: row, matching: find.byTooltip('会话操作')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'pin/archive/unarchive update shared preferences and list sections',
    (tester) async {
      final link = SessionLink(), hub = fakeHub();
      await hub.load(connect: false);
      await hub.attach(hub.hosts.single, link);
      await tester.pumpWidget(DogCodesApp(hub: hub));
      await tester.pumpAndSettle();
      await menu(tester);
      await tester.tap(find.text('置顶会话'));
      await tester.pumpAndSettle();
      expect(link.preferences['tasks']['t2'], 'pinned');
      expect(find.text('置顶'), findsOneWidget);
      await menu(tester);
      await tester.tap(find.text('归档会话'));
      await tester.pumpAndSettle();
      expect(find.text('修复移动端布局'), findsNothing);
      await tester.tap(find.text('已归档'));
      await tester.pumpAndSettle();
      expect(find.text('修复移动端布局'), findsOneWidget);
      await menu(tester);
      await tester.tap(find.text('取消归档'));
      await tester.pumpAndSettle();
      expect(link.preferences['tasks']['t2'], isNull);
      expect(find.text('暂无已归档会话'), findsOneWidget);
      await tester.tap(find.text('当前会话'));
      await tester.pumpAndSettle();
      expect(find.text('修复移动端布局'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      hub.dispose();
    },
  );

  testWidgets(
    'Fork selects a historical turn and environment and opens the returned task',
    (tester) async {
      final link = SessionLink(), hub = fakeHub();
      await hub.load(connect: false);
      await hub.attach(hub.hosts.single, link);
      await tester.pumpWidget(DogCodesApp(hub: hub));
      await tester.pumpAndSettle();
      await menu(tester);
      await tester.tap(find.text('Fork 会话'));
      await tester.pumpAndSettle();
      expect(find.text('第 1 轮 · 原始历史问题'), findsOneWidget);
      await tester.tap(find.text('新 Worktree'));
      await tester.tap(find.text('创建 Fork'));
      await tester.pumpAndSettle();
      expect(link.forkRequest!['taskId'], 't2');
      expect(link.forkRequest!['turnId'], 'turn2');
      expect(link.forkRequest!['environment'], 'worktree');
      expect(find.text('Fork 新会话'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      hub.dispose();
    },
  );

  testWidgets(
    'history search covers scoped sessions and opens the matching turn',
    (tester) async {
      final link = SessionLink(), hub = fakeHub();
      await hub.load(connect: false);
      await hub.attach(hub.hosts.single, link);
      await tester.pumpWidget(DogCodesApp(hub: hub));
      await tester.pumpAndSettle();
      await menu(tester);
      await tester.tap(find.text('搜索历史正文'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '历史');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(link.searches.single['taskId'], 't2');
      expect(link.searches.single['text'], '历史');
      await tester.tap(find.text('匹配历史正文'));
      await tester.pumpAndSettle();
      expect(find.text('打开对应会话'), findsOneWidget);
      await tester.tap(find.text('打开对应会话'));
      await tester.pumpAndSettle();
      expect(find.text('原始历史问题'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      hub.dispose();
      expect(tester.takeException(), isNull);
    },
  );
}
