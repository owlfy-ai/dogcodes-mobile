import 'package:dogcodes_app/app.dart';
import 'package:dogcodes_app/features/conversation/computer_use_banner.dart';
import 'package:dogcodes_app/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'widget_test.dart';

/// A computer with one server (remote host) and an Agent using its screen.
class ServerLink extends FakeLink {
  ServerLink() : super('macbook-pro-host');
  final asked = <(String, dynamic)>[];
  String phase = 'failed';
  bool using = true;

  @override
  Future<dynamic> call(String method, dynamic params) async {
    asked.add((method, params));
    switch (method) {
      case 'remote_hosts':
        return [
          {
            'targetId': 'tgt_build',
            'name': 'build-box',
            'phase': phase,
            'scanning': false,
            'needsInput': false,
            'error': phase == 'failed' ? 'host_unreachable' : null,
          },
        ];
      case 'remote_host_reconnect':
        phase = 'connected';
        return {'started': true};
      case 'computer_use_status':
        return using
            ? {
                'operationId': 'op_1',
                'taskId': 't1',
                'tool': 'mcp__computer__click',
                'mode': 'foreground',
                'preparing': false,
              }
            : {'mode': 'idle'};
      case 'computer_use_stop':
        using = false;
        return {'accepted': params == 'op_1'};
      case 'bootstrap':
        final snapshot = Map<String, dynamic>.from(
          await super.call(method, params) as Map,
        );
        snapshot['projects'] = [
          ...snapshot['projects'] as List,
          {
            'projectId': 'p2',
            'displayName': 'api',
            'path': '/srv/api',
            'targetId': 'tgt_build',
            'taskCount': 0,
          },
        ];
        return snapshot;
    }
    return super.call(method, params);
  }
}

void main() {
  testWidgets(
    'servers show their state and can be reconnected from the phone',
    (tester) async {
      final link = ServerLink();
      final hub = fakeHub(link);
      await tester.pumpWidget(DogCodesApp(hub: hub));
      await tester.pumpAndSettle();
      await tester.tap(find.text('电脑').last);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('build-box'), 200);
      expect(find.text('远程主机'), findsOneWidget);
      expect(find.text('无法访问服务器'), findsOneWidget);

      await tester.tap(find.widgetWithText(OutlinedButton, '重新连接').last);
      // The hub checks back after 2, 5 and 10 seconds.
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(link.asked, contains(('remote_host_reconnect', 'tgt_build')));
      expect(find.text('已连接'), findsOneWidget);
      final h = hub.hosts.single;
      expect(h.serverName(h.project('p2')), 'build-box');
      expect(h.serverName(h.project('p1')), isNull);
      expect(h.placeName(h.project('p2')), 'build-box');
      await tester.pumpWidget(const SizedBox());
      hub.dispose();
    },
  );

  testWidgets('an Agent using the computer can be stopped from the phone', (
    tester,
  ) async {
    final link = ServerLink();
    final hub = fakeHub(link);
    await hub.load();
    final host = hub.hosts.single;
    await tester.pumpWidget(
      MaterialApp(
        theme: dcTheme(Brightness.light),
        home: Scaffold(
          body: ComputerUseBanner(
            host: host,
            taskId: 't1',
            running: true,
            interval: const Duration(milliseconds: 500),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('电脑操作'), findsOneWidget);
    expect(find.text('前台 · 点击'), findsOneWidget);

    await tester.tap(find.text('停止电脑操作'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(link.asked, contains(('computer_use_stop', 'op_1')));
    expect(find.text('已停止电脑操作'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('电脑操作'), findsNothing);

    // Another conversation's activity is not shown here.
    link.using = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ComputerUseBanner(host: host, taskId: 't2', running: true),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('电脑操作'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    hub.dispose();
  });
}
