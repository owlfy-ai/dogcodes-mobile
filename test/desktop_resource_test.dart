import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:dogcodes_app/core/adaptive_host_link.dart';
import 'package:dogcodes_app/core/rtc_transport.dart';
import 'package:dogcodes_app/core/host_hub.dart';
import 'package:dogcodes_app/core/security/secret_storage.dart';
import 'package:dogcodes_app/features/computers/remote_desktop_page.dart';
import 'package:dogcodes_app/ui/theme.dart';
import 'remote_desktop_widget_test.dart' show DesktopLink;

class Peer implements RTCPeerConnection {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class CountLink extends DesktopLink {
  int closed = 0;
  @override
  Future<void> close() async {
    closed++;
  }
}

class ScreenStream extends MediaStream {
  ScreenStream() : super('screen', 'remote');
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class ScreenPeer extends Peer {
  @override
  Future<List<StatsReport>> getStats([MediaStreamTrack? track]) async => [];
}

class RtcScreenLink extends CountLink {
  int selects = 0;
  @override
  Future<dynamic> call(String method, dynamic params) async {
    if (method == 'remote_desktop_displays') {
      return [
        {'id': 1, 'width': 1600, 'height': 1000, 'primary': true},
        {'id': 2, 'width': 1600, 'height': 1000, 'primary': false},
      ];
    }
    if (method == 'remote_desktop_open') {
      opens.add(Map<String, dynamic>.from(params as Map));
      return {
        'leaseId': 'lease',
        'inputSequence': '0',
        'inputBatch': 64,
        'video': {
          'codec': 'h264',
          'width': 1600,
          'height': 1000,
          'transport': 'webrtc',
        },
      };
    }
    if (method == 'remote_desktop_select') {
      selects++;
      throw StateError('screen peer must be replaced');
    }
    return super.call(method, params);
  }
}

void main() {
  testWidgets(
    'RTC screen switches replace the peer even if renderer cleanup fails',
    (t) async {
      const methods = MethodChannel('FlutterWebRTC.Method');
      const events = MethodChannel('FlutterWebRTC.Event');
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        events,
        (_) async => null,
      );
      addTearDown(
        () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          events,
          null,
        ),
      );
      final channels = <String>[];
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
          return {'textureId': id};
        }
        if (call.method == 'videoRendererDispose') {
          throw PlatformException(code: 'gone', message: 'already gone');
        }
        return null;
      });
      addTearDown(() {
        t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          methods,
          null,
        );
        for (final path in channels) {
          t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            MethodChannel(path),
            null,
          );
        }
      });
      final business = CountLink(), connections = <RtcScreenLink>[];
      final routed = AdaptiveHostLink(
        relay: business,
        relayDialer: () async => CountLink(),
        directDialer: (_) async => throw StateError('no'),
        desktopDialer: (_) async {
          final link = RtcScreenLink();
          connections.add(link);
          return DesktopConnection(
            link,
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
      for (var i = 0; i < 12; i++) {
        await t.pump();
      }
      expect(connections, hasLength(1));
      expect(channels, hasLength(1));
      await t.tap(find.byTooltip('切换屏幕'));
      await t.pumpAndSettle();
      await t.tap(find.text('屏幕 2'));
      for (
        var i = 0;
        i < 12 && (connections.length < 2 || connections.last.opens.isEmpty);
        i++
      ) {
        await t.pump();
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      expect(connections, hasLength(2));
      expect(connections.first.closed, 1);
      expect(connections.first.selects, 0);
      expect(connections.last.opens.single['monitorId'], 2);
      expect(business.closed, 0);
      await t.pumpWidget(const SizedBox());
      for (var i = 0; i < 6; i++) {
        await t.pump();
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
      }
      unawaited(routed.close());
    },
  );
  testWidgets(
    'business route upgrades do not retire the dedicated desktop lease',
    (t) async {
      final business = CountLink(),
          desktop = CountLink(),
          candidate = CountLink();
      final routed = AdaptiveHostLink(
        relay: business,
        relayDialer: () async => desktop,
        directDialer: (_) async =>
            DirectConnection(candidate, ConnectionRoute.direct),
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
      for (var i = 0; i < 8; i++) {
        await t.pump();
      }
      expect(desktop.opens.length, 1);
      expect(business.opens, isEmpty);
      await t.runAsync(routed.tryDirect);
      await t.pump(const Duration(seconds: 1));
      expect(routed.route, ConnectionRoute.direct);
      expect(business.closed, 1);
      expect(desktop.closed, 0);
      expect(candidate.opens, isEmpty);
      expect(desktop.frames, isNotEmpty);
      await t.pumpWidget(const SizedBox());
      for (var i = 0; i < 10 && desktop.closed == 0; i++) {
        await t.pump();
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      expect(desktop.closed, 1);
      unawaited(routed.close());
    },
  );

  testWidgets(
    'leaving while desktop dial is pending closes its late connection',
    (t) async {
      final lateLink = CountLink(), gate = Completer<Object>();
      var started = false;
      final routed = AdaptiveHostLink(
        relay: DesktopLink(),
        relayDialer: () async => DesktopLink(),
        directDialer: (_) async => throw StateError('no'),
        desktopDialer: (_) {
          started = true;
          return gate.future;
        },
      );
      final h = HostState({'hostId': 'pc'}, MemorySecretStorage())
        ..link = routed
        ..status = LinkStatus.online;
      await t.pumpWidget(
        MaterialApp(
          theme: dcTheme(Brightness.light),
          home: RemoteDesktopPage(host: h),
        ),
      );
      for (var i = 0; i < 5; i++) {
        await t.pump();
      }
      expect(started, isTrue);
      await t.pumpWidget(const SizedBox());
      gate.complete(
        DesktopConnection(
          lateLink,
          Peer(),
          Completer<MediaStream>().future,
          video: false,
        ),
      );
      for (var i = 0; i < 5; i++) {
        await t.pump();
      }
      final count = lateLink.closed;
      unawaited(lateLink.close());
      unawaited(routed.close());
      expect(
        count,
        1,
        reason:
            'the page is gone, but the authenticated RTC connection remains alive',
      );
    },
  );
}
