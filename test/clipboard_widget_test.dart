import 'dart:convert';
import 'dart:async';
import 'package:dogcodes_app/core/adaptive_host_link.dart';
import 'package:dogcodes_app/core/protocol.dart';
import 'package:dogcodes_app/core/host_hub.dart';
import 'package:dogcodes_app/core/security/secret_storage.dart';
import 'package:dogcodes_app/features/computers/remote_desktop_page.dart';
import 'package:dogcodes_app/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'clipboard_transfer_test.dart' show ClipboardLink;
import 'remote_desktop_widget_test.dart' show DesktopLink;

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAABAAAAAKCAIAAAAy3EnLAAAAEUlEQVR4nGNoIBEwjGoYmhoAv1XwATGE43sAAAAASUVORK5CYII=',
);

Future<void> waitFor(WidgetTester t, bool Function() done) async {
  await t.runAsync(() async {
    for (var i = 0; i < 60 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await t.pump();
    }
  });
  await t.pump();
  expect(done(), isTrue);
}

class PermissionDeniedScreen extends DesktopLink {
  bool denied = false;
  @override
  Future<dynamic> call(String method, dynamic params) async {
    if (method == 'remote_desktop_open') {
      denied = true;
      throw const ProtocolException('屏幕录制权限不可用');
    }
    return super.call(method, params);
  }
}

