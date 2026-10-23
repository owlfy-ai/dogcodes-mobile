import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/core/adaptive_host_link.dart';
import 'package:dogcodes_app/core/host_hub.dart';
import 'package:dogcodes_app/core/security/secret_storage.dart';
import 'package:dogcodes_app/features/computers/remote_desktop_page.dart';
import 'package:dogcodes_app/ui/theme.dart';
import 'desktop_handoff_fixture.dart';
import 'desktop_resource_test.dart' show CountLink;

Future<void> flush(WidgetTester t) async {
  for (var i = 0; i < 16; i++) {
    await t.pump();
  }
}

class Rig {
  final pc = HandoffBroker(), business = CountLink();
  late AdaptiveHostLink routed;
  final disposed = <int>[], decoded = <int, int>{};
  int creates = 0;
  Future<DirectConnection> Function()? dial;
  Completer<int>? creating;
  Completer<void>? decoding;
  Future<void> open(WidgetTester t) async {
    t.view.physicalSize = const Size(400, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    const channel = MethodChannel('dogcodes/h264');
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      final id = (call.arguments as Map?)?['id'] as int?;
      if (call.method == 'create') {
        creates++;
        return creates == 2 ? creating?.future ?? 8 : 6 + creates;
      }
      if (call.method == 'decode') {
        if (id == 8) await decoding?.future;
        decoded[id!] = (decoded[id] ?? 0) + 1;
      }
      if (call.method == 'stats') return {'decoded': decoded[id] ?? 0};
      if (call.method == 'dispose') disposed.add(id!);
      return null;
    });
    addTearDown(
      () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    routed = AdaptiveHostLink(
      relay: business,
      relayDialer: () async => pc.old,
      desktopDialer: (_) async =>
          throw StateError('initial screen ICE unavailable'),
      directDialer: (_) async =>
          dial?.call() ??
          Future.value(DirectConnection(pc.next, ConnectionRoute.direct)),
      retryDelay: const Duration(seconds: 1),
    );
    final host = HostState({'hostId': 'pc'}, MemorySecretStorage())
      ..link = routed
      ..status = LinkStatus.online;
    await t.pumpWidget(
      MaterialApp(
        theme: dcTheme(Brightness.light),
        home: RemoteDesktopPage(host: host),
      ),
    );
    await flush(t);
  }

  Future<void> begin(WidgetTester t) async {
    await t.pump(const Duration(seconds: 1));
    await flush(t);
    await t.pump(const Duration(seconds: 1));
    await flush(t);
  }

  Future<void> leave(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await flush(t);
    unawaited(routed.close());
    await flush(t);
  }
}

