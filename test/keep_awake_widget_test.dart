import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/app.dart';
import 'package:dogcodes_app/core/preferences.dart';
import 'package:dogcodes_app/core/protocol.dart';
import 'package:dogcodes_app/features/computers/keep_awake.dart';
import 'package:dogcodes_app/ui/theme.dart';
import 'widget_test.dart' show FakeLink, fakeHub;
import 'power_writes_test.dart' show PowerApi;

class PowerLink extends FakeLink {
  PowerLink() : super('macbook-pro-host');
  final power = PowerApi();
  bool failRead = false;
  Completer<dynamic>? readGate, writeGate;
  @override
  Future<dynamic> call(String method, dynamic args) async {
    if (method == 'power_preferences') {
      if (failRead) throw const ProtocolException('设置暂时无法读取');
      return readGate?.future ?? power.call(method, args);
    }
    if (method == 'power_preferences_set') {
      if (writeGate != null) return writeGate!.future;
      return power.call(method, args);
    }
    return super.call(method, args);
  }
}

class Rig {
  final hub = fakeHub(), prefs = AppPreferences();
  Future<void> open(WidgetTester t, PowerLink link) async {
    await hub.load(connect: false);
    await hub.attach(hub.hosts.single, link);
    await t.pumpWidget(
      AppScope(
        hub: hub,
        preferences: prefs,
        runtime: null,
        client: null,
        child: MaterialApp(
          theme: dcTheme(Brightness.light),
          home: Scaffold(
            body: ListenableBuilder(
              listenable: hub,
              builder: (_, _) => KeepAwake(host: hub.hosts.single),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
  }

  SwitchListTile value(WidgetTester t) =>
      t.widget<SwitchListTile>(find.byType(SwitchListTile));
  Future<void> close(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    hub.dispose();
    prefs.dispose();
  }
}

void main() {
  testWidgets('a failed initial read remains visible and can be retried', (
    t,
  ) async {
    final rig = Rig(), link = PowerLink()..failRead = true;
    await rig.open(t, link);
    expect(find.text('设置暂时无法读取'), findsOneWidget);
    expect(rig.value(t).onChanged, isNull);
    link.failRead = false;
    await t.tap(find.byTooltip('刷新保持唤醒设置'));
    await t.pumpAndSettle();
    expect(rig.value(t).value, true);
    expect(rig.value(t).onChanged, isNotNull);
    await rig.close(t);
  });
  testWidgets(
    'late read on an old route cannot replace the reconnected value',
    (t) async {
      final rig = Rig(), old = PowerLink()..readGate = Completer<dynamic>();
      await rig.open(t, old);
      final next = PowerLink();
      next.power.enabled = false;
      await t.runAsync(() => rig.hub.attach(rig.hub.hosts.single, next));
      await t.pumpAndSettle();
      expect(rig.value(t).value, false);
      old.readGate!.complete({'enabled': true, 'active': false});
      await t.pumpAndSettle();
      expect(rig.value(t).value, false);
      await rig.close(t);
    },
  );
  testWidgets('the switch sets the value and shows what the PC confirmed', (
    t,
  ) async {
    final rig = Rig(), link = PowerLink();
    await rig.open(t, link);
    await t.tap(find.byType(SwitchListTile));
    await t.pumpAndSettle();
    expect(link.power.enabled, false);
    expect(rig.value(t).value, false);
    expect(find.textContaining('还没收到电脑确认'), findsNothing);
    await rig.close(t);
  });
  testWidgets('a lost reply is settled by reading the value back', (t) async {
    final rig = Rig(), link = PowerLink();
    link.power.loseAfter = true;
    await rig.open(t, link);
    await t.tap(find.byType(SwitchListTile));
    await t.pumpAndSettle();
    expect(rig.value(t).value, false);
    expect(rig.value(t).onChanged, isNotNull);
    await rig.close(t);
  });
  testWidgets('a setting that never arrived says so and can be retried', (
    t,
  ) async {
    final rig = Rig(), link = PowerLink();
    link.power.loseBefore = true;
    await rig.open(t, link);
    await t.tap(find.byType(SwitchListTile));
    await t.pumpAndSettle();
    expect(find.text('电脑没有收到这次设置，请再试一次。'), findsOneWidget);
    expect(rig.value(t).value, true);
    link.power.loseBefore = false;
    await t.tap(find.byType(SwitchListTile));
    await t.pumpAndSettle();
    expect(rig.value(t).value, false);
    await rig.close(t);
  });
  testWidgets(
    'a late write response cannot overwrite state read from a newer route',
    (t) async {
      final rig = Rig(), old = PowerLink()..writeGate = Completer<dynamic>();
      await rig.open(t, old);
      await t.tap(find.byType(SwitchListTile));
      await t.pumpAndSettle();
      final next = PowerLink();
      await t.runAsync(() => rig.hub.attach(rig.hub.hosts.single, next));
      await t.pumpAndSettle();
      expect(rig.value(t).value, true);
      old.writeGate!.complete({'enabled': false, 'active': false});
      await t.pumpAndSettle();
      expect(rig.value(t).value, true);
      await rig.close(t);
    },
  );
}
