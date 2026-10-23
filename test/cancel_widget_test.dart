import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/app.dart';
import 'package:dogcodes_app/core/mobile_operations.dart';
import 'widget_test.dart' show FakeLink, fakeHub;
import 'cancel_writes_test.dart' show CancelApi;

// An active Agent intentionally animates; settling the whole app cannot end.
Future<void> advance(WidgetTester t) async {
  await t.pump(const Duration(milliseconds: 350));
  for (var i = 0; i < 16; i++) {
    await t.pump(const Duration(milliseconds: 16));
  }
}

Future<void> waitForTask(WidgetTester t) async {
  for (var i = 0; i < 60; i++) {
    if (find.text('修复移动端布局').evaluate().isNotEmpty) return;
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 2)),
    );
    await t.pump(const Duration(milliseconds: 20));
  }
  expect(find.text('修复移动端布局'), findsOneWidget);
}

class RunningSession extends FakeLink {
  RunningSession() : super('macbook-pro-host');
  final api = CancelApi();
  @override
  Future<dynamic> call(String method, dynamic args) async {
    if ((method == 'execute' || method == 'command_receipt') &&
        args[0]['payload']['type'] == 'cancel_turn') {
      return api.call(method, args);
    }
    final result = await super.call(method, args);
    if (method == 'bootstrap') {
      final task = (result['tasks'] as List).singleWhere(
        (t) => t['taskId'] == 't2',
      );
      task['activePrimaryRun'] = {
        'runId': 'run-a',
        'turnId': 'turn-a',
        'state': 'running',
      };
    }
    return result;
  }
}

void main() {
  testWidgets(
    'conversation Stop persists a lost request and verifies its acceptance once',
    (t) async {
      final link = RunningSession();
      link.api.loseAfter = true;
      final hub = fakeHub(link);
      try {
        await t.pumpWidget(DogCodesApp(hub: hub));
        await advance(t);
        await waitForTask(t);
        await t.tap(find.text('修复移动端布局'));
        await advance(t);
        await t.tap(find.byTooltip('停止'));
        await advance(t);
        expect(find.text('停止任务：还没收到电脑确认'), findsOneWidget);
        expect(link.api.writes.length, 1);
        await t.tap(find.text('重新确认'));
        await advance(t);
        expect(await hub.hosts.single.operations.pendingCancellation(), isNull);
        expect(link.api.writes.length, 1);
      } finally {
        await t.pumpWidget(const SizedBox());
        hub.dispose();
        await t.pump();
      }
    },
  );
  testWidgets('not waiting for an unknown Stop only clears the phone record', (
    t,
  ) async {
    final link = RunningSession();
    link.api.loseBefore = true;
    final hub = fakeHub(link);
    try {
      await t.pumpWidget(DogCodesApp(hub: hub));
      await advance(t);
      await waitForTask(t);
      await t.tap(find.text('修复移动端布局'));
      await advance(t);
      await t.tap(find.byTooltip('停止'));
      await advance(t);
      expect(find.text('停止任务：还没收到电脑确认'), findsOneWidget);
      final calls = link.api.calls.length;
      await t.tap(find.text('不再等待'));
      await advance(t);
      await t.tap(find.text('确定'));
      await advance(t);
      expect(await hub.hosts.single.operations.pendingCancellation(), isNull);
      expect(link.api.calls.length, calls);
      expect(link.api.writes.length, 1);
    } finally {
      await t.pumpWidget(const SizedBox());
      hub.dispose();
      await t.pump();
    }
  });
  testWidgets(
    'a pending ordinary write does not block Stop on a small conversation screen',
    (t) async {
      t.view.physicalSize = const Size(400, 700);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final link = RunningSession();
      link.api.loseBefore = true;
      final hub = fakeHub(link);
      try {
        await t.pumpWidget(DogCodesApp(hub: hub));
        await advance(t);
        await waitForTask(t);
        await t.tap(find.text('修复移动端布局'));
        await advance(t);
        final host = hub.hosts.single;
        final main = {
          'kind': 'send',
          'request': {
            'operationId': 'ordinary',
            'input': {'prompt': '未确认的消息'},
          },
        };
        await host.operations.storage.write(
          host.operations.key,
          jsonEncode(main),
        );
        await hub.refreshOperation(host);
        await advance(t);
        await t.tap(find.byTooltip('停止'));
        await advance(t);
        expect(link.api.writes.length, 1);
        expect(await host.operations.pending(), main);
        expect((await host.operations.pendingCancellations()).length, 1);
        expect(hub.pendingCount, greaterThanOrEqualTo(2));
        expect(t.takeException(), isNull);
      } finally {
        await t.pumpWidget(const SizedBox());
        hub.dispose();
        await t.pump();
      }
    },
  );
}
