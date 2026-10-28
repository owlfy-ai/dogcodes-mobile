import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/core/host_hub.dart';
import 'package:dogcodes_app/core/security/secret_storage.dart';
import 'package:dogcodes_app/features/computers/remote_desktop_page.dart';
import 'package:dogcodes_app/ui/theme.dart';
import 'relay_video_test.dart' show frame;
import 'video_recovery_test.dart' show ReadyScreens;
import 'video_resolution_widget_test.dart' show flush;

void main() {
  testWidgets(
    'local decode recovery blocks old-picture clicks until a new IDR outputs',
    (t) async {
      const channel = MethodChannel('dogcodes/h264');
      var failNext = false, holdKey = false, decoded = 0;
      final replacement = Completer<void>();
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'create') return 7;
        if (call.method == 'decode') {
          if (failNext) {
            failNext = false;
            throw PlatformException(code: 'needKeyframe');
          }
          if (holdKey) await replacement.future;
          decoded++;
        }
        if (call.method == 'stats') return {'decoded': decoded};
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
      await flush(t);
      expect(decoded, 1);
      final center = t.getRect(find.byType(Texture)).center;
      await t.tapAt(center);
      await flush(t);
      var before = link.inputs.length;
      expect(before, greaterThan(0));

      final drag = await t.startGesture(center);
      await t.pump(const Duration(milliseconds: 20));
      await drag.moveBy(const Offset(20, 0));
      await flush(t);
      final heldButton = link.inputs
          .expand((r) => r['events'] as List)
          .where((event) => event['kind'] == 'button')
          .last;
      expect(heldButton['direction'], 'press');
      before = link.inputs.length;

      failNext = true;
      link.pushed.add({
        ...frame(++link.sequence),
        'leaseId': 'lease',
        'generation': link.generation,
      });
      await flush(t);
      expect(link.inputs.skip(before).expand((r) => r['events'] as List), [
        {'kind': 'button', 'button': 'left', 'direction': 'release'},
      ], reason: 'release our held remote button as soon as references fail');
      before = link.inputs.length;
      await drag.up();
      await flush(t);
      expect(link.inputs.length, before, reason: 'held button released once');
      // The PC is healthy. Its ordinary heartbeat must not thaw a decoder
      // which has lost its local reference chain.
      await t.pump(const Duration(seconds: 1));
      await flush(t);
      await t.tapAt(center);
      await flush(t);
      expect(link.inputs.length, before, reason: 'known stale picture');
      expect(find.text('画面正在恢复'), findsWidgets);

      holdKey = true;
      link.pushed.add({
        ...frame(++link.sequence, key: true),
        'leaseId': 'lease',
        'generation': link.generation,
      });
      await flush(t);
      await t.tapAt(center);
      await flush(t);
      expect(link.inputs.length, before, reason: 'IDR has not output yet');
      replacement.complete();
      await flush(t);
      expect(decoded, 2);
      expect(find.text('画面正在恢复'), findsNothing);
      expect(link.inputs.length, before, reason: 'never replay frozen clicks');
      await t.tapAt(center);
      await flush(t);
      expect(link.inputs.length, greaterThan(before));
      expect(link.opens, hasLength(1));
      await t.pumpWidget(const SizedBox());
      await flush(t);
    },
  );
}
