import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/core/adaptive_host_link.dart';
import 'package:dogcodes_app/core/host_hub.dart';
import 'package:dogcodes_app/core/security/secret_storage.dart';
import 'package:dogcodes_app/features/computers/remote_desktop_page.dart';
import 'package:dogcodes_app/ui/theme.dart';

/// A 16×10 grey PNG standing in for a 16:10 Mac frame.
const _png =
    'iVBORw0KGgoAAAANSUhEUgAAABAAAAAKCAIAAAAy3EnLAAAAEUlEQVR4nGNoIBEwjGoYmhoAv1XwATGE43sAAAAASUVORK5CYII=';

class DesktopLink implements HostLink {
  final inputs = <Map<String, dynamic>>[];
  final frames = <Map<String, dynamic>>[];
  final opens = <Map<String, dynamic>>[];
  final controls = <Map<String, dynamic>>[];

  /// Answers a binary-video request with a relay video stream.
  bool relayVideo = false;
  final pushed = StreamController<Map<String, dynamic>>.broadcast();
  @override
  String get hostId => 'pc';
  @override
  String? get hostName => 'Mac';
  @override
  Stream<Map<String, dynamic>> get events => pushed.stream;
  @override
  Future<void> close() async {}
  @override
  Future<dynamic> call(String method, dynamic params) async {
    return switch (method) {
      'device_status' => {'locked': false},
      'remote_desktop_displays' => [
        {'id': 1, 'width': 1728, 'height': 1080, 'scale': 2.0, 'primary': true},
      ],
      'remote_capabilities' => {
        'transportMethods': ['direct_open'],
      },
      'remote_desktop_open' => _open(params as Map),
      'remote_desktop_frame' => _frame(params as Map),
      'remote_desktop_input' => _input(params as Map),
      'remote_desktop_video' => _control(params as Map),
      _ => null,
    };
  }

  Map<String, dynamic> _control(Map params) {
    controls.add(Map<String, dynamic>.from(params));
    return {};
  }

  Map<String, dynamic> _open(Map params) {
    opens.add(Map<String, dynamic>.from(params));
    return {
      'leaseId': 'lease',
      'inputSequence': '0',
      'maxFps': 25,
      'inputBatch': 64,
      if (relayVideo && params['videoTransport'] == 'binary')
        'video': {
          'codec': 'h264',
          'width': 1600,
          'height': 1000,
          'transport': 'binary',
        },
    };
  }

  Map<String, dynamic> _frame(Map params) {
    frames.add(Map<String, dynamic>.from(params));
    final known = params['knownFrameId'] == 'f1';
    return {
      'frameId': 'f1',
      if (known) 'unchanged': true,
      if (!known) ...{'width': 1600, 'height': 1000, 'bytes': _png},
      'cursor': {'x': 0, 'y': 0},
    };
  }

  Map<String, dynamic> _input(Map params) {
    inputs.add(Map<String, dynamic>.from(params));
    return {'sequence': params['sequence']};
  }

  /// All events in send order, each tagged with its request's sequence.
  List<String> get log => [
    for (final r in inputs)
      for (final e in r['events'] as List)
        '${r['sequence']}:${e['kind']}'
            '${e['direction'] != null ? '-${e['direction']}' : ''}',
  ];
}

