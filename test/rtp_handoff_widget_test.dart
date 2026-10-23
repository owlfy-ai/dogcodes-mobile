import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:dogcodes_app/core/adaptive_host_link.dart';
import 'package:dogcodes_app/core/host_hub.dart';
import 'package:dogcodes_app/core/rtc_transport.dart';
import 'package:dogcodes_app/core/security/secret_storage.dart';
import 'package:dogcodes_app/features/computers/remote_desktop_page.dart';
import 'package:dogcodes_app/ui/theme.dart';
import 'desktop_handoff_fixture.dart';
import 'desktop_resource_test.dart' show CountLink, ScreenPeer, ScreenStream;

Future<void> flush(WidgetTester t) async {
  for (var i = 0; i < 12; i++) {
    await t.pump();
  }
  // EventChannel cancellation uses the platform message loop, outside FakeAsync.
  await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
  await t.pump();
}

Future<void> event(
  WidgetTester t,
  int texture,
  String kind, {
  int width = 640,
  int height = 400,
}) async {
  await t.binding.defaultBinaryMessenger.handlePlatformMessage(
    'FlutterWebRTC/Texture$texture',
    const StandardMethodCodec().encodeSuccessEnvelope({
      'event': kind,
      'width': width,
      'height': height,
    }),
    (_) {},
  );
  await flush(t);
}

