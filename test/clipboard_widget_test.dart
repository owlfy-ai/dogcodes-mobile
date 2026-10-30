import 'dart:convert';
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

/// The phone clipboard, through Flutter's platform channel.
class PhoneClipboard {
  PhoneClipboard(WidgetTester t, {this.text}) : _t = t {
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        switch (call.method) {
          case 'Clipboard.getData':
            reads++;
            return text == null ? null : {'text': text};
          case 'Clipboard.setData':
            text = (call.arguments as Map)['text'] as String?;
            writes++;
        }
        return null;
      },
    );
  }
  final WidgetTester _t;
  String? text;
  int reads = 0, writes = 0;
  void dispose() => _t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    null,
  );
}

typedef Fixture = ({
  DesktopLink screen,
  ClipboardLink main,
  List<ClipboardLink> transfers,
  AdaptiveHostLink business,
});

Future<Fixture> open(
  WidgetTester t, {
  DesktopLink? screen,
  ClipboardLink Function()? transfer,
}) async {
  final s = screen ?? DesktopLink(), main = ClipboardLink();
  final transfers = <ClipboardLink>[];
  var dials = 0;
  final business = AdaptiveHostLink(
    relay: main,
    relayDialer: () async {
      if (dials++ == 0) return s;
      final next = transfer?.call() ?? ClipboardLink();
      transfers.add(next);
      return next;
    },
    directDialer: (_) async => throw StateError('no ICE'),
  );
  final host = HostState({'hostId': 'pc'}, MemorySecretStorage())
    ..link = business
    ..status = LinkStatus.online;
  await t.pumpWidget(
    MaterialApp(
      theme: dcTheme(Brightness.light),
      home: RemoteDesktopPage(host: host),
    ),
  );
  return (screen: s, main: main, transfers: transfers, business: business);
}

Future<void> close(WidgetTester t, Fixture f) async {
  await t.pumpWidget(const SizedBox());
  await t.pump();
  await t.runAsync(f.business.close);
}

Future<void> menu(WidgetTester t, String action) async {
  await t.tap(find.text('剪贴板'));
  await t.pump();
  await t.pump(const Duration(milliseconds: 350));
  await t.tap(find.text(action));
  await t.pump();
  await t.pump(const Duration(milliseconds: 350));
}

