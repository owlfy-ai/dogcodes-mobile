import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/core/host_hub.dart';
import 'package:dogcodes_app/core/security/secret_storage.dart';
import 'package:dogcodes_app/features/computers/remote_desktop_page.dart';
import 'package:dogcodes_app/features/computers/video_recovery.dart';
import 'package:dogcodes_app/ui/theme.dart';
import 'video_resolution_widget_test.dart' show ResizingScreens, flush;

class RecoveringScreens extends ResizingScreens {
  String phase = 'ready';
  @override
  Map<String, dynamic> get description => {
    ...super.description,
    'codecReady': phase != 'restarting',
    'ready': ready.contains(generation),
    'resize': {
      ...super.description['resize'] as Map,
      'state': phase == 'restarting' ? 'updating' : 'ready',
    },
  };
  @override
  Future<dynamic> call(String method, dynamic args) async {
    if (method == 'remote_desktop_open' && args['video'] != true) {
      opens.add(Map<String, dynamic>.from(args as Map));
      return {
        'leaseId': 'lease',
        'inputSequence': '0',
        'maxFps': 25,
        'inputBatch': 64,
      };
    }
    final result = await super.call(method, args);
    if (method == 'remote_desktop_video' && args['ready'] != true) {
      result['recovery'] = {'state': phase};
    }
    return result;
  }
}

