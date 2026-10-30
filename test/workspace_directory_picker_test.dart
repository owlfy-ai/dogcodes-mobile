import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/app.dart';
import 'package:dogcodes_app/core/host_hub.dart';
import 'package:dogcodes_app/core/preferences.dart';
import 'package:dogcodes_app/features/tools/files_page.dart';
import 'package:dogcodes_app/features/tools/run_page.dart';
import 'package:dogcodes_app/features/tools/tool_context.dart';
import 'package:dogcodes_app/ui/theme.dart';
import 'workspace_read_pages_test.dart' show ReadLink, mountPage;
import 'workspace_pages_test.dart' show ToolsLink;
import 'widget_test.dart' show fakeHub;

class DirectoryReadLink extends ReadLink {
  DirectoryReadLink() : super('directories');
  List<String> paths = ['/first', '/second'];
  final reads = <Map<String, dynamic>>[];
  Future<dynamic> Function()? search;
  @override
  Future<dynamic> call(String method, dynamic args) async {
    if (method == 'workspace_roots') return paths;
    if (method == 'workspace_find_files') {
      return search?.call() ??
          {
            'files': [
              {'root': 0, 'path': 'first-only.dart'},
              {'root': 0, 'path': 'same.dart'},
              {'root': 1, 'path': 'same.dart'},
            ],
          };
    }
    if (method == 'workspace_preview') {
      reads.add(Map<String, dynamic>.from(args as Map));
      return {'text': 'preview from root ${args['root']}'};
    }
    if (method == 'workspace_directory') {
      reads.add(Map<String, dynamic>.from(args as Map));
      return [
        {'name': 'src', 'path': 'src', 'directory': true},
      ];
    }
    return super.call(method, args);
  }
}

Future<void> chooseDirectory(
  WidgetTester t,
  String tooltip,
  String path,
) async {
  await t.tap(find.byTooltip(tooltip));
  await t.pumpAndSettle();
  await t.tap(
    find.ancestor(
      of: find.text(path).last,
      matching: find.byType(CheckedPopupMenuItem<int>),
    ),
  );
  await t.pumpAndSettle();
}

Future<void> mountRun(
  WidgetTester t,
  ToolsLink link,
  Future<void> Function(HostHub, HostState) body,
) async {
  final hub = fakeHub(), preferences = AppPreferences();
  await hub.load(connect: false);
  await hub.attach(hub.hosts.single, link);
  final host = hub.hosts.single;
  await t.pumpWidget(
    AppScope(
      hub: hub,
      preferences: preferences,
      runtime: null,
      client: null,
      child: MaterialApp(
        theme: dcTheme(Brightness.light),
        home: RunPage(tool: ToolContext(host, host.projects.single)),
      ),
    ),
  );
  await t.pumpAndSettle();
  try {
    await body(hub, host);
  } finally {
    await t.pumpWidget(const SizedBox());
    hub.dispose();
    preferences.dispose();
  }
}

