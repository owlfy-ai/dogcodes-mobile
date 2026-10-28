import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/features/tools/terminal_page.dart';
import 'workspace_read_pages_test.dart' show ReadLink, mountPage;

class DirectoryLink extends ReadLink {
  DirectoryLink() : super('terminal');
  List<String> paths = ['/project/frontend', '/project/backend'];
  final terminals = <String, Map<String, dynamic>>{};
  final launches = <String, Map<String, dynamic>>{};
  final starts = <Map<String, dynamic>>[];
  final reads = <String>[];
  Completer<dynamic>? listing;
  Map<String, dynamic> terminal(String id) => {
    'id': id,
    'epoch': 'epoch-$id',
    'projectId': 'p1',
    'taskId': null,
    'directoryIndex': 1,
    'commandId': null,
    'label': '终端',
    'cwd': paths.last,
    'status': 'running',
    'createdAt': 1,
  };
  @override
  Future<dynamic> call(String method, dynamic args) async {
    if (method == 'bootstrap') {
      final snapshot = await super.call(method, args) as Map;
      final project = (snapshot['projects'] as List).single as Map;
      project['path'] = paths.first;
      project['additionalDirectories'] = paths.skip(1).toList();
      return snapshot;
    }
    if (method == 'remote_capabilities') {
      return {'terminalLaunchRecovery': true};
    }
    if (method == 'terminal_list') {
      return listing?.future ?? terminals.values.toList();
    }
    if (method == 'terminal_start') {
      final request = Map<String, dynamic>.from(args as Map);
      starts.add(request);
      final id = request['operationId'] as String;
      terminals[id] = {
        ...terminal(id),
        'cwd': request['cwd'],
        'directoryIndex': request['directoryIndex'],
      };
      launches[id] = {
        'operationId': id,
        'state': 'accepted',
        'intent': request,
        'terminal': terminals[id],
      };
      return terminals[id];
    }
    if (method == 'terminal_launch_intents') {
      return launches[args['operationId']];
    }
    if (method == 'terminal_read') {
      final id = args[0] as String;
      reads.add(id);
      return {'bytes': <int>[], 'next': '0', 'info': terminals[id]};
    }
    if (method == 'terminal_get') return terminals[args];
    return super.call(method, args);
  }
}

Future<void> chooseBackend(WidgetTester t) async {
  await t.tap(
    find.ancestor(
      of: find.text('/project/backend'),
      matching: find.byType(ListTile),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  testWidgets(
    'a phone starts a terminal in the chosen additional directory and reconnects to the same ID',
    (t) async {
      final link = DirectoryLink();
      await mountPage(t, link, (tool) => TerminalPage(tool: tool), (
        hub,
        host,
      ) async {
        await t.pumpAndSettle();
        await t.tap(find.byTooltip('新建终端'));
        await t.pumpAndSettle();
        expect(find.text('选择终端目录'), findsOneWidget);
        await chooseBackend(t);
        final request = link.starts.single;
        expect(request['cwd'], '/project/backend');
        expect(request['directoryIndex'], 1);
        expect(find.text('backend · 1'), findsOneWidget);
        expect(link.reads.toSet(), {request['operationId']});
        final next = DirectoryLink();
        next.terminals.addAll(link.terminals);
        await t.runAsync(() => hub.attach(host, next));
        await t.pumpAndSettle();
        expect(next.starts, isEmpty);
        expect(next.reads.toSet(), {request['operationId']});
        expect(find.text('backend · 1'), findsOneWidget);
        expect(await host.operations.sidePending(), isNull);
      });
    },
  );

  testWidgets(
    'project directories changed during selection require choosing again',
    (t) async {
      final link = DirectoryLink();
      await mountPage(t, link, (tool) => TerminalPage(tool: tool), (
        hub,
        host,
      ) async {
        await t.pumpAndSettle();
        await t.tap(find.byTooltip('新建终端'));
        await t.pumpAndSettle();
        link.paths = ['/project/frontend', '/project/replacement'];
        await hub.refresh(host);
        await chooseBackend(t);
        expect(find.text('连接或项目目录已改变，请重新选择终端目录。'), findsOneWidget);
        expect(link.starts, isEmpty);
        expect(await host.operations.sidePending(), isNull);
      });
    },
  );

  testWidgets(
    'a directory selection from a retired connection cannot start a terminal',
    (t) async {
      final link = DirectoryLink();
      await mountPage(t, link, (tool) => TerminalPage(tool: tool), (
        hub,
        host,
      ) async {
        await t.pumpAndSettle();
        await t.tap(find.byTooltip('新建终端'));
        await t.pumpAndSettle();
        final next = DirectoryLink();
        await t.runAsync(() => hub.attach(host, next));
        await t.pumpAndSettle();
        await chooseBackend(t);
        expect(link.starts, isEmpty);
        expect(next.starts, isEmpty);
        expect(find.text('连接或项目目录已改变，请重新选择终端目录。'), findsOneWidget);
        expect(await host.operations.sidePending(), isNull);
      });
    },
  );

  testWidgets(
    'reconnection waits for the terminal list before attaching an old selection',
    (t) async {
      final link = DirectoryLink();
      link.terminals['kept'] = link.terminal('kept');
      await mountPage(t, link, (tool) => TerminalPage(tool: tool), (
        hub,
        host,
      ) async {
        await t.pumpAndSettle();
        expect(link.reads.toSet(), {'kept'});
        final next = DirectoryLink()..listing = Completer<dynamic>();
        next.terminals.addAll(link.terminals);
        await t.runAsync(() => hub.attach(host, next));
        await t.pump();
        expect(next.reads, isEmpty);
        expect(next.starts, isEmpty);
        next.listing!.complete(next.terminals.values.toList());
        await t.pumpAndSettle();
        expect(next.reads.toSet(), {'kept'});
        expect(next.starts, isEmpty);
      });
    },
  );
}
