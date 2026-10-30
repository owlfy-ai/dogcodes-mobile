import 'dart:convert';
import 'package:dogcodes_app/core/mobile_operations.dart';
import 'package:dogcodes_app/features/inbox/pending_operation.dart';
import 'package:dogcodes_app/features/inbox/pending_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/app.dart';
import 'package:dogcodes_app/core/preferences.dart';
import 'package:dogcodes_app/ui/theme.dart';
import 'package:dogcodes_app/core/protocol.dart';
import 'package:dogcodes_app/features/tools/run_page.dart';
import 'package:dogcodes_app/features/tools/terminal_page.dart';
import 'package:dogcodes_app/features/tools/tool_context.dart';
import 'widget_test.dart' show FakeLink, fakeHub;

class ToolsLink extends FakeLink {
  ToolsLink() : super('macbook-pro-host');
  bool active = false, stopFails = false, plainTerminal = false;
  final writes = <Map<String, dynamic>>[];
  final reads = <List<dynamic>>[];
  final stopCalls = <Map<String, dynamic>>[];
  Map<String, dynamic>? receipt, launch;
  final catalog = <String, dynamic>{
    'projectId': 'p1',
    'generation': 'generation',
    'directories': [
      for (var i = 0; i < 2; i++)
        {
          'path': '/fixture/$i',
          'status': 'ready',
          'userModified': true,
          'commands': [
            {
              'id': 'same',
              'label': i == 0 ? 'First directory' : 'Second directory',
              'command': 'echo fixture',
              'pinned': false,
            },
          ],
        },
    ],
  };
  Map<String, dynamic> get terminal => {
    'id': 'existing',
    'epoch': 'epoch',
    'projectId': 'p1',
    'taskId': plainTerminal ? null : 't2',
    'directoryIndex': 0,
    'commandId': plainTerminal ? null : 'same',
    'status': active ? 'running' : 'exited',
    'createdAt': 1,
    'label': 'Fixture',
    'cwd': '/fixture',
  };
  @override
  Future<dynamic> call(String method, dynamic args) async {
    if (method == 'remote_capabilities') {
      return {
        'terminalLaunchRecovery': true,
        'terminalStopEpoch': true,
        'runOperationRequest': true,
      };
    }
    if (method == 'project_runs') return jsonDecode(jsonEncode(catalog));
    if (method == 'terminal_list') {
      return active || plainTerminal ? [terminal] : [];
    }
    if (method == 'terminal_read') {
      reads.add(List.of(args as List));
      return {'bytes': <int>[], 'next': '0', 'info': terminal};
    }
    if (method == 'terminal_get') {
      if (args != 'existing') {
        throw const ProtocolException('终端不存在或属于已清除的后台实例');
      }
      return terminal;
    }
    if (method == 'terminal_stop') {
      stopCalls.add({
        'type': 'execute',
        'request': Map<String, dynamic>.from(args as Map),
      });
      if (stopFails) throw const ProtocolException('网络中断，停止结果待核实');
      if (args['expectedEpoch'] == terminal['epoch']) active = false;
      return terminal;
    }
    if (method == 'project_run_edit') {
      final request = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(args)) as Map,
      );
      writes.add(request);
      catalog['directories'][request['directoryIndex']]['commands'][0]['label'] =
          request['edit']['label'];
      receipt = {
        'operationId': request['operationId'],
        'request': request,
        'generation': 'generation',
        'status': 'succeeded',
        'error': null,
      };
      return {'Ok': catalog};
    }
    if (method == 'project_run_operation') return receipt;
    if (method == 'project_run_start') {
      final request = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(args)) as Map,
      );
      writes.add(request);
      launch = {
        'operationId': args['operationId'],
        'state': 'accepted',
        'intent': {'projectLaunch': request},
        'terminal': {
          'id': args['operationId'],
          'projectId': 'p1',
          'status': 'exited',
        },
      };
      return launch!['terminal'];
    }
    if (method == 'terminal_launch_intents') return launch;
    return super.call(method, args);
  }
}

