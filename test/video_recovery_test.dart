import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fake_async/fake_async.dart';
import 'package:dogcodes_app/core/host_hub.dart';
import 'package:dogcodes_app/core/protocol.dart';
import 'package:dogcodes_app/core/security/secret_storage.dart';
import 'package:dogcodes_app/features/computers/remote_desktop_page.dart';
import 'package:dogcodes_app/features/computers/relay_video.dart';
import 'package:dogcodes_app/ui/theme.dart';
import 'relay_video_test.dart' show frame;
import 'remote_desktop_widget_test.dart' show DesktopLink;
import 'native_cursor_test.dart' show cursorWire, nativeShapeId;

class NativeCursorScreens extends DesktopLink {
  NativeCursorScreens(bool video) {
    relayVideo = video;
  }
  int shapesSent = 0;
  @override
  Future<dynamic> call(String method, dynamic args) async {
    final result = await super.call(method, args);
    if (method == 'remote_desktop_open' && result['video'] is Map) {
      result['video'] = {
        ...result['video'] as Map,
        'generation': 1,
        'clientReadyRequired': true,
        'cursorEmbedded': false,
      };
    }
    if (method == 'remote_desktop_video' && args['ready'] == true) {
      result['relay'] = {'generation': 1, 'ready': true};
      pushed.add({...frame(1, key: true), 'leaseId': 'lease', 'generation': 1});
    }
    if (method == 'remote_desktop_frame' ||
        (method == 'remote_desktop_video' && args['includeCursor'] == true)) {
      final pixels = args['knownCursorShapeId'] != nativeShapeId;
      if (pixels) shapesSent++;
      result['cursor'] = cursorWire(pixels: pixels);
      if (method == 'remote_desktop_frame') result['cursorEmbedded'] = false;
    }
    return result;
  }
}

class Screens extends DesktopLink {
  Screens() {
    relayVideo = true;
  }
  @override
  Future<dynamic> call(String m, dynamic a) async {
    if (m == 'remote_desktop_displays') {
      return [
        {'id': 1, 'width': 1600, 'height': 1000, 'scale': 1.0, 'primary': true},
        {
          'id': 2,
          'width': 1000,
          'height': 1600,
          'scale': 1.0,
          'primary': false,
        },
      ];
    }
    if (m == 'remote_desktop_select') {
      return {
        'monitorId': 2,
        'video': {'codec': 'h264', 'width': 1000, 'height': 1600},
      };
    }
    return super.call(m, a);
  }
}

class ReadyScreens extends Screens {
  int generation = 1, sequence = 0;
  final ready = <int>[];
  void Function()? onReady;
  @override
  Future<dynamic> call(String method, dynamic args) async {
    if (method == 'remote_desktop_video' && args['ready'] == true) {
      expect(args['generation'], generation);
      onReady?.call();
      ready.add(generation);
      controls.add(Map<String, dynamic>.from(args as Map));
      // The first frame arrives as soon as PC sees readiness, even before
      // the readiness reply. It must already have a live listener/decoder.
      pushed.add({
        ...frame(++sequence, key: true),
        'leaseId': 'lease',
        'generation': generation,
      });
      return {
        'relay': {'generation': generation, 'ready': true},
      };
    }
    final result = await super.call(method, args);
    if (method == 'remote_desktop_open' || method == 'remote_desktop_select') {
      if (method == 'remote_desktop_select') generation++;
      final value = Map<String, dynamic>.from(result as Map);
      value['video'] = {
        ...value['video'] as Map,
        'generation': generation,
        'clientReadyRequired': true,
      };
      return value;
    }
    return result;
  }
}

class PointerScreens extends ReadyScreens {
  PointerScreens(this.embedded);
  final bool? embedded;
  @override
  Future<dynamic> call(String method, dynamic args) async {
    final result = await super.call(method, args);
    if (method == 'remote_desktop_open' || method == 'remote_desktop_select') {
      result['video']['cursorEmbedded'] = embedded;
    }
    return result;
  }
}

class EmbeddedScreenshots extends DesktopLink {
  @override
  Future<dynamic> call(String method, dynamic args) async {
    final result = await super.call(method, args);
    if (method == 'remote_desktop_frame') result['cursorEmbedded'] = true;
    return result;
  }
}