void main() {
  testWidgets('the menu offers text only and reads nothing until chosen', (
    t,
  ) async {
    final phone = PhoneClipboard(t, text: 'secret');
    final f = await open(t);
    try {
      await waitFor(t, () => f.screen.frames.isNotEmpty);
      await t.tap(find.text('剪贴板'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 350));
      expect(find.text('发送文字到电脑'), findsOneWidget);
      expect(find.text('从电脑获取文字'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.textContaining('图片'),
        ),
        findsNothing,
      );
      expect(phone.reads, 0);
    } finally {
      await close(t, f);
      phone.dispose();
    }
  });

  testWidgets('send lets the user edit the phone text before it leaves', (
    t,
  ) async {
    final phone = PhoneClipboard(t, text: 'hello');
    final f = await open(t);
    try {
      await waitFor(t, () => f.screen.frames.isNotEmpty);
      await menu(t, '发送文字到电脑');
      expect(phone.reads, 1);
      // Nothing is sent before the user confirms.
      expect(f.transfers, isEmpty);
      final field = find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byType(TextField),
      );
      expect(t.widget<TextField>(field).controller!.text, 'hello');
      await t.enterText(field, 'hello 世界');
      await t.pump();
      expect(find.text('8 个字符'), findsOneWidget);
      await t.tap(find.text('仅发送'));
      await t.pump();
      await waitFor(
        t,
        () => f.transfers.isNotEmpty && f.transfers.first.writes == 1,
      );
      expect(utf8.decode(f.transfers.first.clipboard), 'hello 世界');
      await t.pump(const Duration(milliseconds: 100));
      expect(find.text('已发送到电脑剪贴板，可在电脑上粘贴'), findsOneWidget);
      expect(f.main.calls, isEmpty);
      expect(f.screen.opens, hasLength(1));
    } finally {
      await close(t, f);
      phone.dispose();
    }
  });

  testWidgets('send and paste presses the computer paste shortcut', (t) async {
    final phone = PhoneClipboard(t, text: 'npm test');
    final f = await open(
      t,
      transfer: () => ClipboardLink()..platform = 'macos',
    );
    try {
      await waitFor(t, () => f.screen.frames.isNotEmpty);
      await menu(t, '发送文字到电脑');
      await t.tap(find.text('发送并粘贴'));
      await t.pump();
      await waitFor(t, () => f.screen.log.any((e) => e.endsWith(':key-press')));
      final keys = [
        for (final r in f.screen.inputs)
          for (final e in r['events'] as List)
            if (e['kind'] == 'key') '${e['key']}-${e['direction']}',
      ];
      expect(keys, ['meta-press', 'v-press', 'v-release', 'meta-release']);
      expect(utf8.decode(f.transfers.single.clipboard), 'npm test');
      expect(find.text('已粘贴到电脑'), findsOneWidget);
    } finally {
      await close(t, f);
      phone.dispose();
    }
  });

  testWidgets('an empty phone clipboard opens an empty editor', (t) async {
    final phone = PhoneClipboard(t);
    final f = await open(t);
    try {
      await waitFor(t, () => f.screen.frames.isNotEmpty);
      await menu(t, '发送文字到电脑');
      expect(find.text('粘贴或输入要发送到电脑的文字'), findsOneWidget);
      final send = t.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, '仅发送'),
      );
      expect(send.onPressed, isNull);
    } finally {
      await close(t, f);
      phone.dispose();
    }
  });

  testWidgets('get copies to the phone and shows what arrived', (t) async {
    final phone = PhoneClipboard(t);
    final f = await open(
      t,
      transfer: () =>
          ClipboardLink()
            ..clipboard = Uint8List.fromList(utf8.encode('from pc')),
    );
    try {
      await waitFor(t, () => f.screen.frames.isNotEmpty);
      await menu(t, '从电脑获取文字');
      await waitFor(t, () => phone.text == 'from pc');
      await t.pump(const Duration(milliseconds: 350));
      expect(find.text('已复制到手机剪贴板'), findsOneWidget);
      expect(find.text('from pc'), findsOneWidget);
      expect(find.text('7 个字符'), findsOneWidget);
      expect(f.main.closed, 0);
    } finally {
      await close(t, f);
      phone.dispose();
    }
  });

  testWidgets('an empty computer clipboard explains what to do', (t) async {
    final phone = PhoneClipboard(t, text: 'keep');
    final f = await open(t);
    try {
      await waitFor(t, () => f.screen.frames.isNotEmpty);
      await menu(t, '从电脑获取文字');
      await waitFor(t, () => f.transfers.isNotEmpty);
      await t.pump(const Duration(milliseconds: 350));
      expect(find.text('电脑剪贴板里没有文字，先在电脑上复制后再试'), findsOneWidget);
      expect(phone.text, 'keep');
      expect(phone.writes, 0);
    } finally {
      await close(t, f);
      phone.dispose();
    }
  });

  testWidgets(
    'clipboard remains available when screen capture permission is unavailable',
    (t) async {
      final phone = PhoneClipboard(t, text: 'still works');
      final f = await open(t, screen: PermissionDeniedScreen());
      try {
        await waitFor(t, () => (f.screen as PermissionDeniedScreen).denied);
        await menu(t, '发送文字到电脑');
        // No live screen means no input channel: paste is not offered.
        expect(find.text('发送并粘贴'), findsNothing);
        await t.tap(find.text('仅发送'));
        await t.pump();
        await waitFor(
          t,
          () => f.transfers.isNotEmpty && f.transfers.first.writes == 1,
        );
        expect(utf8.decode(f.transfers.first.clipboard), 'still works');
        expect(f.main.calls, isEmpty);
      } finally {
        await close(t, f);
        phone.dispose();
      }
    },
  );
}