void main() {
  testWidgets(
    'manual text/image actions use independent links and keep the screen alive',
    (t) async {
      final screen = DesktopLink(), main = ClipboardLink();
      final transfers = <ClipboardLink>[];
      var dials = 0;
      Future<HostLink> dial() async {
        if (dials++ == 0) return screen;
        final next = ClipboardLink()..clipboard = Uint8List.fromList(_png);
        transfers.add(next);
        return next;
      }

      final business = AdaptiveHostLink(
        relay: main,
        relayDialer: dial,
        directDialer: (_) async => throw StateError('no ICE'),
      );
      final host = HostState({'hostId': 'pc'}, MemorySecretStorage())
        ..link = business
        ..status = LinkStatus.online;
      final native = <String>[];
      Uint8List? copied;
      const channel = MethodChannel('dogcodes/clipboard');
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        native.add(call.method);
        if (call.method == 'readPng') return _png;
        if (call.method == 'writePng') {
          copied = (call.arguments as Map)['png'] as Uint8List;
        }
        return null;
      });
      try {
        await t.pumpWidget(
          MaterialApp(
            theme: dcTheme(Brightness.light),
            home: RemoteDesktopPage(host: host),
          ),
        );
        await waitFor(t, () => screen.frames.isNotEmpty);
        await t.tap(find.text('剪贴板'));
        await t.pump();
        await t.pump(const Duration(milliseconds: 350));
        expect(find.text('发送文字到电脑'), findsOneWidget);
        expect(find.text('从电脑获取文字'), findsOneWidget);
        expect(
          native,
          isEmpty,
        ); // Opening the menu never reads clipboard contents.
        await t.tap(find.text('发送图片到电脑'));
        await t.pump();
        await waitFor(
          t,
          () => transfers.isNotEmpty && transfers.first.closed > 0,
        );
        expect(transfers.first.clipboard, orderedEquals(_png));
        expect(transfers.first.writes, 1);
        expect(native, ['readPng']);
        expect(main.calls, isEmpty);
        expect(main.closed, 0);
        expect(find.byType(Image), findsOneWidget);
        await t.tap(find.text('剪贴板'));
        await t.pump();
        await t.pump(const Duration(milliseconds: 350));
        await t.tap(find.text('从电脑获取图片'));
        await t.pump();
        await waitFor(t, () => copied != null);
        expect(copied, orderedEquals(_png));
        expect(native, ['readPng', 'writePng']);
        expect(transfers, hasLength(2));
        expect(main.closed, 0);
        expect(screen.opens, hasLength(1));
      } finally {
        await t.pumpWidget(const SizedBox());
        await t.pump();
        await t.runAsync(business.close);
        t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
      }
    },
  );
  testWidgets(
    'denied image paste reports the error without opening a transfer',
    (t) async {
      final screen = DesktopLink(), main = ClipboardLink();
      var dials = 0;
      final business = AdaptiveHostLink(
        relay: main,
        relayDialer: () async {
          dials++;
          return screen;
        },
        directDialer: (_) async => throw StateError('unused'),
      );
      final host = HostState({'hostId': 'pc'}, MemorySecretStorage())
        ..link = business
        ..status = LinkStatus.online;
      const channel = MethodChannel('dogcodes/clipboard');
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async =>
            throw PlatformException(code: 'denied', message: '请允许粘贴图片'),
      );
      try {
        await t.pumpWidget(
          MaterialApp(
            theme: dcTheme(Brightness.light),
            home: RemoteDesktopPage(host: host),
          ),
        );
        await waitFor(t, () => screen.frames.isNotEmpty);
        await t.tap(find.text('剪贴板'));
        await t.pump();
        await t.pump(const Duration(milliseconds: 350));
        await t.tap(find.text('发送图片到电脑'));
        await t.pump();
        await t.pump(const Duration(milliseconds: 350));
        expect(find.text('请允许粘贴图片'), findsOneWidget);
        expect(dials, 1);
        expect(main.calls, isEmpty);
      } finally {
        await t.pumpWidget(const SizedBox());
        await t.pump();
        await t.runAsync(business.close);
        t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
      }
    },
  );
  testWidgets(
    'clipboard remains available when screen capture permission is unavailable',
    (t) async {
      final screen = PermissionDeniedScreen(),
          main = ClipboardLink(),
          transfer = ClipboardLink();
      var dials = 0;
      final business = AdaptiveHostLink(
        relay: main,
        relayDialer: () async => dials++ == 0 ? screen : transfer,
        directDialer: (_) async => throw StateError('no ICE'),
      );
      final host = HostState({'hostId': 'pc'}, MemorySecretStorage())
        ..link = business
        ..status = LinkStatus.online;
      const channel = MethodChannel('dogcodes/clipboard');
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => _png,
      );
      try {
        await t.pumpWidget(
          MaterialApp(
            theme: dcTheme(Brightness.light),
            home: RemoteDesktopPage(host: host),
          ),
        );
        await waitFor(t, () => screen.denied);
        await t.tap(find.text('剪贴板'));
        await t.pump();
        await t.pump(const Duration(milliseconds: 350));
        await t.tap(find.text('发送图片到电脑'));
        await t.pump();
        await waitFor(t, () => transfer.writes == 1);
        expect(transfer.clipboard, orderedEquals(_png));
        expect(main.calls, isEmpty);
        expect(main.closed, 0);
      } finally {
        await t.pumpWidget(const SizedBox());
        await t.pump();
        await t.runAsync(business.close);
        t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
      }
    },
  );
  testWidgets(
    'leaving the page cancels a pending native image write with the same identity',
    (t) async {
      final screen = DesktopLink(),
          main = ClipboardLink(),
          transfer = ClipboardLink()..clipboard = Uint8List.fromList(_png);
      var dials = 0;
      final business = AdaptiveHostLink(
        relay: main,
        relayDialer: () async => dials++ == 0 ? screen : transfer,
        directDialer: (_) async => throw StateError('no ICE'),
      );
      final host = HostState({'hostId': 'pc'}, MemorySecretStorage())
        ..link = business
        ..status = LinkStatus.online;
      final pending = Completer<void>();
      String? writeId, cancelId;
      const channel = MethodChannel('dogcodes/clipboard');
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        final args = call.arguments as Map;
        if (call.method == 'writePng') {
          writeId = args['id'] as String;
          await pending.future;
        }
        if (call.method == 'cancelWrite') {
          cancelId = args['id'] as String;
          pending.completeError(PlatformException(code: 'cancelled'));
          return true;
        }
        return null;
      });
      try {
        await t.pumpWidget(
          MaterialApp(
            theme: dcTheme(Brightness.light),
            home: RemoteDesktopPage(host: host),
          ),
        );
        await waitFor(t, () => screen.frames.isNotEmpty);
        await t.tap(find.text('剪贴板'));
        await t.pump();
        await t.pump(const Duration(milliseconds: 350));
        await t.tap(find.text('从电脑获取图片'));
        await t.pump();
        await waitFor(t, () => writeId != null);
        await t.pumpWidget(const SizedBox());
        await t.pump();
        await waitFor(t, () => cancelId != null);
        expect(cancelId, writeId);
        expect(main.closed, 0);
        expect(t.takeException(), isNull);
      } finally {
        await t.pumpWidget(const SizedBox());
        await t.pump();
        await t.runAsync(business.close);
        t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
      }
    },
  );
}
