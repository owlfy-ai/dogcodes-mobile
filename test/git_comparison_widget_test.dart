import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/features/tools/changes_page.dart';
import 'git_roots_widget_test.dart' show RootsLink, selectBackend;
import 'workspace_read_pages_test.dart' show mountPage;

class ComparisonLink extends RootsLink {
  final reads = <Map<String, dynamic>>[];
  Future<dynamic>? historyResponse, comparisonResponse;
  bool failHistory = false, failComparison = false;
  @override
  Future<dynamic> call(String method, dynamic args) async {
    if (method == 'review') {
      final op = args['operation'];
      final request = Map<String, dynamic>.from(args['arguments'] as Map);
      reads.add({'type': op, ...request});
      if (op == 'history') {
        if (failHistory) throw StateError('history unavailable');
        if (historyResponse != null) return historyResponse!;
        return [
          for (
            var i = request['skip'] as int;
            i < (request['skip'] == 0 ? 50 : 51);
            i++
          )
            {
              'id': 'commit-$i-long-id',
              'subject': 'Commit $i',
              'author': 'Fixture',
              'date': '2026-10-26',
              'parents': i == 50
                  ? ['parent-one', 'parent-two']
                  : ['parent-one'],
            },
        ];
      }
      if (op == 'branches') {
        return [
          {'name': 'refs/heads/main', 'commit': 'main-sha'},
          {'name': 'refs/remotes/origin/topic', 'commit': 'topic-sha'},
        ];
      }
      if (op == 'query' && ['committed', 'branch'].contains(request['mode'])) {
        if (failComparison) throw StateError('comparison unavailable');
        if (comparisonResponse != null) return comparisonResponse!;
        return {
          'id':
              'compare-${request['reference']}-${request['parent']}-$revision',
          'roots': [
            for (final root in changes('uncommitted')['roots'] as List)
              if (root['root']['id'] == request['rootId']) root,
          ],
        };
      }
    }
    return super.call(method, args);
  }
}

Future<void> compareMode(WidgetTester t, String label) async {
  await t.tap(find.byTooltip('比较范围'));
  await t.pumpAndSettle();
  await t.tap(find.text(label).last);
  await t.pumpAndSettle();
}

