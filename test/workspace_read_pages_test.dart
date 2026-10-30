import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/app.dart';
import 'package:dogcodes_app/core/preferences.dart';
import 'package:dogcodes_app/core/host_hub.dart';
import 'package:dogcodes_app/features/tools/changes_page.dart';
import 'package:dogcodes_app/features/tools/files_page.dart';
import 'package:dogcodes_app/features/tools/tool_context.dart';
import 'package:dogcodes_app/ui/theme.dart';
import 'widget_test.dart' show FakeLink, fakeHub;

class ReadLink extends FakeLink {
  ReadLink(this.label) : super('macbook-pro-host');
  final String label;
  String revision = 'one';
  Future<dynamic> Function(Map args)? list, query, preview;
  Future<String>? summary;
  final writes = <String>[];
  final diffReads = <String>[];
  Map<String, dynamic> snapshot(String mode) => {
    'id': '$label-$revision-$mode',
    'roots': [
      {
        'root': {'id': 'repo', 'path': '/fixture/repo', 'git': true},
        'files': mode == 'staged'
            ? []
            : [
                {'path': '$label.dart', 'kind': 'modified'},
              ],
        'statistics': {},
      },
    ],
  };
  @override
  Future<dynamic> call(String method, dynamic args) async {
    if (method == 'workspace_roots') return ['/first', '/second'];
    if (method == 'workspace_directory') {
      return list?.call(args as Map) ??
          [
            {'name': '$label.txt', 'path': '$label.txt', 'directory': false},
          ];
    }
    if (method == 'workspace_preview') {
      return preview?.call(args as Map) ?? {'text': '$label preview'};
    }
    if (method == 'review') {
      final op = args['operation'] as String, params = args['arguments'] as Map;
      if (op == 'query') {
        return query?.call(params) ?? snapshot(params['mode'] as String);
      }
      if (op == 'workspaces') {
        return [
          {'current': true, 'git': true, 'branch': 'main'},
        ];
      }
      if (op == 'file') {
        diffReads.add(params['snapshotId'] as String);
        return {
          'binary': false,
          'text': {
            'before': [],
            'after': ['$label $revision diff'],
          },
        };
      }
      if (op == 'commit_summary') return summary ?? 'Generated summary';
      writes.add(op);
      throw StateError('unexpected write: $op');
    }
    return super.call(method, args);
  }
}

Future<void> mountPage(
  WidgetTester tester,
  ReadLink link,
  Widget Function(ToolContext) page,
  Future<void> Function(HostHub hub, HostState host) body,
) async {
  final hub = fakeHub(), preferences = AppPreferences();
  await hub.load(connect: false);
  await hub.attach(hub.hosts.single, link);
  final host = hub.hosts.single;
  await tester.pumpWidget(
    AppScope(
      hub: hub,
      preferences: preferences,
      runtime: null,
      client: null,
      child: MaterialApp(
        theme: dcTheme(Brightness.light),
        home: page(ToolContext(host, host.projects.single)),
      ),
    ),
  );
  await tester.pump();
  try {
    await body(hub, host);
  } finally {
    await tester.pumpWidget(const SizedBox());
    hub.dispose();
    preferences.dispose();
  }
}