class RtpRig {
  final pc = HandoffBroker()..transport = 'webrtc',
      business = CountLink(),
      fallback = CountLink();
  final disposed = <int>[], channels = <String>[];
  late AdaptiveHostLink routed;
  int dials = 0, relayDials = 0, decoders = 0;
  bool initialBinary = false, fallbackBinary = false;
  Completer<void>? decoding;
  final decoded = <int, int>{}, disposedDecoders = <int>[];
  final decoderSizes = <Map>[];
  Completer<void>? initializing;
  Future<void> open(WidgetTester t) async {
    t.view.physicalSize = const Size(400, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    if (initialBinary) pc.transport = 'binary';
    const h264 = MethodChannel('dogcodes/h264');
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(h264, (
      call,
    ) async {
      final id = (call.arguments as Map?)?['id'] as int?;
      if (call.method == 'create') {
        decoderSizes.add(Map.from(call.arguments as Map));
        return 100 + (++decoders);
      }
      if (call.method == 'decode') {
        if (id == 102) await decoding?.future;
        decoded[id!] = (decoded[id] ?? 0) + 1;
      }
      if (call.method == 'stats') return {'decoded': decoded[id] ?? 0};
      if (call.method == 'dispose') disposedDecoders.add(id!);
      return null;
    });
    addTearDown(
      () =>
          t.binding.defaultBinaryMessenger.setMockMethodCallHandler(h264, null),
    );
    const methods = MethodChannel('FlutterWebRTC.Method');
    const globalEvents = MethodChannel('FlutterWebRTC.Event');
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      globalEvents,
      (_) async => null,
    );
    addTearDown(
      () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        globalEvents,
        null,
      ),
    );

    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(methods, (
      call,
    ) async {
      if (call.method == 'createVideoRenderer') {
        final id = 20 + channels.length,
            path = 'FlutterWebRTC/Texture${20 + channels.length}';
        channels.add(path);
        t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          MethodChannel(path),
          (_) async => null,
        );
        if (id == 21) await initializing?.future;
        return {'textureId': id};
      }
      if (call.method == 'videoRendererDispose') {
        disposed.add(call.arguments['textureId'] as int);
      }
      return null;
    });
    addTearDown(() {
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(methods, null);
      for (final path in channels) {
        t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          MethodChannel(path),
          null,
        );
      }
    });
    routed = AdaptiveHostLink(
      relay: business,
      retryDelay: const Duration(seconds: 1),
      relayDialer: () async {
        if (initialBinary) return ++relayDials == 1 ? pc.old : pc.next;
        if (fallbackBinary && dials >= 2 && !pc.next.disconnected) {
          return pc.next;
        }
        return CountLink();
      },
      directDialer: (_) async => throw StateError('not a binary desktop'),
      desktopDialer: (_) async {
        final index = ++dials;
        final first = index == 1;
        if ((initialBinary && first) || (fallbackBinary && !first)) {
          throw StateError('fixture media unavailable');
        }
        return DesktopConnection(
          first
              ? pc.old
              : index == 2
              ? pc.next
              : fallback,
          ScreenPeer(),
          Future.value(ScreenStream()),
          video: true,
          expiresAt: first
              ? DateTime.now().add(const Duration(seconds: 90))
              : null,
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
    if (!initialBinary) {
      await event(t, 20, 'didTextureChangeVideoSize');
      await event(t, 20, 'didFirstFrameRendered');
    }
  }

  Future<void> renew(WidgetTester t) async {
    await t.pump(const Duration(seconds: 31));
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
    'RTP renewal keeps old renderer and held input until actual first frame',
    (t) async {
      final rig = RtpRig();
      await rig.open(t);
      await rig.renew(t);
      expect(rig.dials, 2);
      expect(rig.pc.claimed, true);
      expect(rig.pc.phases.where((p) => p == 'new:claim').length, 1);
      expect(
        t
            .widget<RTCVideoView>(find.byType(RTCVideoView))
            .videoRenderer
            .textureId,
        20,
      );
      expect(rig.disposed, isNot(contains(20)));
      // Size metadata alone is not proof of decoded/rendered video.
      await event(t, 21, 'didTextureChangeVideoSize');
      expect(
        t
            .widget<RTCVideoView>(find.byType(RTCVideoView))
            .videoRenderer
            .textureId,
        20,
      );
      await t.tap(find.byType(RTCVideoView));
      await flush(t);
      expect(rig.pc.next.inputs, isNotEmpty);
      expect(rig.pc.old.closes, 0);
      await event(t, 21, 'didFirstFrameRendered');
      expect(
        t
            .widget<RTCVideoView>(find.byType(RTCVideoView))
            .videoRenderer
            .textureId,
        21,
      );
      expect(rig.pc.old.closes, 1);
      expect(rig.pc.next.opens, isEmpty);
      expect(rig.pc.old.opens.length, 1);
      expect(rig.business.closed, 0);
      expect(rig.disposed.where((id) => id == 20).length, 1);
      await rig.leave(t);
      expect(rig.pc.next.closes, 1);
      expect(rig.disposed.where((id) => id == 21).length, 1);
    },
  );
  testWidgets(
    'leaving while RTP first frame is pending cancels it and disposes each surface once',
    (t) async {
      final rig = RtpRig();
      await rig.open(t);
      await rig.renew(t);
      expect(rig.pc.claimed, true);
      await rig.leave(t);
      expect(rig.pc.next.closes, 1);
      expect(rig.pc.old.closes, 1);
      expect(rig.disposed.where((id) => id == 20).length, 1);
      expect(rig.disposed.where((id) => id == 21).length, 1);
    },
  );
  testWidgets(
    'late candidate renderer cannot claim a lease after the page left',
    (t) async {
      final rig = RtpRig()..initializing = Completer<void>();
      await rig.open(t);
      await rig.renew(t);
      expect(rig.dials, 2);
      expect(rig.pc.claimed, false);
      await rig.leave(t);
      rig.initializing!.complete();
      await flush(t);
      expect(rig.pc.phases, isNot(contains('new:claim')));
      expect(rig.pc.next.closes, 1);
      expect(rig.disposed.where((id) => id == 21).length, 1);
    },
  );
  testWidgets(
    'missing RTP first frame falls back once without reusing the moved lease',
    (t) async {
      final rig = RtpRig();
      await rig.open(t);
      await rig.renew(t);
      expect(rig.pc.claimed, true);
      await t.pump(const Duration(seconds: 6));
      await flush(t);
      expect(rig.pc.phases.where((p) => p == 'new:claim').length, 1);
      expect(rig.pc.next.closes, 1);
      expect(rig.pc.old.closes, 1);
      expect(rig.disposed.where((id) => id == 20).length, 1);
      expect(rig.disposed.where((id) => id == 21).length, 1);
      expect(find.byType(RTCVideoView), findsNothing);
      expect(rig.fallback.opens.single['video'], isNot(true));
      expect(rig.fallback.frames, isNotEmpty);
      expect(rig.business.closed, 0);
      await rig.leave(t);
      expect(rig.pc.next.closes, 1);
    },
  );
  testWidgets(
    'binary to RTP waits for codec readiness and a real first frame while retaining old pixels',
    (t) async {
      final rig = RtpRig()..initialBinary = true;
      rig.pc.codecGate = Completer<void>();
      rig.pc.movedWidth = 800;
      rig.pc.movedHeight = 500;
      await rig.open(t);
      expect(t.widget<Texture>(find.byType(Texture)).textureId, 101);
      await t.pump(const Duration(seconds: 1));
      await flush(t);
      await t.pump(const Duration(seconds: 1));
      await flush(t);
      expect(
        rig.pc.claimed,
        true,
        reason: 'dials ${rig.dials} phases ${rig.pc.phases}',
      );
      expect(rig.pc.transport, 'webrtc');
      expect(t.widget<Texture>(find.byType(Texture)).textureId, 101);
      rig.pc.codecGate!.complete();
      await t.pump(const Duration(milliseconds: 101));
      await flush(t);
      expect(t.widget<Texture>(find.byType(Texture)).textureId, 101);
      final oldSize = t.getSize(find.byType(Texture));
      await event(t, 20, 'didTextureChangeVideoSize', width: 800, height: 600);
      expect(t.getSize(find.byType(Texture)), oldSize);
      expect(t.widget<Texture>(find.byType(Texture)).textureId, 101);
      await event(t, 20, 'didFirstFrameRendered');
      expect(t.widget<Texture>(find.byType(Texture)).textureId, 20);
      expect(rig.disposedDecoders, [101]);
      await t.tap(find.byType(Texture));
      await flush(t);
      expect(rig.pc.next.inputs, isNotEmpty);
      expect(rig.pc.phases.where((p) => p == 'new:claim').length, 1);
      await rig.leave(t);
    },
  );
  testWidgets(
    'RTP to binary retains old RTP until decoded output and recreates the target decoder geometry',
    (t) async {
      final rig = RtpRig()
        ..fallbackBinary = true
        ..decoding = Completer<void>();
      rig.pc.codecGate = Completer<void>();
      rig.pc.movedWidth = 960;
      rig.pc.movedHeight = 600;
      await rig.open(t);
      await rig.renew(t);
      expect(
        rig.pc.claimed,
        true,
        reason: 'dials ${rig.dials} phases ${rig.pc.phases}',
      );
      expect(rig.pc.transport, 'binary');
      expect(t.widget<Texture>(find.byType(Texture)).textureId, 20);
      rig.pc.codecGate!.complete();
      await t.pump(const Duration(milliseconds: 101));
      await flush(t);
      expect(rig.decoders, 2);
      expect(rig.decoderSizes.last, containsPair('width', 960));
      expect(rig.decoderSizes.last, containsPair('height', 600));
      expect(rig.disposedDecoders, [101]);
      expect(t.widget<Texture>(find.byType(Texture)).textureId, 20);
      rig.decoding!.complete();
      await flush(t);
      expect(t.widget<Texture>(find.byType(Texture)).textureId, 102);
      expect(rig.disposed, [20]);
      await t.tap(find.byType(Texture));
      await flush(t);
      expect(rig.pc.next.inputs, isNotEmpty);
      expect(rig.pc.phases.where((p) => p == 'new:claim').length, 1);
      await rig.leave(t);
    },
  );
  testWidgets(
    'codec handoff timeout falls back once without replaying the claim',
    (t) async {
      final rig = RtpRig()..fallbackBinary = true;
      rig.pc.codecGate = Completer<void>();
      await rig.open(t);
      await rig.renew(t);
      expect(rig.pc.claimed, true);
      await t.pump(const Duration(seconds: 11));
      await flush(t);
      expect(rig.pc.phases.where((p) => p == 'new:claim').length, 1);
      expect(rig.pc.next.closes, 1);
      expect(rig.pc.old.closes, 1);
      await t.pump(const Duration(milliseconds: 100));
      await flush(t);
      expect(find.textContaining('已切换图片模式'), findsOneWidget);
      await rig.leave(t);
    },
  );
  testWidgets(
    'leaving during a mixed codec rebuild closes both links and never continues polling',
    (t) async {
      final rig = RtpRig()..fallbackBinary = true;
      rig.pc.codecGate = Completer<void>();
      await rig.open(t);
      await rig.renew(t);
      expect(rig.pc.claimed, true);
      await rig.leave(t);
      final calls = rig.pc.next.controls.length;
      rig.pc.codecGate!.complete();
      await t.pump(const Duration(milliseconds: 101));
      await flush(t);
      expect(rig.pc.next.controls.length, calls);
      expect(rig.pc.next.closes, 1);
      expect(rig.pc.old.closes, 1);
      expect(rig.disposed.where((id) => id == 20).length, 1);
      expect(rig.disposedDecoders, [101]);
    },
  );
}
