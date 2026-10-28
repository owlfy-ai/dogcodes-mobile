import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/core/adaptive_host_link.dart';
import 'package:dogcodes_app/core/rtc_transport.dart';
import 'package:dogcodes_app/core/host_hub.dart';
import 'package:dogcodes_app/core/security/secret_storage.dart';
import 'package:dogcodes_app/features/computers/remote_desktop_page.dart';
import 'package:dogcodes_app/ui/theme.dart';
import 'desktop_resource_test.dart'
    show CountLink, RtcScreenLink, ScreenPeer, ScreenStream;

class StartupRig {
  final creation = Completer<Map<String, dynamic>>();
  final business = CountLink();
  final screens = <RtcScreenLink>[];
  final disposed = <int>[], attached = <String>[];
  final calls = <String>[];
  late AdaptiveHostLink routed;
  int creates = 0;

  Future<void> flush(WidgetTester t) async {
    for (var i = 0; i < 16; i++) {
      await t.pump();
    }
  }

  Future<void> open(WidgetTester t) async {
    const methods = MethodChannel('FlutterWebRTC.Method');
    const events = MethodChannel('FlutterWebRTC.Event');
    const texture = EventChannel('FlutterWebRTC/Texture80');
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      events,
      (_) async => null,
    );
    t.binding.defaultBinaryMessenger.setMockStreamHandler(
      texture,
      MockStreamHandler.inline(
        onListen: (_, _) {
          calls.add('texture listen');
        },
        onCancel: (_) {
          calls.add('texture cancel');
        },
      ),
    );
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(methods, (
      call,
    ) async {
      calls.add('${call.method}:${call.arguments}');
      if (call.method == 'createVideoRenderer') {
        creates++;
        return creation.future;
      }
      final args = call.arguments as Map?;
      if (call.method == 'videoRendererDispose') {
        disposed.add(args!['textureId'] as int);
      }
      if (call.method == 'videoRendererSetSrcObject' &&
          args!['streamId'] != '') {
        attached.add(args['streamId'] as String);
      }
      return null;
    });
    addTearDown(() {
      t.binding.defaultBinaryMessenger.setMockStreamHandler(texture, null);
      for (final channel in [methods, events]) {
        t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
      }
    });
    routed = AdaptiveHostLink(
      relay: business,
      relayDialer: () async => CountLink(),
      directDialer: (_) async => throw StateError('no'),
      desktopDialer: (_) async {
        final screen = RtcScreenLink();
        screens.add(screen);
        return DesktopConnection(
          screen,
          ScreenPeer(),
          Future.value(ScreenStream()),
          video: true,
        );
      },
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

  Future<void> leave(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await flush(t);
    if (!creation.isCompleted) creation.complete({'textureId': 80});
    await flush(t);
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await t.pump(const Duration(seconds: 3));
    await flush(t);
    unawaited(routed.close());
    await flush(t);
  }
}

void main() {
  testWidgets(
    'RTP renderer timeout releases video lease and disposes a late surface without binding',
    (t) async {
      final rig = StartupRig();
      try {
        await rig.open(t);
        expect(rig.creates, 1);
        expect(rig.screens.single.opens.single['video'], true);
        await t.pump(const Duration(seconds: 3));
        await rig.flush(t);
        for (var i = 0; i < 4 && rig.screens.length < 2; i++) {
          await t.pump(const Duration(seconds: 1));
          await rig.flush(t);
        }
        expect(
          rig.screens,
          hasLength(2),
          reason: 'creation cannot leave the page waiting forever',
        );
        expect(rig.screens.first.closed, 1);
        expect(rig.screens.last.opens.single['video'], isNot(true));
        expect(rig.screens.last.frames, isNotEmpty);
        rig.creation.complete({'textureId': 80});
        await rig.flush(t);
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await t.pump(const Duration(seconds: 3));
        await rig.flush(t);
        expect(
          rig.attached,
          isEmpty,
          reason: 'late surface belongs to the expired video start',
        );
        expect(rig.disposed, [80], reason: rig.calls.join(" / "));
        expect(
          rig.creates,
          1,
          reason: 'picture fallback cannot start another renderer',
        );
        expect(rig.screens.last.closed, 0);
        expect(rig.business.closed, 0);
      } finally {
        await rig.leave(t);
      }
    },
  );
  testWidgets(
    'leaving during RTP renderer creation never attaches the late stream',
    (t) async {
      final rig = StartupRig();
      try {
        await rig.open(t);
        expect(rig.creates, 1);
        await rig.leave(t);
        expect(
          rig.attached,
          isEmpty,
          reason: 'retired startup must not bind any screen track',
        );
        expect(rig.disposed, [80], reason: rig.calls.join(" / "));
        expect(rig.screens, hasLength(1));
        expect(rig.screens.single.closed, 1);
      } finally {
        await rig.leave(t);
      }
    },
  );
}
