import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/app.dart';
import 'package:dogcodes_app/core/host_hub.dart';
import 'package:dogcodes_app/core/preferences.dart';
import 'package:dogcodes_app/ui/theme.dart';
import 'package:dogcodes_app/features/settings/notification_settings_page.dart';
import 'notification_settings_test.dart' show NotificationFixture;

Future<void> mountNotifications(
  WidgetTester t,
  NotificationFixture fixture,
  Future<void> Function(HostHub hub, HostState host) body, {
  String? taskId,
}) async {
  await fixture.init();
  final hub = HostHub(storage: fixture.storage, lister: fixture.hosts.list);
  final preferences = AppPreferences();
  await hub.load(connect: false);
  final host = hub.hosts.single;
  host.snapshot = {
    'tasks': [
      {'taskId': 't1', 'title': 'Current task'},
      {'taskId': 'other-task', 'title': 'Other task'},
    ],
  };
  await t.pumpWidget(
    AppScope(
      hub: hub,
      preferences: preferences,
      runtime: null,
      client: null,
      child: MaterialApp(
        theme: dcTheme(Brightness.light),
        home: NotificationSettingsPage(
          host: host,
          taskId: taskId,
          api: fixture.api,
        ),
      ),
    ),
  );
  await t.pump();
  try {
    await body(hub, host);
  } finally {
    await t.pumpWidget(const SizedBox());
    hub.dispose();
    preferences.dispose();
  }
}

SwitchListTile switchFor(WidgetTester t, String label) =>
    t.widget<SwitchListTile>(
      find.ancestor(
        of: find.text(label),
        matching: find.byType(SwitchListTile),
      ),
    );

void main() {
  testWidgets(
    'computer mute and kinds are saved while PC is offline without clearing other preferences',
    (t) async {
      final fixture = NotificationFixture();
      await mountNotifications(t, fixture, (hub, host) async {
        await t.pumpAndSettle();
        expect(host.online, isFalse);
        expect(switchFor(t, '静音这台电脑').onChanged, isNotNull);
        expect(find.textContaining('后台提醒暂未启用'), findsOneWidget);
        await t.tap(find.text('静音这台电脑'));
        await t.pumpAndSettle();
        expect(switchFor(t, '静音这台电脑').value, isTrue);
        await t.tap(find.text('任务完成'));
        await t.pumpAndSettle();
        expect(switchFor(t, '任务完成').value, isFalse);
        final put =
            fixture.calls.lastWhere((c) => c['method'] == 'PUT')['body'] as Map;
        expect(put['muted'], isTrue);
        expect(put['mutedTasks'], ['other-task']);
        expect(put['enabledKinds'], ['approval', 'failed', 'question']);
        expect(put['expectedRevision'], '9007199254740994');
      });
    },
  );

  testWidgets(
    'session mute preserves computer mute and other sessions and can be undone',
    (t) async {
      final fixture = NotificationFixture()..value['muted'] = true;
      await mountNotifications(t, fixture, (hub, host) async {
        await t.pumpAndSettle();
        expect(find.textContaining('这台电脑已静音'), findsOneWidget);
        await t.tap(find.text('静音此会话'));
        await t.pumpAndSettle();
        expect(switchFor(t, '静音此会话').value, isTrue);
        expect(fixture.value['mutedTasks'], ['other-task', 't1']);
        await t.tap(find.text('静音此会话'));
        await t.pumpAndSettle();
        expect(switchFor(t, '静音此会话').value, isFalse);
        expect(fixture.value['mutedTasks'], ['other-task']);
        expect(fixture.value['muted'], isTrue);
      }, taskId: 't1');
    },
  );

  testWidgets(
    'lost save acknowledgement reads the value once and never repeats PUT',
    (t) async {
      final fixture = NotificationFixture()..loseAfter = true;
      await mountNotifications(t, fixture, (hub, host) async {
        await t.pumpAndSettle();
        await t.tap(find.text('静音这台电脑'));
        await t.pumpAndSettle();
        expect(switchFor(t, '静音这台电脑').value, isTrue);
        expect(find.textContaining('未确认'), findsNothing);
        expect(fixture.calls.map((c) => c['method']), ['GET', 'PUT', 'GET']);
      });
    },
  );

  testWidgets(
    'conflict reloads authoritative settings instead of merging stale preferences',
    (t) async {
      final fixture = NotificationFixture();
      await mountNotifications(t, fixture, (hub, host) async {
        await t.pumpAndSettle();
        fixture.conflict = true;
        fixture.value = {
          ...fixture.value,
          'revision': '9007199254740994',
          'muted': true,
          'enabledKinds': ['failed'],
        };
        await t.tap(find.text('任务完成'));
        await t.pumpAndSettle();
        expect(switchFor(t, '静音这台电脑').value, isTrue);
        expect(switchFor(t, '待审批').value, isFalse);
        expect(switchFor(t, '执行失败').value, isTrue);
        expect(find.text('通知设置已改变，请重新读取后修改。'), findsOneWidget);
        expect(fixture.calls.map((c) => c['method']), ['GET', 'PUT', 'GET']);
      });
    },
  );

  testWidgets(
    'unknown save disables editing until a successful explicit read',
    (t) async {
      final fixture = NotificationFixture();
      await mountNotifications(t, fixture, (hub, host) async {
        await t.pumpAndSettle();
        fixture.offline = true;
        await t.tap(find.text('静音这台电脑'));
        await t.pumpAndSettle();
        expect(find.text('保存结果未确认，请检查网络后重新读取。'), findsOneWidget);
        expect(find.byType(SwitchListTile), findsNothing);
        fixture.offline = false;
        await t.tap(find.byTooltip('重新读取'));
        await t.pumpAndSettle();
        expect(switchFor(t, '静音这台电脑').value, isFalse);
        expect(fixture.calls.map((c) => c['method']), [
          'GET',
          'PUT',
          'GET',
          'GET',
        ]);
      });
    },
  );

  testWidgets('forgetting the computer discards a pending notification read', (
    t,
  ) async {
    final gate = Completer<Map<String, dynamic>>();
    final fixture = NotificationFixture()..readGate = gate;
    await mountNotifications(t, fixture, (hub, host) async {
      await t.pump();
      await hub.forget(host);
      await t.pump();
      gate.complete(fixture.value);
      await t.pumpAndSettle();
      expect(find.text('电脑绑定已改变，请返回设备列表。'), findsOneWidget);
      expect(find.byType(SwitchListTile), findsNothing);
      expect(fixture.calls.where((c) => c['method'] == 'PUT'), isEmpty);
    });
  });
}