void main() {
  test('warmup status cannot reset the local recovery deadline', () {
    final recovery = VideoRecovery();
    const scope = (1, 0);
    expect(
      recovery.observe({'state': 'restarting'}, Duration.zero, scope: scope),
      false,
    );
    expect(recovery.active, true);
    expect(
      recovery.observe(
        {'state': 'warming'},
        const Duration(seconds: 19),
        scope: scope,
      ),
      false,
    );
    expect(
      recovery.observe(
        {'state': 'restarting', 'timeoutMs': 99999999},
        const Duration(seconds: 20),
        scope: scope,
      ),
      true,
    );
    expect(
      recovery.observe(
        {'state': 'warming'},
        const Duration(seconds: 21),
        scope: (1, 1),
      ),
      false,
    );
    expect(
      recovery.observe(
        {'state': 'ready'},
        const Duration(seconds: 22),
        scope: (1, 1),
      ),
      false,
    );
    expect(
      recovery.active,
      true,
      reason: 'PC ready is not proof of phone decoding',
    );
    recovery.decoded();
    expect(recovery.active, false);
    expect(
      recovery.observe(
        {'state': 'warming'},
        const Duration(seconds: 23),
        scope: (1, 1),
      ),
      false,
    );
    expect(
      recovery.active,
      false,
      reason: 'a repeated old status cannot freeze input again',
    );
    recovery.observe(
      {'state': 'restarting', 'attempts': 1},
      const Duration(seconds: 24),
      scope: (1, 1),
    );
    expect(recovery.active, true);
  });

  test(
    'ordinary geometry changes also wait for decoding and later changes rearm',
    () {
      final recovery = VideoRecovery();
      const scope = (1, 0);
      recovery.observe(
        {'state': 'ready'},
        Duration.zero,
        scope: scope,
        changing: true,
      );
      expect(recovery.active, true);
      recovery.observe(
        {'state': 'ready'},
        const Duration(seconds: 1),
        scope: scope,
      );
      expect(recovery.active, true);
      recovery.decoded();
      expect(recovery.active, false);
      recovery.observe(
        {'state': 'ready'},
        const Duration(seconds: 2),
        scope: scope,
        changing: true,
      );
      expect(recovery.active, true);
      expect(
        recovery.observe(
          {'state': 'ready'},
          const Duration(seconds: 22),
          scope: scope,
          changing: true,
        ),
        true,
      );
    },
  );

  testWidgets(
    'runtime recovery keeps the lease and old picture until the replacement decodes',
    (t) async {
      const channel = MethodChannel('dogcodes/h264');
      final formats = <Map>[], counts = <int, int>{}, disposed = <int>[];
      final replacement = Completer<void>();
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        final id = (call.arguments as Map?)?['id'] as int?;
        if (call.method == 'create') {
          formats.add(Map.of(call.arguments as Map));
          return formats.length == 1 ? 7 : 8;
        }
        if (call.method == 'decode') {
          if (id == 8) await replacement.future;
          counts[id!] = (counts[id] ?? 0) + 1;
        }
        if (call.method == 'stats') return {'decoded': counts[id] ?? 0};
        if (call.method == 'dispose') disposed.add(id!);
        return null;
      });
      addTearDown(
        () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final link = RecoveringScreens();
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
      expect(t.widget<Texture>(find.byType(Texture)).textureId, 7);
      final center = t.getRect(find.byType(Texture)).center;
      await t.tapAt(center);
      await flush(t);
      final beforeFrozen = link.inputs.length;
      expect(beforeFrozen, greaterThan(0));
      link.phase = 'restarting';
      for (var i = 0; i < 6; i++) {
        await t.pump(const Duration(seconds: 1));
        await flush(t);
      }
      expect(find.textContaining('电脑画面正在恢复'), findsWidgets);
      await t.tapAt(center);
      await flush(t);
      expect(
        link.inputs.length,
        beforeFrozen,
        reason: 'frozen picture clicks must not enter the input queue',
      );
      expect(link.opens, hasLength(1));
      expect(link.frames, isEmpty);
      expect(formats, hasLength(1));
      link.phase = 'warming';
      link.generation++;
      await t.pump(const Duration(seconds: 1));
      await flush(t);
      expect(link.ready, [1, 2]);
      expect(formats, hasLength(2));
      expect(t.widget<Texture>(find.byType(Texture)).textureId, 7);
      expect(disposed, isNot(contains(7)));
      replacement.complete();
      await flush(t);
      expect(t.widget<Texture>(find.byType(Texture)).textureId, 8);
      expect(disposed.where((id) => id == 7), hasLength(1));
      expect(
        link.inputs.length,
        beforeFrozen,
        reason: 'restoring the picture must not replay frozen clicks',
      );
      await t.tapAt(t.getRect(find.byType(Texture)).center);
      await flush(t);
      expect(link.inputs.length, greaterThan(beforeFrozen));
      link.phase = 'ready';
      await t.pump(const Duration(seconds: 1));
      await flush(t);
      expect(find.textContaining('电脑画面正在恢复'), findsNothing);
      expect(link.opens, hasLength(1));
      expect(link.frames, isEmpty);
      await t.pumpWidget(const SizedBox());
      await flush(t);
    },
  );

  testWidgets('stuck PC recovery has a finite local wait before image fallback', (
    t,
  ) async {
    const channel = MethodChannel('dogcodes/h264');
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'create') return 7;
      if (call.method == 'stats') return {'decoded': 1};
      return null;
    });
    addTearDown(
      () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    var elapsed = Duration.zero;
    final link = RecoveringScreens();
    final host = HostState({'hostId': 'pc'}, MemorySecretStorage())
      ..link = link
      ..status = LinkStatus.online;
    await t.pumpWidget(
      MaterialApp(
        theme: dcTheme(Brightness.light),
        home: RemoteDesktopPage(host: host, recoveryClock: () => elapsed),
      ),
    );
    await flush(t);
    link.phase = 'restarting';
    for (var i = 0; i < 23; i++) {
      elapsed += const Duration(seconds: 1);
      await t.pump(const Duration(seconds: 1));
      await flush(t);
    }
    expect(
      find.textContaining('电脑画面恢复超时'),
      findsWidgets,
      reason:
          'opens=${link.opens.length}, controls=${link.controls.length}, elapsed=$elapsed',
    );
    for (var i = 0; i < 8 && link.frames.isEmpty; i++) {
      await t.pump(const Duration(seconds: 1));
      await flush(t);
    }
    expect(link.frames, isNotEmpty);
    await t.pumpWidget(const SizedBox());
    await flush(t);
  });
}
