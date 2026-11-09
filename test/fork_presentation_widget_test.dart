import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/app.dart';
import 'package:dogcodes_app/features/sessions/sessions_page.dart';
import 'widget_test.dart' show FakeLink, fakeHub;

/// A host where 修复移动端布局 (t2) was forked into a worktree, and that fork
/// was forked again in place.
class ForkedLink extends FakeLink {
  ForkedLink() : super('macbook-pro-host');
  @override
  Future<dynamic> call(String method, dynamic params) async {
    final value = await super.call(method, params);
    if (method == 'bootstrap') {
      (value['projects'] as List).add({
        'projectId': 'prj_FORK',
        'displayName': 'dogcodes-web · Fork',
        'path': '/Users/dev/dogcodes-web/.git/dogcodes-worktrees/tsk_FORK',
        'taskCount': 1,
      });
      (value['tasks'] as List).addAll([
        {
          'taskId': 'tsk_FORK',
          'projectId': 'prj_FORK',
          'title': '修复移动端布局 · Fork',
          'preferredExecutor': FakeLink.executor,
          'activePrimaryRun': null,
          'streamVersion': 2,
          'updatedAt': FakeLink.now,
          'forkedFrom': 't2',
        },
        {
          'taskId': 'tsk_NESTED',
          'projectId': 'prj_FORK',
          'title': '只改平板布局',
          'preferredExecutor': FakeLink.executor,
          'lastTurnExecutor': FakeLink.executor,
          'activePrimaryRun': null,
          'streamVersion': 3,
          'updatedAt': FakeLink.now,
          'forkedFrom': 'tsk_FORK',
        },
      ]);
    }
    if (method == 'timeline_snapshot' && params[0] == 'tsk_FORK') {
      value['items'] = [
        {
          'itemId': 'fork',
          'kind': 'fork_context',
          'occurredAt': FakeLink.now,
          'text':
              '{"sourceTaskId":"t2","environment":"worktree","restoredTurnSnapshot":false,"contextOnly":true,'
              '"text":"[{\\"kind\\":\\"turn.queued\\",\\"text\\":\\"原始历史问题\\"},{\\"kind\\":\\"message.delta\\",\\"text\\":\\"原始回答\\"}]"}',
        },
      ];
    }
    return value;
  }
}

Finder rowOf(String title) =>
    find.ancestor(of: find.text(title), matching: find.byType(SessionRow));

void main() {
  testWidgets('forks are listed under their source, without a fork project', (
    tester,
  ) async {
    final hub = fakeHub();
    await hub.load(connect: false);
    await hub.attach(hub.hosts.single, ForkedLink());
    await tester.pumpWidget(DogCodesApp(hub: hub));
    await tester.pumpAndSettle();

    final rows = tester.widgetList<SessionRow>(find.byType(SessionRow)).toList();
    final order = [for (final r in rows) (r.session.taskId, r.depth)];
    final source = order.indexOf(('t2', 0));
    expect(source, isNot(-1));
    expect(order.sublist(source + 1, source + 3), [
      ('tsk_FORK', 1),
      ('tsk_NESTED', 2),
    ]);
    // The worktree fork's own project never becomes a group of its own.
    expect(find.text('dogcodes-web · Fork'), findsNothing);
    // The suffix is redundant once the row sits under its source.
    expect(find.text('修复移动端布局 · Fork'), findsNothing);
    expect(
      find.descendant(
        of: rowOf('只改平板布局'),
        matching: find.byIcon(Icons.subdirectory_arrow_right),
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
    hub.dispose();
  });

  testWidgets('a fork opens with its origin and can return to the source', (
    tester,
  ) async {
    final hub = fakeHub();
    await hub.load(connect: false);
    await hub.attach(hub.hosts.single, ForkedLink());
    await tester.pumpWidget(DogCodesApp(hub: hub));
    await tester.pumpAndSettle();
    final forkRow = find.byWidgetPredicate(
      (w) => w is SessionRow && w.session.taskId == 'tsk_FORK',
    );
    await tester.ensureVisible(forkRow);
    await tester.tap(forkRow);
    await tester.pumpAndSettle();

    expect(find.textContaining('分叉自'), findsOneWidget);
    expect(find.textContaining('此项目不是 Git 仓库'), findsOneWidget);
    expect(find.textContaining('在下方发送消息即可从这里继续'), findsOneWidget);
    expect(find.text('原始回答'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('fork-context-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('原始回答'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('fork-source')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('fork-source')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    hub.dispose();
  });
}