void main() {
  testWidgets('tap, long-press, drag and pinch drive the remote in order', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final link = DesktopLink();
    final host = HostState({'hostId': 'pc'}, MemorySecretStorage())
      ..link = link
      ..status = LinkStatus.online;
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: dcTheme(Brightness.light),
          home: RemoteDesktopPage(host: host),
        ),
      );
      for (var i = 0; i < 20 && link.frames.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(link.frames, isNotEmpty);
    expect(find.byType(Image), findsOneWidget);
    final screen = tester.getRect(
      find
          .ancestor(of: find.byType(Image), matching: find.byType(Listener))
          .first,
    );
    final centre = screen.center;

    await tester.tapAt(centre);
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    expect(link.log, ['1:move', '2:button-press', '2:button-release']);
    // Taps land relative to the fitted frame: the centre is (0.5, 0.5).
    final move = (link.inputs.first['events'] as List).single as Map;
    expect(move['x'], closeTo(32768, 200));
    expect(move['y'], closeTo(32768, 200));

    link.inputs.clear();
    final drag = await tester.startGesture(centre);
    await tester.pump(const Duration(milliseconds: 20));
    for (var i = 1; i <= 5; i++) {
      await drag.moveBy(const Offset(10, 4));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await drag.up();
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    final kinds = link.log.map((e) => e.split(':').last).toList();
    expect(kinds.first, 'move');
    expect(kinds[1], 'button-press');
    expect(kinds.last, 'button-release');
    expect(kinds.where((k) => k.startsWith('button')).length, 2);
    // Sequence numbers are strictly consecutive, one per request.
    final seqs = link.inputs.map((r) => int.parse('${r['sequence']}'));
    expect(seqs, List.generate(seqs.length, (i) => seqs.first + i));

    link.inputs.clear();
    final hold = await tester.startGesture(centre);
    await tester.pump(const Duration(milliseconds: 600));
    await hold.up();
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    final events = link.inputs.expand((r) => r['events'] as List).toList();
    expect(events.where((e) => e['kind'] == 'button').map((e) => e['button']), [
      'right',
      'right',
    ]);

    // Pinch zoom is local only; a later tap maps through the zoomed view.
    link.inputs.clear();
    final a = await tester.startGesture(centre - const Offset(40, 0));
    final b = await tester.startGesture(centre + const Offset(40, 0));
    await tester.pump();
    for (var i = 0; i < 4; i++) {
      await a.moveBy(const Offset(-20, 0));
      await b.moveBy(const Offset(20, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await a.up();
    await b.up();
    await tester.pump();
    expect(link.inputs, isEmpty);
    await tester.tapAt(centre + const Offset(100, 0));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    final zoomed = (link.inputs.first['events'] as List).first as Map;
    // Without zoom +100 px would be 0.75 across; zoomed in it is much less.
    expect(zoomed['x'], lessThan(0.7 * 65535));
    expect(zoomed['x'], greaterThan(32768));

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('without a desktop connection the page stays on frame pulls', (
    tester,
  ) async {
    final business = DesktopLink();
    final relay = DesktopLink();
    var dialed = 0;
    final link = AdaptiveHostLink(
      relay: business,
      relayDialer: () async => relay,
      directDialer: (_) async => throw StateError('no ICE'),
      desktopDialer: (_) async {
        dialed++;
        throw StateError('no ICE');
      },
    );
    final host = HostState({'hostId': 'pc'}, MemorySecretStorage())
      ..link = link
      ..status = LinkStatus.online;
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: dcTheme(Brightness.light),
          home: RemoteDesktopPage(host: host),
        ),
      );
      for (var i = 0; i < 20 && relay.frames.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
    });
    await tester.pump();
    expect(dialed, 1);
    // Relay video was asked for; this PC has none, so JPEG frames flow.
    expect(relay.opens.single['videoTransport'], 'binary');
    expect(relay.frames, isNotEmpty);
    expect(find.byType(Image), findsOneWidget);
    expect(find.textContaining('使用图片模式'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(link.close);
  });

  testWidgets('relay video feeds the platform decoder and acknowledges', (
    tester,
  ) async {
    const channel = MethodChannel('dogcodes/h264');
    final decoded = <(int, bool)>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      final args = call.arguments as Map;
      switch (call.method) {
        case 'create':
          expect((args['width'], args['height']), (1600, 1000));
          return 7;
        case 'decode':
          decoded.add((
            (args['data'] as Uint8List).length,
            args['keyframe'] as bool,
          ));
          return null;
      }
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final link = DesktopLink()..relayVideo = true;
    final host = HostState({'hostId': 'pc'}, MemorySecretStorage())
      ..link = link
      ..status = LinkStatus.online;
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: dcTheme(Brightness.light),
          home: RemoteDesktopPage(host: host),
        ),
      );
      for (var i = 0; i < 20 && link.opens.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      for (var seq = 1; seq <= 3; seq++) {
        link.pushed.add({
          'type': 'video',
          'leaseId': 'lease',
          'seq': seq,
          'key': seq == 1,
          'payload': Uint8List(100 * seq),
        });
      }
      // Another lease's frames are not ours.
      link.pushed.add({
        'type': 'video',
        'leaseId': 'old',
        'seq': 9,
        'key': true,
        'payload': Uint8List(1),
      });
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await tester.pump();
    });
    expect(decoded, [(100, true), (200, false), (300, false)]);
    expect(link.controls.last['ack'], '3');
    expect(link.frames, isEmpty);
    expect(find.byType(Texture), findsOneWidget);
    expect(find.textContaining('H.264 · 加密中继'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
