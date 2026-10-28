import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/features/tools/changes_page.dart';
import 'workspace_read_pages_test.dart' show ReadLink, mountPage;

class RootsLink extends ReadLink {
  RootsLink() : super('roots');
  bool reversed = false, removeSecond = false, firstGit = true;
  final requests = <Map<String, dynamic>>[];
  final receipts = <String, Map<String, dynamic>>{};
  List<String> get ids => removeSecond
      ? ['a']
      : reversed
      ? ['b', 'a']
      : ['a', 'b'];
  Map<String, dynamic> changes(String mode) => {
    'id': 'snapshot-$revision-$mode',
    'roots': [
      // The index response has a different order from the changes response.
      for (final id in mode == 'staged' ? ids.reversed : ids)
        {
          'root': {
            'id': id,
            'path': id == 'a' ? '/workspace/frontend' : r'C:\work\backend',
            'git': id != 'a' || firstGit,
          },
          'files': mode == 'staged' && id == 'a'
              ? []
              : [
                  {'path': 'same.dart', 'kind': 'modified'},
                ],
          'statistics': {},
        },
    ],
  };
  @override
  Future<dynamic> call(String method, dynamic args) async {
    if (method != 'review') return super.call(method, args);
    final operation = args['operation'] as String;
    final request = Map<String, dynamic>.from(args['arguments'] as Map);
    if (operation == 'query') return changes(request['mode'] as String);
    if (operation == 'workspaces') {
      return [
        {'current': true, 'git': true, 'branch': 'frontend-main'},
      ];
    }
    if (operation == 'file') {
      requests.add({'type': operation, ...request});
      return {
        'text': {
          'before': [],
          'after': ['${request['rootId']} diff'],
        },
      };
    }
    if (operation == 'commit_summary') {
      requests.add({'type': operation, ...request});
      return 'Summary for ${request['rootId']}';
    }
    if (operation == 'index' || operation == 'git_action') {
      requests.add({'type': operation, ...request});
      receipts[request['operationId'] as String] = {
        'request': operation == 'index'
            ? {
                'operationId': request['operationId'],
                'taskId': request['taskId'],
                'command': 'core_review_index',
                'arguments': {
                  for (final entry in request.entries)
                    if (entry.key != 'operationId') entry.key: entry.value,
                },
              }
            : request,
        'outcome': {'status': 'succeeded', 'completed': true},
        'closed': false,
      };
      return true;
    }
    if (operation == 'file_operation' || operation == 'git_operation') {
      return receipts[request['operationId']];
    }
    return super.call(method, args);
  }
}

Future<void> selectBackend(WidgetTester tester) async {
  await tester.tap(find.byTooltip('选择 Git 目录'));
  await tester.pumpAndSettle();
  await tester.tap(
    find.ancestor(
      of: find.text(r'C:\work\backend'),
      matching: find.byType(CheckedPopupMenuItem<String>),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;
  testWidgets(
    'root selection scopes the file diff and joins staged counts by root identity',
    (t) async {
      await t.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => t.binding.setSurfaceSize(null));
      final link = RootsLink();
      await mountPage(t, link, (tool) => ChangesPage(tool: tool), (
        hub,
        host,
      ) async {
        await t.pumpAndSettle();
        expect(find.text('1 个文件 · 已暂存 0'), findsOneWidget);
        await t.tap(find.text('same.dart'));
        await t.pumpAndSettle();
        expect(find.text('+ a diff'), findsOneWidget);
        await selectBackend(t);
        expect(find.text('1 个文件 · 已暂存 1'), findsOneWidget);
        expect(find.text('+ a diff'), findsNothing);
        expect(find.text('frontend-main'), findsNothing);
        await t.tap(find.text('same.dart'));
        await t.pumpAndSettle();
        expect(find.text('+ b diff'), findsOneWidget);
        expect(
          link.requests
              .where((r) => r['type'] == 'file')
              .map((r) => r['rootId']),
          ['a', 'b'],
        );
      });
    },
  );

  testWidgets(
    'stage, unstage, summary, commit and remote Git actions use the selected root',
    (t) async {
      final link = RootsLink();
      await mountPage(t, link, (tool) => ChangesPage(tool: tool), (
        hub,
        host,
      ) async {
        await t.pumpAndSettle();
        await selectBackend(t);
        for (final label in ['暂存', '取消暂存']) {
          await t.tap(find.byType(Checkbox).first);
          await t.pumpAndSettle();
          await t.tap(find.text(label));
          await t.pumpAndSettle();
        }
        await t.tap(find.byTooltip('AI 生成提交说明'));
        await t.pumpAndSettle();
        expect(find.text('Summary for b'), findsOneWidget);
        await t.tap(find.text('提交'));
        await t.pumpAndSettle();
        expect(find.text('暂存全部并提交？'), findsNothing);
        for (final label in ['推送', '拉取', '同步']) {
          await t.tap(find.byTooltip('更多 Git 操作'));
          await t.pumpAndSettle();
          await t.tap(find.text(label));
          await t.pumpAndSettle();
        }
        expect(link.requests, hasLength(7));
        expect(link.requests.every((r) => r['rootId'] == 'b'), isTrue);
        expect(
          link.requests
              .where((r) => r['type'] == 'index')
              .map((r) => r['action']),
          ['stage', 'unstage'],
        );
        final commit = link.requests.singleWhere(
          (r) => r['action'] == 'commit',
        );
        expect(commit['message'], 'Summary for b');
        expect(commit['stageAll'], isFalse);
        expect(await host.operations.sidePending(), isNull);
      });
    },
  );

  testWidgets(
    'per-root drafts and root selection survive a reordered reconnect and removed root',
    (t) async {
      final link = RootsLink();
      await mountPage(t, link, (tool) => ChangesPage(tool: tool), (
        hub,
        host,
      ) async {
        await t.pumpAndSettle();
        await t.enterText(find.byType(TextField), 'Frontend draft');
        await selectBackend(t);
        expect(find.text('Frontend draft'), findsNothing);
        await t.enterText(find.byType(TextField), 'Backend draft');
        final replacement = RootsLink()..reversed = true;
        await t.runAsync(() => hub.attach(host, replacement));
        await t.pumpAndSettle();
        expect(find.text('Backend draft'), findsOneWidget);
        expect(find.text('1 个文件 · 已暂存 1'), findsOneWidget);
        replacement.removeSecond = true;
        final refresh = t.state<RefreshIndicatorState>(
          find.byType(RefreshIndicator),
        );
        final refreshing = refresh.show();
        await t.pumpAndSettle();
        await refreshing;
        expect(find.text('Frontend draft'), findsOneWidget);
        expect(find.text('Backend draft'), findsNothing);
        expect(find.text('1 个文件 · 已暂存 0'), findsOneWidget);
        expect(replacement.requests, isEmpty);
      });
    },
  );

  testWidgets(
    'an additional Git repository is available when the main directory is not Git',
    (t) async {
      final link = RootsLink()..firstGit = false;
      await mountPage(t, link, (tool) => ChangesPage(tool: tool), (
        hub,
        host,
      ) async {
        await t.pumpAndSettle();
        expect(find.text('backend'), findsOneWidget);
        expect(find.text('1 个文件 · 已暂存 1'), findsOneWidget);
        await t.tap(find.text('same.dart'));
        await t.pumpAndSettle();
        expect(link.requests.single['rootId'], 'b');
      });
    },
  );
}