void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;
  testWidgets(
    'paged commit and merge parent comparisons are scoped and read only',
    (t) async {
      await t.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => t.binding.setSurfaceSize(null));
      final link = ComparisonLink();
      await mountPage(t, link, (tool) => ChangesPage(tool: tool), (
        hub,
        host,
      ) async {
        await t.pumpAndSettle();
        await selectBackend(t);
        await t.enterText(find.byType(TextField), 'Keep backend draft');
        await compareMode(t, '历史提交');
        expect(find.text('选择历史提交'), findsOneWidget);
        await t.tap(find.text('加载更早的提交'));
        await t.pumpAndSettle();
        await t.scrollUntilVisible(
          find.text('Commit 50'),
          300,
          scrollable: find.byType(Scrollable).last,
        );
        await t.tap(find.text('Commit 50'));
        await t.pumpAndSettle();
        expect(find.byType(TextField), findsNothing);
        expect(find.byType(Checkbox), findsNothing);
        expect(find.text('提交'), findsNothing);
        expect(find.byTooltip('选择 Git 目录'), findsOneWidget);
        expect(
          t
              .widget<PopupMenuButton<String>>(
                find.byWidgetPredicate(
                  (w) =>
                      w is PopupMenuButton<String> && w.tooltip == '更多 Git 操作',
                ),
              )
              .enabled,
          isFalse,
        );
        expect(
          link.reads.where((r) => r['type'] == 'history').map((r) => r['skip']),
          [0, 50],
        );
        expect(
          link.reads
              .where((r) => r['type'] == 'history')
              .every((r) => r['rootId'] == 'b'),
          isTrue,
        );
        var query = link.reads.lastWhere((r) => r['mode'] == 'committed');
        expect(query['rootId'], 'b');
        expect(query['reference'], 'commit-50-long-id');
        expect(query['parent'], 0);
        await t.tap(find.byTooltip('选择父提交'));
        await t.pumpAndSettle();
        await t.tap(find.text('父提交 2 · parent-t'));
        await t.pumpAndSettle();
        query = link.reads.lastWhere((r) => r['mode'] == 'committed');
        expect(query['parent'], 1);
        await t.tap(find.text('same.dart'));
        await t.pumpAndSettle();
        expect(find.text('+ b diff'), findsOneWidget);
        expect(link.requests.single['rootId'], 'b');
        expect(
          link.requests.single['snapshotId'],
          'compare-commit-50-long-id-1-one',
        );
        await compareMode(t, '未提交变更');
        expect(find.text('Keep backend draft'), findsOneWidget);
        expect(find.byType(Checkbox), findsOneWidget);
        expect(link.requests.where((r) => r['type'] != 'file'), isEmpty);
      });
    },
  );

  testWidgets(
    'branch comparison uses its full ref and root switch restores working changes',
    (t) async {
      final link = ComparisonLink();
      await mountPage(t, link, (tool) => ChangesPage(tool: tool), (
        hub,
        host,
      ) async {
        await t.pumpAndSettle();
        await t.enterText(find.byType(TextField), 'Frontend draft');
        await compareMode(t, '分支比较');
        await t.tap(find.text('origin/topic'));
        await t.pumpAndSettle();
        final query = link.reads.lastWhere((r) => r['mode'] == 'branch');
        expect(query['reference'], 'refs/remotes/origin/topic');
        expect(query['rootId'], 'a');
        expect(find.text('只读 · 当前 HEAD 相对所选分支共同祖先的变更'), findsOneWidget);
        expect(find.byType(Checkbox), findsNothing);
        await selectBackend(t);
        expect(find.text('未提交变更'), findsOneWidget);
        expect(find.byType(Checkbox), findsOneWidget);
        expect(find.text('origin/topic'), findsNothing);
        await t.tap(find.byTooltip('选择 Git 目录'));
        await t.pumpAndSettle();
        await t.tap(
          find.ancestor(
            of: find.text('/workspace/frontend'),
            matching: find.byType(CheckedPopupMenuItem<String>),
          ),
        );
        await t.pumpAndSettle();
        expect(find.text('Frontend draft'), findsOneWidget);
        expect(link.requests, isEmpty);
      });
    },
  );

  testWidgets(
    'cancelled or failed reference selection keeps the working view',
    (t) async {
      final link = ComparisonLink()..failHistory = true;
      await mountPage(t, link, (tool) => ChangesPage(tool: tool), (
        hub,
        host,
      ) async {
        await t.pumpAndSettle();
        await compareMode(t, '历史提交');
        expect(find.textContaining('history unavailable'), findsOneWidget);
        link.failHistory = false;
        await t.tap(find.text('重试'));
        await t.pumpAndSettle();
        expect(find.text('Commit 0'), findsOneWidget);
        await t.tap(find.byTooltip('关闭'));
        await t.pumpAndSettle();
        expect(find.text('未提交变更'), findsOneWidget);
        expect(find.byType(TextField), findsOneWidget);
        expect(link.reads.where((r) => r['mode'] == 'committed'), isEmpty);
      });
    },
  );

  testWidgets(
    'reference chosen from a retired connection cannot issue a comparison',
    (t) async {
      final reply = Completer<dynamic>();
      final link = ComparisonLink()..historyResponse = reply.future;
      await mountPage(t, link, (tool) => ChangesPage(tool: tool), (
        hub,
        host,
      ) async {
        await t.pumpAndSettle();
        await t.tap(find.byTooltip('比较范围'));
        await t.pumpAndSettle();
        await t.tap(find.text('历史提交'));
        await t.pump();
        final replacement = ComparisonLink();
        await t.runAsync(() => hub.attach(host, replacement));
        await t.pump();
        reply.complete([
          {'id': 'stale', 'subject': 'Stale commit', 'parents': []},
        ]);
        await t.pumpAndSettle();
        expect(find.text('Stale commit'), findsNothing);
        expect(find.text('选择历史提交'), findsNothing);
        expect(find.text('未提交变更'), findsOneWidget);
        expect(link.reads.where((r) => r['mode'] == 'committed'), isEmpty);
        expect(
          replacement.reads.where((r) => r['mode'] == 'committed'),
          isEmpty,
        );
      });
    },
  );

  testWidgets(
    'failed historical query is read only and can return to working changes',
    (t) async {
      final link = ComparisonLink()..failComparison = true;
      await mountPage(t, link, (tool) => ChangesPage(tool: tool), (
        hub,
        host,
      ) async {
        await t.pumpAndSettle();
        await compareMode(t, '分支比较');
        await t.tap(find.text('main').last);
        await t.pumpAndSettle();
        expect(find.textContaining('comparison unavailable'), findsOneWidget);
        expect(find.byType(TextField), findsNothing);
        await compareMode(t, '未提交变更');
        expect(find.textContaining('comparison unavailable'), findsNothing);
        expect(find.byType(TextField), findsOneWidget);
        expect(link.requests, isEmpty);
      });
    },
  );

  testWidgets(
    'reconnect reloads the chosen comparison and ignores its retired reply',
    (t) async {
      final old = Completer<dynamic>();
      final link = ComparisonLink()..comparisonResponse = old.future;
      await mountPage(t, link, (tool) => ChangesPage(tool: tool), (
        hub,
        host,
      ) async {
        await t.pumpAndSettle();
        await compareMode(t, '历史提交');
        await t.tap(find.text('Commit 0'));
        await t.pump();
        final replacement = ComparisonLink()..revision = 'new';
        await t.runAsync(() => hub.attach(host, replacement));
        await t.pumpAndSettle();
        final currentQuery = replacement.reads.lastWhere(
          (r) => r['mode'] == 'committed',
        );
        expect(currentQuery['reference'], 'commit-0-long-id');
        expect(currentQuery['rootId'], 'a');
        expect(find.text('same.dart'), findsOneWidget);
        old.complete({
          'id': 'retired-snapshot',
          'roots': [
            {
              'root': {'id': 'a', 'path': '/workspace/frontend', 'git': true},
              'files': [
                {'path': 'retired.dart', 'kind': 'added'},
              ],
            },
          ],
        });
        await t.pumpAndSettle();
        expect(find.text('retired.dart'), findsNothing);
        await t.tap(find.text('same.dart'));
        await t.pumpAndSettle();
        expect(
          replacement.requests.single['snapshotId'],
          'compare-commit-0-long-id-0-new',
        );
        expect(link.requests, isEmpty);
      });
    },
  );
}