void main() {
  testWidgets('a slower directory response cannot replace the selected root', (
    t,
  ) async {
    final old = Completer<dynamic>();
    final link = ReadLink('new')
      ..list = (args) async => args['root'] == 0
          ? old.future
          : [
              {'name': 'new.txt', 'path': 'new.txt', 'directory': false},
            ];
    await mountPage(t, link, (tool) => FilesPage(tool: tool), (
      hub,
      host,
    ) async {
      await t.tap(find.byTooltip('切换目录'));
      await t.pumpAndSettle();
      await t.tap(
        find.ancestor(
          of: find.text('/second'),
          matching: find.byType(CheckedPopupMenuItem<int>),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('new.txt'), findsOneWidget);
      old.complete([
        {'name': 'old.txt', 'path': 'old.txt', 'directory': false},
      ]);
      await t.pumpAndSettle();
      expect(find.text('old.txt'), findsNothing);
      expect(find.text('new.txt'), findsOneWidget);
    });
  });

  testWidgets(
    'files recover on reconnect without accepting a retired directory reply',
    (t) async {
      final old = Completer<dynamic>();
      final link = ReadLink('old')..list = (_) => old.future;
      await mountPage(t, link, (tool) => FilesPage(tool: tool), (
        hub,
        host,
      ) async {
        await t.runAsync(() => hub.disconnect(host));
        await t.pump();
        expect(find.text('电脑离线，重新连接后再试。'), findsOneWidget);
        await t.runAsync(() => hub.attach(host, ReadLink('new')));
        await t.pumpAndSettle();
        expect(find.text('new.txt'), findsOneWidget);
        old.complete([
          {'name': 'old.txt', 'path': 'old.txt', 'directory': false},
        ]);
        await t.pumpAndSettle();
        expect(find.text('old.txt'), findsNothing);
      });
    },
  );

  testWidgets('a preview reloads after reconnect and ignores its old reply', (
    t,
  ) async {
    final old = Completer<dynamic>();
    final link = ReadLink('old')..preview = (_) => old.future;
    await mountPage(
      t,
      link,
      (tool) => FilePreviewPage(tool: tool, root: 0, path: 'file.txt'),
      (hub, host) async {
        await t.runAsync(() => hub.disconnect(host));
        await t.runAsync(() => hub.attach(host, ReadLink('new')));
        await t.pumpAndSettle();
        expect(find.text('new preview'), findsOneWidget);
        old.complete({'text': 'old preview'});
        await t.pumpAndSettle();
        expect(find.text('old preview'), findsNothing);
      },
    );
  });

  testWidgets('a slower Git range query cannot overwrite the current range', (
    t,
  ) async {
    final old = Completer<dynamic>();
    final link = ReadLink('new');
    link.query = (args) async => args['mode'] == 'uncommitted'
        ? old.future
        : link.snapshot(args['mode'] as String);
    await mountPage(t, link, (tool) => ChangesPage(tool: tool), (
      hub,
      host,
    ) async {
      await t.tap(find.byTooltip('比较范围'));
      await t.pumpAndSettle();
      await t.tap(find.text('未暂存'));
      await t.pumpAndSettle();
      expect(find.text('new.dart'), findsOneWidget);
      old.complete(ReadLink('old').snapshot('uncommitted'));
      await t.pumpAndSettle();
      expect(find.text('old.dart'), findsNothing);
      expect(find.text('new.dart'), findsOneWidget);
    });
  });

  testWidgets('refreshing a Git snapshot reloads an already expanded diff', (
    t,
  ) async {
    final link = ReadLink('source');
    await mountPage(t, link, (tool) => ChangesPage(tool: tool), (
      hub,
      host,
    ) async {
      await t.pumpAndSettle();
      await t.tap(find.text('source.dart'));
      await t.pumpAndSettle();
      expect(find.text('+ source one diff'), findsOneWidget);
      link.revision = 'two';
      final refresh = t.state<RefreshIndicatorState>(
        find.byType(RefreshIndicator),
      );
      unawaited(refresh.show());
      await t.pumpAndSettle();
      expect(find.text('+ source two diff'), findsOneWidget);
      expect(find.text('+ source one diff'), findsNothing);
      expect(link.diffReads, [
        'source-one-uncommitted',
        'source-two-uncommitted',
      ]);
    });
  });

  testWidgets(
    'reconnecting during commit confirmation requires a fresh confirmation',
    (t) async {
      final link = ReadLink('old');
      await mountPage(t, link, (tool) => ChangesPage(tool: tool), (
        hub,
        host,
      ) async {
        await t.pumpAndSettle();
        await t.enterText(find.byType(TextField), 'My commit');
        await t.tap(find.text('提交'));
        await t.pumpAndSettle();
        expect(find.text('暂存全部并提交？'), findsOneWidget);
        final replacement = ReadLink('new');
        await t.runAsync(() => hub.disconnect(host));
        await t.runAsync(() => hub.attach(host, replacement));
        await t.pumpAndSettle();
        await t.tap(find.text('暂存并提交'));
        await t.pumpAndSettle();
        expect(find.text('连接或变更已更新，请核对后重新提交。'), findsOneWidget);
        expect(link.writes, isEmpty);
        expect(replacement.writes, isEmpty);
        expect(find.text('new.dart'), findsOneWidget);
        expect(find.text('My commit'), findsOneWidget);
      });
    },
  );

  testWidgets(
    'a late AI commit summary preserves a message edited while waiting',
    (t) async {
      final summary = Completer<String>();
      final link = ReadLink('source')..summary = summary.future;
      await mountPage(t, link, (tool) => ChangesPage(tool: tool), (
        hub,
        host,
      ) async {
        await t.pumpAndSettle();
        await t.tap(find.byTooltip('AI 生成提交说明'));
        await t.pump();
        await t.enterText(find.byType(TextField), 'User edited message');
        summary.complete('Outdated generated summary');
        await t.pumpAndSettle();
        expect(find.text('User edited message'), findsOneWidget);
        expect(find.text('Outdated generated summary'), findsNothing);
      });
    },
  );
}