class DelayedScreen extends Screens {
  DelayedScreen() {
    relayVideo = false;
  }
  final selecting = Completer<void>();
  int display = 1;
  bool holdNext = false, selectRequested = false;
  Completer<Map<String, dynamic>>? oldFrame;
  Map<String, dynamic>? held;
  @override
  Future<dynamic> call(String method, dynamic args) async {
    if (method == 'remote_desktop_select') {
      selectRequested = true;
      await selecting.future;
      display = 2;
      return {'monitorId': 2, 'video': null};
    }
    if (method == 'remote_desktop_frame') {
      final result = Map<String, dynamic>.from(
        await super.call(method, {...args as Map, 'knownFrameId': null}) as Map,
      );
      result.addAll({
        'monitorId': display,
        'frameId': 'screen-$display',
        'width': display == 1 ? 1600 : 1000,
        'height': display == 1 ? 1000 : 1600,
      });
      if (holdNext) {
        holdNext = false;
        held = result;
        oldFrame = Completer<Map<String, dynamic>>();
        return oldFrame!.future;
      }
      return result;
    }
    return super.call(method, args);
  }
}

void main() {
  for (final video in [false, true]) {
    testWidgets(
      'native pointer is painted and acknowledged on ${video ? "video" : "JPEG"}',
      (t) async {
        const channel = MethodChannel('dogcodes/h264');
        t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async => switch (call.method) {
            'create' => 7,
            'stats' => {'decoded': 1},
            _ => null,
          },
        );
        addTearDown(
          () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );
        final link = NativeCursorScreens(video);
        final host = HostState({'hostId': 'pc'}, MemorySecretStorage())
          ..link = link
          ..status = LinkStatus.online;
        await t.pumpWidget(
          MaterialApp(
            theme: dcTheme(Brightness.light),
            home: RemoteDesktopPage(host: host),
          ),
        );
        if (!video) {
          await t.runAsync(() async {
            for (var i = 0; i < 25 && link.frames.isEmpty; i++) {
              await Future<void>.delayed(const Duration(milliseconds: 20));
              await t.pump();
            }
            await Future<void>.delayed(const Duration(milliseconds: 50));
          });
        }
        for (var i = 0; i < 12; i++) {
          await t.pump();
        }
        if (video) {
          await t.pump(const Duration(milliseconds: 1001));
          await t.pump();
        }
        expect(
          find.byKey(const ValueKey('desktop-cursor-shape-$nativeShapeId')),
          findsOneWidget,
        );
        for (var i = 0; i < 4; i++) {
          if ([
            ...link.frames,
            ...link.controls,
          ].any((r) => r['knownCursorShapeId'] == nativeShapeId)) {
            break;
          }
          await t.pump(const Duration(milliseconds: 1001));
          await t.pump();
        }
        expect(
          [
            ...link.frames,
            ...link.controls,
          ].any((r) => r['knownCursorShapeId'] == nativeShapeId),
          true,
        );
        expect(link.shapesSent, 1);
        expect(
          find.byKey(const ValueKey('desktop-cursor-shape-$nativeShapeId')),
          findsOneWidget,
        );
        await t.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('JPEG with an embedded pointer does not retain a second arrow', (
    t,
  ) async {
    final link = EmbeddedScreenshots();
    final host = HostState({'hostId': 'pc'}, MemorySecretStorage())
      ..link = link
      ..status = LinkStatus.online;
    await t.pumpWidget(
      MaterialApp(
        theme: dcTheme(Brightness.light),
        home: RemoteDesktopPage(host: host),
      ),
    );
    await t.runAsync(() async {
      for (var i = 0; i < 25 && link.frames.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await t.pump();
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await t.pump();
    final pointer = find.byKey(const ValueKey('desktop-cursor'));
    expect(find.byType(Image), findsOneWidget);
    expect(pointer, findsNothing);
    await t.tap(find.byType(Image));
    await t.pump();
    expect(pointer, findsOneWidget);
    await t.pump(const Duration(milliseconds: 401));
    expect(pointer, findsNothing);
    await t.pumpWidget(const SizedBox.shrink());
  });

  for (final embedded in [true, false, null]) {
    testWidgets('video pointer prediction expires only if embedded=$embedded', (
      t,
    ) async {
      const channel = MethodChannel('dogcodes/h264');
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'create' ? 7 : null,
      );
      addTearDown(
        () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final link = PointerScreens(embedded);
      final host = HostState({'hostId': 'pc'}, MemorySecretStorage())
        ..link = link
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
      expect(find.byType(Texture), findsOneWidget);
      final pointer = find.byKey(const ValueKey('desktop-cursor'));
      expect(pointer, findsNothing);
      await t.tap(find.byType(Texture));
      await t.pump();
      expect(pointer, findsOneWidget);
      await t.pump(const Duration(milliseconds: 401));
      expect(pointer, embedded != false ? findsNothing : findsOneWidget);
      await t.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'decoder creation timeout uses JPEG and releases a late texture',
    (t) async {
      const channel = MethodChannel('dogcodes/h264');
      final creating = Completer<int>();
      var requested = false, disposed = 0;
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'create') {
          requested = true;
          return creating.future;
        }
        if (call.method == 'dispose') disposed++;
        return null;
      });
      addTearDown(
        () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final link = ReadyScreens();
      final host = HostState({'hostId': 'pc'}, MemorySecretStorage())
        ..link = link
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
      expect(requested, true);
      await t.pump(const Duration(milliseconds: 3100));
      for (var i = 0; i < 12; i++) {
        await t.pump();
      }
      expect(link.ready, isEmpty);
      expect(link.opens.length, 2);
      expect(link.opens.last['video'], isNull);
      creating.complete(7);
      for (var i = 0; i < 8; i++) {
        await t.pump();
      }
      expect(disposed, 1);
      expect(link.ready, isEmpty);
      await t.pumpWidget(const SizedBox());
    },
  );

  testWidgets('initial and switched streams wait for decoder readiness', (
    t,
  ) async {
    const channel = MethodChannel('dogcodes/h264');
    final creating = Completer<int>();
    var creates = 0, decoded = 0, decoderReady = false;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'create') {
        final result = ++creates == 1 ? await creating.future : 8;
        decoderReady = true;
        return result;
      }
      if (call.method == 'decode') decoded++;
      if (call.method == 'stats') {
        return {'decoded': decoded, 'pending': 0, 'maxPending': 1};
      }
      return null;
    });
    addTearDown(
      () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final link = ReadyScreens()
      ..onReady = () {
        expect(decoderReady, true);
      };
    final host = HostState({'hostId': 'pc'}, MemorySecretStorage())
      ..link = link
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
    expect(creates, 1);
    expect(link.ready, isEmpty);
    expect(link.opens.single['deferVideo'], true);
    creating.complete(7);
    for (var i = 0; i < 12; i++) {
      await t.pump();
    }
    expect(link.ready, [1]);
    expect(
      decoded,
      1,
      reason: 'the first IDR before the readiness reply must not be lost',
    );
    expect(find.byType(Texture), findsOneWidget);
    await t.tap(find.byTooltip('切换屏幕'));
    await t.pumpAndSettle();
    decoderReady = false;
    await t.tap(find.text('屏幕 2'));
    for (var i = 0; i < 12; i++) {
      await t.pump();
    }
    expect(link.ready, [1, 2]);
    expect(decoded, 2);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('a decoder created after leaving never activates PC video', (
    t,
  ) async {
    const channel = MethodChannel('dogcodes/h264');
    final creating = Completer<int>();
    var disposed = 0, requested = false;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'create') {
        requested = true;
        return creating.future;
      }
      if (call.method == 'dispose') disposed++;
      return null;
    });
    addTearDown(
      () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final link = ReadyScreens();
    final host = HostState({'hostId': 'pc'}, MemorySecretStorage())
      ..link = link
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
    expect(requested, true);
    await t.pumpWidget(const SizedBox());
    creating.complete(7);
    for (var i = 0; i < 8; i++) {
      await t.pump();
    }
    expect(link.ready, isEmpty);
    expect(disposed, 1);
  });

  testWidgets('screen switches reject old coordinates and late JPEG replies', (
    t,
  ) async {
    final link = DelayedScreen();
    final host = HostState({'hostId': 'pc'}, MemorySecretStorage())
      ..link = link
      ..status = LinkStatus.online;
    await t.pumpWidget(
      MaterialApp(
        theme: dcTheme(Brightness.light),
        home: RemoteDesktopPage(host: host),
      ),
    );
    await t.runAsync(() async {
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await t.pump();
        if (find.byType(Image).evaluate().isNotEmpty) break;
      }
    });
    await t.pump();
    expect(find.byType(Image), findsOneWidget);
    final screen = t.getRect(
      find
          .ancestor(of: find.byType(Image), matching: find.byType(Listener))
          .first,
    );
    link.holdNext = true;
    for (var i = 0; i < 5 && link.oldFrame == null; i++) {
      await t.pump(const Duration(milliseconds: 200));
    }
    expect(link.oldFrame, isNotNull);
    await t.tap(find.byTooltip('切换屏幕'));
    await t.pumpAndSettle();
    await t.tap(find.text('屏幕 2'));
    for (var i = 0; i < 4; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(link.selectRequested, isTrue);
    await t.tapAt(screen.center);
    await t.pump();
    expect(link.inputs, isEmpty);
    link.selecting.complete();
    for (var i = 0; i < 4; i++) {
      await t.pump();
    }
    expect(find.byType(Image), findsNothing);
    link.oldFrame!.complete(link.held!);
    for (var i = 0; i < 4; i++) {
      await t.pump();
    }
    expect(find.byType(Image), findsNothing);
    await t.pump(const Duration(milliseconds: 60));
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await t.pump();
    expect(find.byType(Image), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });
  test('rejected final cumulative ACK is retried even without a new frame', () {
    fakeAsync((a) {
      final calls = <int?>[];
      final r = RelayVideoReceiver(
        decode: (_, _) async {},
        control: ({int? ack, bool keyframe = false}) async {
          calls.add(ack);
          if (ack == 8 && calls.where((s) => s == 8).length == 1) {
            throw const ProtocolException('too many in-flight requests');
          }
        },
        now: () => a.getClock(DateTime(2026)).now(),
      );
      r.onFrame(frame(1, key: true));
      a.flushMicrotasks();
      for (var i = 2; i <= 8; i++) {
        r.onFrame(frame(i));
      }
      a.elapse(const Duration(seconds: 3));
      expect(
        calls.where((s) => s == 8).length,
        greaterThan(1),
        reason:
            'PC window is full; no new frame can trigger the next cumulative ACK',
      );
      r.dispose();
    });
  });
  testWidgets('selecting portrait monitor updates relay viewport aspect', (
    t,
  ) async {
    const ch = MethodChannel('dogcodes/h264');
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      ch,
      (c) async => c.method == 'create' ? 7 : null,
    );
    addTearDown(
      () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(ch, null),
    );
    final link = Screens();
    final h = HostState({'hostId': 'pc'}, MemorySecretStorage())
      ..link = link
      ..status = LinkStatus.online;
    await t.pumpWidget(
      MaterialApp(
        theme: dcTheme(Brightness.light),
        home: RemoteDesktopPage(host: h),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await t.pump();
    }
    expect(find.byType(Texture), findsOneWidget);
    final before = t.getSize(find.byType(Texture));
    expect(before.width / before.height, closeTo(1.6, .01));
    await t.tap(find.byTooltip('切换屏幕'));
    await t.pumpAndSettle();
    await t.tap(find.text('屏幕 2'));
    await t.pump();
    await t.pump();
    final after = t.getSize(find.byType(Texture));
    expect(after.width / after.height, closeTo(.625, .01));
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('video without decoded frames eventually falls back', (t) async {
    const ch = MethodChannel('dogcodes/h264');
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      ch,
      (c) async => c.method == 'create' ? 7 : null,
    );
    addTearDown(
      () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(ch, null),
    );
    final link = Screens();
    final h = HostState({'hostId': 'pc'}, MemorySecretStorage())
      ..link = link
      ..status = LinkStatus.online;
    await t.pumpWidget(
      MaterialApp(
        theme: dcTheme(Brightness.light),
        home: RemoteDesktopPage(host: h),
      ),
    );
    for (var i = 0; i < 25; i++) {
      await t.pump(const Duration(seconds: 1));
    }
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await t.pump();
    expect(link.controls.length, greaterThanOrEqualTo(8));
    expect(
      link.frames,
      isNotEmpty,
      reason:
          'successful heartbeats are not proof that the video stream is producing a picture',
    );
    await t.pumpWidget(const SizedBox());
  });
}