void main() {
  testWidgets(
    'migration drains old input, retains old pixels and continues queued input on the new owner',
    (t) async {
      final rig = Rig()
        ..creating = Completer<int>()
        ..decoding = Completer<void>();
      await rig.open(t);
      await rig.begin(t);
      expect(rig.creates, 2);
      expect(rig.pc.phases, ['old:offer', 'new:stage']);
      final input = Completer<void>();
      rig.pc.old.inputGate = input;
      await t.tap(find.byType(Texture));
      await flush(t);
      rig.creating!.complete(8);
      await flush(t);
      expect(rig.pc.phases, isNot(contains('new:claim')));
      expect(t.widget<Texture>(find.byType(Texture)).textureId, 7);
      input.complete();
      await flush(t);
      expect(rig.pc.claimed, true);
      expect(rig.pc.next.inputs, isNotEmpty);
      expect(
        int.parse('${rig.pc.next.inputs.first['sequence']}'),
        greaterThan(int.parse('${rig.pc.old.inputs.last['sequence']}')),
      );
      expect(t.widget<Texture>(find.byType(Texture)).textureId, 7);
      expect(rig.pc.old.closes, 0);
      rig.decoding!.complete();
      await flush(t);
      expect(t.widget<Texture>(find.byType(Texture)).textureId, 8);
      expect(rig.pc.old.closes, 1);
      expect(rig.business.closed, 0);
      expect(find.textContaining('P2P 直连'), findsOneWidget);
      expect(rig.pc.old.opens.length, 1);
      expect(rig.pc.next.opens, isEmpty);
      expect(rig.disposed.where((id) => id == 7).length, 1);
      await rig.leave(t);
      expect(rig.pc.next.closes, 1);
    },
  );
  testWidgets(
    'staged candidate survives loss of the old wire and verifies a lost claim reply',
    (t) async {
      final rig = Rig();
      rig.pc.claiming = Completer<void>();
      rig.pc.loseClaimReply = true;
      await rig.open(t);
      await rig.begin(t);
      expect(rig.creates, 2);
      rig.pc.dropOld();
      await flush(t);
      rig.pc.claiming!.complete();
      await flush(t);
      expect(rig.pc.claimed, true);
      expect(rig.pc.phases.where((p) => p == 'new:claim').length, 1);
      expect(rig.pc.phases, contains('new:status'));
      expect(t.widget<Texture>(find.byType(Texture)).textureId, 8);
      expect(rig.pc.old.opens.length, 1);
      expect(rig.business.closed, 0);
      await rig.leave(t);
    },
  );
  testWidgets(
    'confirmed cancellation retains the old lease and disposes only the candidate',
    (t) async {
      final rig = Rig();
      rig.pc.loseClaimBefore = true;
      await rig.open(t);
      await rig.begin(t);
      expect(rig.pc.claimed, false);
      expect(rig.pc.retired, true);
      expect(t.widget<Texture>(find.byType(Texture)).textureId, 7);
      expect(rig.pc.old.closes, 0);
      expect(rig.pc.next.closes, 1);
      await t.tap(find.byType(Texture));
      await flush(t);
      expect(rig.pc.old.inputs, isNotEmpty);
      expect(rig.pc.next.inputs, isEmpty);
      expect(rig.disposed, contains(8));
      expect(rig.disposed, isNot(contains(7)));
      await rig.leave(t);
    },
  );
  testWidgets(
    'binary credential renewal moves the same lease to a third physical peer',
    (t) async {
      final rig = Rig();
      final third = HandoffLink(rig.pc, true);
      var dials = 0;
      rig.dial = () async => ++dials == 1
          ? DirectConnection(
              rig.pc.next,
              ConnectionRoute.direct,
              expiresAt: DateTime.now().add(const Duration(seconds: 90)),
            )
          : DirectConnection(third, ConnectionRoute.direct);
      await rig.open(t);
      await rig.begin(t);
      expect(t.widget<Texture>(find.byType(Texture)).textureId, 8);
      await t.tap(find.byType(Texture));
      await flush(t);
      final before = rig.pc.inputSequence;
      await t.pump(const Duration(seconds: 31));
      await flush(t);
      expect(dials, 2);
      expect(rig.pc.revision, 2);
      expect(identical(rig.pc.owner, third), true);
      expect(t.widget<Texture>(find.byType(Texture)).textureId, 9);
      expect(rig.pc.next.closes, 1);
      expect(rig.pc.old.closes, 1);
      await t.tap(find.byType(Texture));
      await flush(t);
      expect(rig.pc.inputSequence, greaterThan(before));
      expect(third.inputs, isNotEmpty);
      expect(rig.pc.old.opens.length, 1);
      expect(third.opens, isEmpty);
      expect(rig.business.closed, 0);
      await rig.leave(t);
      expect(third.closes, 1);
    },
  );
  testWidgets(
    'leaving during candidate decoder creation cannot activate or leak it',
    (t) async {
      final rig = Rig()..creating = Completer<int>();
      await rig.open(t);
      await rig.begin(t);
      expect(rig.creates, 2);
      await t.pumpWidget(const SizedBox());
      await flush(t);
      rig.creating!.complete(8);
      await flush(t);
      expect(rig.pc.phases, isNot(contains('new:claim')));
      expect(rig.pc.next.closes, 1);
      expect(rig.pc.old.closes, 1);
      expect(rig.disposed.where((id) => id == 8).length, 1);
      unawaited(rig.routed.close());
      await flush(t);
    },
  );
  testWidgets(
    'unresolved ownership ends both wires and never replays queued touches',
    (t) async {
      final rig = Rig();
      rig.pc.claiming = Completer<void>();
      rig.pc.loseClaimBefore = rig.pc.statusUnavailable =
          rig.pc.cancelUnavailable = true;
      await rig.open(t);
      await rig.begin(t);
      await t.tap(find.byType(Texture));
      await flush(t);
      rig.pc.claiming!.complete();
      await flush(t);
      expect(rig.pc.inputSequence, 0);
      expect(rig.pc.phases.where((p) => p == 'new:claim').length, 1);
      expect(rig.pc.old.closes, 1);
      expect(rig.pc.next.closes, 1);
      expect(rig.business.closed, 0);
      await rig.leave(t);
    },
  );
}
