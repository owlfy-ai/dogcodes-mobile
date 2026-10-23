import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/core/host_hub.dart';
import 'package:dogcodes_app/core/security/secret_storage.dart';
import 'package:dogcodes_app/features/computers/remote_desktop_page.dart';
import 'package:dogcodes_app/ui/theme.dart';
import 'video_recovery_test.dart' show ReadyScreens;

class ResizingScreens extends ReadyScreens {
  int width = 640, applied = 0;
  final changes = <Map>[];
  Map<String, dynamic> get description => {
    'codec': 'h264',
    'transport': 'binary',
    'width': width,
    'height': width * 5 ~/ 8,
    'generation': generation,
    'clientReadyRequired': true,
    'resize': {
      'instanceId': 'video-1',
      'requested': '$applied',
      'applied': '$applied',
      'targetWidth': width,
      'maxWidth': 1280,
      'state': 'ready',
    },
  };
  @override
  Future<dynamic> call(String method, dynamic args) async {
    if (method == 'remote_desktop_video' && args['ready'] != true) {
      if (args['targetWidth'] != null) {
        changes.add(Map.of(args as Map));
        final seq = int.parse(args['viewRequest'] as String);
        if (seq > applied) {
          applied = seq;
          width = args['targetWidth'] as int;
          generation++;
        }
      }
      controls.add(Map<String, dynamic>.from(args as Map));
      return {'video': description, 'frames': sequence};
    }
    final result = await super.call(method, args);
    if (method == 'remote_desktop_open' && args['videoTransport'] == 'binary') {
      result['video'] = description;
    }
    return result;
  }
}

Future<void> flush(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump();
  }
}

Future<void> pinch(WidgetTester t) async {
  final center = t.getRect(find.byType(Texture)).center;
  final a = await t.createGesture(pointer: 1),
      b = await t.createGesture(pointer: 2);
  await a.down(center - const Offset(40, 0));
  await b.down(center + const Offset(40, 0));
  await a.moveTo(center - const Offset(110, 0));
  await b.moveTo(center + const Offset(110, 0));
  await a.up();
  await b.up();
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
  await t.pump(const Duration(seconds: 1));
  await flush(t);
  // First heartbeat establishes actual native decoder progress. The next
  // can submit the settled resize without relying on an unproven texture.
  await t.pump(const Duration(seconds: 1));
  await flush(t);
}

void main() {
  testWidgets(
    'resizing keeps the old texture and input until the new decoder outputs a frame',
    (t) async {
      t.view.physicalSize = const Size(400, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      const channel = MethodChannel('dogcodes/h264');
      final creating = Completer<int>(), decoding = Completer<void>();
      var creates = 0;
      final disposed = <int>[], counts = <int, int>{};
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        final id = (call.arguments as Map?)?['id'] as int?;
        if (call.method == 'create') {
          return ++creates == 1 ? 7 : creating.future;
        }
        if (call.method == 'decode') {
          if (id == 8) await decoding.future;
          counts[id!] = (counts[id] ?? 0) + 1;
        }
        if (call.method == 'dispose') disposed.add(id!);
        if (call.method == 'stats') return {'decoded': counts[id] ?? 0};
        return null;
      });
      addTearDown(
        () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final link = ResizingScreens();
      final host = HostState({'hostId': 'pc'}, MemorySecretStorage())
        ..link = link
        ..status = LinkStatus.online;
      await t.pumpWidget(
        MaterialApp(
          theme: dcTheme(Brightness.light),
          home: RemoteDesktopPage(host: host),
        ),
      );
      await flush(t);
      await pinch(t);
      expect(link.changes, isNotEmpty);
      expect(link.changes.single['targetWidth'], greaterThan(640));
      expect(creates, 2);
      expect(t.widget<Texture>(find.byType(Texture)).textureId, 7);
      await t.tap(find.byType(Texture));
      await flush(t);
      expect(link.inputs, isNotEmpty);
      creating.complete(8);
      await flush(t);
      expect(link.ready, [1, 2]);
      expect(t.widget<Texture>(find.byType(Texture)).textureId, 7);
      expect(disposed, isNot(contains(7)));
      decoding.complete();
      await flush(t);
      expect(t.widget<Texture>(find.byType(Texture)).textureId, 8);
      expect(disposed.where((id) => id == 7).length, 1);
      await t.pumpWidget(const SizedBox());
      await flush(t);
      expect(disposed.where((id) => id == 8).length, 1);
    },
  );
  testWidgets(
    'leaving during a resize releases both textures without activating the late decoder',
    (t) async {
      t.view.physicalSize = const Size(400, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      const channel = MethodChannel('dogcodes/h264');
      final creating = Completer<int>();
      var creates = 0;
      final disposed = <int>[];
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'create') {
          return ++creates == 1 ? 7 : creating.future;
        }
        if (call.method == 'stats') return {'decoded': 1};
        if (call.method == 'dispose') disposed.add(call.arguments['id'] as int);
        return null;
      });
      addTearDown(
        () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final link = ResizingScreens();
      final host = HostState({'hostId': 'pc'}, MemorySecretStorage())
        ..link = link
        ..status = LinkStatus.online;
      await t.pumpWidget(
        MaterialApp(
          theme: dcTheme(Brightness.light),
          home: RemoteDesktopPage(host: host),
        ),
      );
      await flush(t);
      await pinch(t);
      expect(creates, 2);
      await t.pumpWidget(const SizedBox());
      await flush(t);
      creating.complete(8);
      await flush(t);
      expect(link.ready, [1]);
      expect(disposed.where((id) => id == 7).length, 1);
      expect(disposed.where((id) => id == 8).length, 1);
    },
  );
  testWidgets('a new-size decoder that cannot output falls back to JPEG once', (
    t,
  ) async {
    t.view.physicalSize = const Size(400, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    const channel = MethodChannel('dogcodes/h264');
    var creates = 0;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'create') return ++creates == 1 ? 7 : 8;
      if (call.method == 'decode' && call.arguments['id'] == 8) {
        throw PlatformException(code: 'needKeyframe');
      }
      if (call.method == 'stats') return {'decoded': 1};
      return null;
    });
    addTearDown(
      () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final link = ResizingScreens();
    final host = HostState({'hostId': 'pc'}, MemorySecretStorage())
      ..link = link
      ..status = LinkStatus.online;
    await t.pumpWidget(
      MaterialApp(
        theme: dcTheme(Brightness.light),
        home: RemoteDesktopPage(host: host),
      ),
    );
    await flush(t);
    await pinch(t);
    expect(creates, 2);
    await t.pump(const Duration(milliseconds: 3100));
    await flush(t);
    expect(link.opens.length, 2);
    expect(link.opens.last['videoTransport'], isNull);
    expect(creates, 2);
    await t.pumpWidget(const SizedBox());
    await flush(t);
  });
}