void main() {
  testWidgets(
    'phone can rename a run configuration through the durable operation path',
    (t) async {
      final link = ToolsLink(), hub = fakeHub();
      await hub.load(connect: false);
      await hub.attach(hub.hosts.single, link);
      final host = hub.hosts.single, prefs = AppPreferences();
      await t.pumpWidget(
        AppScope(
          hub: hub,
          preferences: prefs,
          runtime: null,
          client: null,
          child: MaterialApp(
            theme: dcTheme(Brightness.light),
            home: RunPage(tool: ToolContext(host, host.projects.single)),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('管理运行配置'));
      await t.pumpAndSettle();
      await t.tap(find.text('重命名'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), 'Renamed run');
      await t.tap(find.text('保存'));
      await t.pumpAndSettle();
      expect(find.text('Renamed run'), findsOneWidget);
      expect(link.writes.single['edit']['label'], 'Renamed run');
      expect(await host.operations.pending(), isNull);
      await t.pumpWidget(const SizedBox());
      hub.dispose();
      prefs.dispose();
    },
  );
  testWidgets(
    'identical command IDs in different roots launch the chosen directory',
    (t) async {
      final link = ToolsLink(), hub = fakeHub();
      await hub.load(connect: false);
      await hub.attach(hub.hosts.single, link);
      final host = hub.hosts.single, prefs = AppPreferences();
      await t.pumpWidget(
        AppScope(
          hub: hub,
          preferences: prefs,
          runtime: null,
          client: null,
          child: MaterialApp(
            theme: dcTheme(Brightness.light),
            home: RunPage(tool: ToolContext(host, host.projects.single)),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('选择运行目录'));
      await t.pumpAndSettle();
      await t.tap(
        find.ancestor(
          of: find.text('/fixture/1'),
          matching: find.byType(CheckedPopupMenuItem<int>),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('启动'));
      await t.pumpAndSettle();
      expect(link.writes.single['directoryIndex'], 1);
      expect(link.writes.single['commandId'], 'same');
      await t.pumpWidget(const SizedBox());
      hub.dispose();
      prefs.dispose();
    },
  );

  testWidgets(
    'restart starts a new recipe only after the frozen stop exit proof',
    (t) async {
      final link = ToolsLink()..active = true, hub = fakeHub();
      await hub.load(connect: false);
      await hub.attach(hub.hosts.single, link);
      final host = hub.hosts.single, prefs = AppPreferences();
      await t.pumpWidget(
        AppScope(
          hub: hub,
          preferences: prefs,
          runtime: null,
          client: null,
          child: MaterialApp(
            theme: dcTheme(Brightness.light),
            home: RunPage(tool: ToolContext(host, host.projects.single)),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('重启'));
      await t.pumpAndSettle();
      expect(link.stopCalls.where((r) => r['type'] == 'execute').length, 1);
      expect(link.stopCalls.first['request']['terminalId'], 'existing');
      expect(link.stopCalls.first['request']['expectedEpoch'], 'epoch');
      expect(link.writes.single['commandId'], 'same');
      expect(await host.operations.pending(), isNull);
      await t.pumpWidget(const SizedBox());
      hub.dispose();
      prefs.dispose();
    },
  );
  testWidgets('terminal close waits for a receipt and clears its own session', (
    t,
  ) async {
    final link = ToolsLink()
          ..active = true
          ..plainTerminal = true,
        hub = fakeHub();
    await hub.load(connect: false);
    await hub.attach(hub.hosts.single, link);
    final host = hub.hosts.single, prefs = AppPreferences();
    await t.pumpWidget(
      AppScope(
        hub: hub,
        preferences: prefs,
        runtime: null,
        client: null,
        child: MaterialApp(
          theme: dcTheme(Brightness.light),
          home: TerminalPage(tool: ToolContext(host, host.projects.single)),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('关闭当前终端'));
    await t.pumpAndSettle();
    await t.tap(find.text('关闭终端'));
    await t.pumpAndSettle();
    expect(link.stopCalls.single['type'], 'execute');
    expect(link.active, false);
    expect(await host.operations.pending(), isNull);
    await t.pumpWidget(const SizedBox());
    hub.dispose();
    prefs.dispose();
  });
  testWidgets(
    'changing a route while close confirmation is open requires a fresh confirmation',
    (t) async {
      final old = ToolsLink()
            ..active = true
            ..plainTerminal = true,
          hub = fakeHub();
      await hub.load(connect: false);
      await hub.attach(hub.hosts.single, old);
      final host = hub.hosts.single, prefs = AppPreferences();
      await t.pumpWidget(
        AppScope(
          hub: hub,
          preferences: prefs,
          runtime: null,
          client: null,
          child: MaterialApp(
            theme: dcTheme(Brightness.light),
            home: TerminalPage(tool: ToolContext(host, host.projects.single)),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('关闭当前终端'));
      await t.pumpAndSettle();
      final next = ToolsLink()
        ..active = true
        ..plainTerminal = true;
      await t.runAsync(() => hub.attach(host, next));
      await t.pumpAndSettle();
      await t.tap(find.text('关闭终端'));
      await t.pumpAndSettle();
      expect(old.stopCalls, isEmpty);
      expect(next.stopCalls, isEmpty);
      expect(find.text('连接已改变，请刷新后重新确认关闭。'), findsOneWidget);
      expect(await host.operations.pending(), isNull);
      await t.pumpWidget(const SizedBox());
      hub.dispose();
      prefs.dispose();
    },
  );
  testWidgets('a failed stop never starts a second process during restart', (
    t,
  ) async {
    final link = ToolsLink()
          ..active = true
          ..stopFails = true,
        hub = fakeHub();
    await hub.load(connect: false);
    await hub.attach(hub.hosts.single, link);
    final host = hub.hosts.single, prefs = AppPreferences();
    await t.pumpWidget(
      AppScope(
        hub: hub,
        preferences: prefs,
        runtime: null,
        client: null,
        child: MaterialApp(
          theme: dcTheme(Brightness.light),
          home: RunPage(tool: ToolContext(host, host.projects.single)),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('重启'));
    await t.pumpAndSettle();
    expect(link.writes, isEmpty);
    expect(find.text('网络中断，停止结果待核实'), findsOneWidget);
    expect(link.stopCalls.single['type'], 'execute');
    expect(
      (await host.operations.pendingTerminalStops()).single['kind'],
      'terminal_stop',
    );
    await t.pumpWidget(const SizedBox());
    hub.dispose();
    prefs.dispose();
  });
  testWidgets(
    'an open terminal reattaches to its original ID after route replacement',
    (t) async {
      final old = ToolsLink()
            ..plainTerminal = true
            ..active = true,
          hub = fakeHub();
      await hub.load(connect: false);
      await hub.attach(hub.hosts.single, old);
      final host = hub.hosts.single, prefs = AppPreferences();
      await t.pumpWidget(
        AppScope(
          hub: hub,
          preferences: prefs,
          runtime: null,
          client: null,
          child: MaterialApp(
            theme: dcTheme(Brightness.light),
            home: TerminalPage(tool: ToolContext(host, host.projects.single)),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(old.reads, isNotEmpty);
      final next = ToolsLink()
        ..plainTerminal = true
        ..active = true;
      await t.runAsync(() => hub.attach(host, next));
      await t.pumpAndSettle();
      expect(next.reads, contains(equals(['existing', '0'])));
      expect(next.writes, isEmpty);
      await t.pumpWidget(const SizedBox());
      hub.dispose();
      prefs.dispose();
    },
  );
  testWidgets(
    'a pending ordinary write does not block closing a terminal and its own card verifies exit on a small phone',
    (t) async {
      await t.binding.setSurfaceSize(const Size(400, 700));
      addTearDown(() => t.binding.setSurfaceSize(null));
      final link = ToolsLink()
            ..plainTerminal = true
            ..active = true
            ..stopFails = true,
          hub = fakeHub();
      await hub.load(connect: false);
      await hub.attach(hub.hosts.single, link);
      final host = hub.hosts.single, prefs = AppPreferences();
      final ordinary = {
        'kind': 'send',
        'request': {
          'operationId': 'pending-send',
          'input': {'prompt': '未确认的消息'},
        },
      };
      await hub.storage.write(host.operations.key, jsonEncode(ordinary));
      await hub.refreshOperation(host);
      await t.pumpWidget(
        AppScope(
          hub: hub,
          preferences: prefs,
          runtime: null,
          client: null,
          child: MaterialApp(
            theme: dcTheme(Brightness.light),
            home: TerminalPage(tool: ToolContext(host, host.projects.single)),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('关闭当前终端'));
      await t.pumpAndSettle();
      await t.tap(find.text('关闭终端'));
      await t.pumpAndSettle();
      expect(link.stopCalls.where((c) => c['type'] == 'execute').length, 1);
      expect(await host.operations.pending(), ordinary);
      expect(host.pendingTerminalStops.length, 1);
      expect(find.text('关闭终端：还没收到电脑确认'), findsOneWidget);
      expect(t.takeException(), isNull);
      final saved = host.pendingTerminalStops.single;
      await expectLater(
        host.operations.terminalStop(link, {
          ...link.terminal,
          'id': 'other-terminal',
          'label': 'Other terminal',
        }),
        throwsA(isA<ProtocolException>()),
      );
      await hub.refreshOperation(host);
      await t.pumpAndSettle();
      expect(host.pendingTerminalStops.length, 2);
      link.active = false;
      final card = find.byWidgetPredicate(
        (w) =>
            w is PendingOperationCard &&
            w.operation?['request']?['operationId'] ==
                saved['request']['operationId'],
      );
      final verify = find.descendant(of: card, matching: find.text('重新确认'));
      await t.ensureVisible(verify);
      await t.tap(verify);
      await t.pumpAndSettle();
      expect(
        host.pendingTerminalStops.single['request']['terminalId'],
        'other-terminal',
      );
      expect(await host.operations.pending(), ordinary);
      expect(link.stopCalls.where((c) => c['type'] == 'execute').length, 2);
      expect(t.takeException(), isNull);
      await t.pumpWidget(
        AppScope(
          hub: hub,
          preferences: prefs,
          runtime: null,
          client: null,
          child: MaterialApp(
            theme: dcTheme(Brightness.light),
            home: const Scaffold(body: PendingPage()),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('关闭终端：还没收到电脑确认'), findsOneWidget);
      expect(find.text('发送消息：还没收到电脑确认'), findsOneWidget);
      expect(hub.pendingCount, greaterThanOrEqualTo(2));
      await t.pumpWidget(const SizedBox());
      hub.dispose();
      prefs.dispose();
    },
  );
}