void main() {
  testWidgets(
    'files visibly select a directory, reset breadcrumbs, and scope search and preview',
    (t) async {
      final link = DirectoryReadLink();
      await mountPage(t, link, (tool) => FilesPage(tool: tool), (
        hub,
        host,
      ) async {
        await t.pumpAndSettle();
        expect(find.text('目录 · first'), findsOneWidget);
        await t.tap(find.text('src'));
        await t.pumpAndSettle();
        expect(link.reads.last['path'], 'src');
        await chooseDirectory(t, '切换目录', '/second');
        expect(find.text('目录 · second'), findsOneWidget);
        expect(link.reads.last['root'], 1);
        expect(link.reads.last['path'], '');
        await t.enterText(find.byType(TextField), 'same');
        await t.pump(const Duration(milliseconds: 350));
        await t.pumpAndSettle();
        expect(find.text('first-only.dart'), findsNothing);
        expect(find.byType(ListTile), findsOneWidget);
        await t.tap(find.byType(ListTile));
        await t.pumpAndSettle();
        expect(link.reads.last['root'], 1);
        expect(link.reads.last['path'], 'same.dart');
        expect(find.text('preview from root 1'), findsOneWidget);
      });
    },
  );

  testWidgets(
    'late search results cannot return a file from the previous directory',
    (t) async {
      final old = Completer<dynamic>();
      final link = DirectoryReadLink()..search = () => old.future;
      await mountPage(t, link, (tool) => FilesPage(tool: tool), (
        hub,
        host,
      ) async {
        await t.pumpAndSettle();
        await t.enterText(find.byType(TextField), 'query');
        await t.pump(const Duration(milliseconds: 350));
        link.search = () async => {
          'files': [
            {'root': 1, 'path': 'new.dart'},
          ],
        };
        await chooseDirectory(t, '切换目录', '/second');
        await t.pump(const Duration(milliseconds: 350));
        await t.pumpAndSettle();
        old.complete({
          'files': [
            {'root': 0, 'path': 'old.dart'},
          ],
        });
        await t.pumpAndSettle();
        expect(find.text('new.dart'), findsNWidgets(2));
        expect(find.text('old.dart'), findsNothing);
      });
    },
  );

  testWidgets(
    'partial search responses stay explicit when other roots consume the result limit',
    (t) async {
      final link = DirectoryReadLink()
        ..search = () async => {
          'partial': true,
          'files': [
            {'root': 0, 'path': 'first-only.dart'},
          ],
        };
      await mountPage(t, link, (tool) => FilesPage(tool: tool), (
        hub,
        host,
      ) async {
        await t.pumpAndSettle();
        await chooseDirectory(t, '切换目录', '/second');
        await t.enterText(find.byType(TextField), 'query');
        await t.pump(const Duration(milliseconds: 350));
        await t.pumpAndSettle();
        expect(find.text('搜索结果未全部返回，请输入更具体的文件名或路径。'), findsOneWidget);
        expect(find.text('first-only.dart'), findsNothing);
      });
    },
  );

  testWidgets(
    'file directory follows its path when reconnect changes root order',
    (t) async {
      final link = DirectoryReadLink();
      await mountPage(t, link, (tool) => FilesPage(tool: tool), (
        hub,
        host,
      ) async {
        await t.pumpAndSettle();
        await chooseDirectory(t, '切换目录', '/second');
        await t.runAsync(() => hub.disconnect(host));
        final replacement = DirectoryReadLink()..paths = ['/second', '/first'];
        await t.runAsync(() => hub.attach(host, replacement));
        await t.pumpAndSettle();
        expect(find.text('目录 · second'), findsOneWidget);
        expect(replacement.reads.last['root'], 0);
      });
    },
  );

  testWidgets(
    'identical run names in different directories launch only the selected directory',
    (t) async {
      await t.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => t.binding.setSurfaceSize(null));
      final link = ToolsLink();
      for (final directory in link.catalog['directories'] as List) {
        directory['commands'][0]['label'] = '启动服务';
      }
      await mountRun(t, link, (hub, host) async {
        expect(find.text('目录 · 0'), findsOneWidget);
        await chooseDirectory(t, '选择运行目录', '/fixture/1');
        expect(find.text('目录 · 1'), findsOneWidget);
        await t.tap(find.byTooltip('选择运行配置'));
        await t.pumpAndSettle();
        expect(
          find.byType(PopupMenuItem<({int dir, String id})>),
          findsOneWidget,
        );
        await t.tap(find.text('启动服务').last);
        await t.pumpAndSettle();
        await t.tap(find.byTooltip('启动'));
        await t.pumpAndSettle();
        expect(link.writes.single['directoryIndex'], 1);
        expect(link.writes.single['commandId'], 'same');
      });
    },
  );

  testWidgets(
    'empty run directories stay selected through polling and clear previous output',
    (t) async {
      final link = ToolsLink()..active = true;
      link.catalog['directories'][1]['commands'] = [];
      await mountRun(t, link, (hub, host) async {
        expect(find.byTooltip('停止'), findsOneWidget);
        await chooseDirectory(t, '选择运行目录', '/fixture/1');
        await t.pump(const Duration(seconds: 3));
        await t.pumpAndSettle();
        expect(find.text('目录 · 1'), findsOneWidget);
        expect(find.textContaining('当前目录还没有运行配置'), findsOneWidget);
        expect(find.byTooltip('启动'), findsNothing);
        expect(find.byTooltip('停止'), findsNothing);
        expect(find.text('First directory'), findsNothing);
        expect(link.writes, isEmpty);
        expect(link.stopCalls, isEmpty);
      });
    },
  );

  testWidgets('run selection survives catalog reordering by path', (t) async {
    final link = ToolsLink();
    await mountRun(t, link, (hub, host) async {
      await chooseDirectory(t, '选择运行目录', '/fixture/1');
      link.catalog['directories'] = (link.catalog['directories'] as List)
          .reversed
          .toList();
      await t.tap(find.byTooltip('刷新运行配置'));
      await t.pumpAndSettle();
      expect(find.text('目录 · 1'), findsOneWidget);
      await t.tap(find.byTooltip('启动'));
      await t.pumpAndSettle();
      expect(link.writes.single['directoryIndex'], 0);
    });
  });
}
