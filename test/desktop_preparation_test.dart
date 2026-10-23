import 'dart:async';
import 'package:dogcodes_app/core/host_hub.dart';
import 'package:dogcodes_app/core/security/secret_storage.dart';
import 'package:dogcodes_app/features/computers/remote_desktop_page.dart';
import 'package:dogcodes_app/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'remote_desktop_widget_test.dart' show DesktopLink;

class PreparingLink extends DesktopLink {
  int preparations = 0;
  final requests = <Map<String, dynamic>>[];
  bool displaysRead = false;
  Completer<Map<String, dynamic>>? held;
  bool denied = false, revoked = false;
  @override
  Future<dynamic> call(String method, dynamic args) async {
    if (method == 'device_status') {
      return {'locked': false, 'desktopPreparationRequired': true};
    }
    if (method == 'remote_desktop_prepare') {
      expect(args['control'], true);
      requests.add(Map<String, dynamic>.from(args as Map));
      preparations++;
      if (held != null) return held!.future;
      if (denied) throw StateError('已在电脑上取消屏幕共享授权');
      return {'state': preparations == 1 ? 'pending' : 'ready'};
    }
    if (method == 'remote_desktop_frame' && revoked) {
      return {'authorizationEnded': true, 'error': '电脑已结束屏幕共享'};
    }
    if (method == 'remote_desktop_displays') displaysRead = true;
    return super.call(method, args);
  }
}

Future<void> show(WidgetTester tester, PreparingLink link) async {
  final host = HostState({'hostId': 'pc'}, MemorySecretStorage())
    ..link = link
    ..status = LinkStatus.online;
  await tester.pumpWidget(
    MaterialApp(
      theme: dcTheme(Brightness.light),
      home: RemoteDesktopPage(host: host),
    ),
  );
  for (var i = 0; i < 12; i++) {
    await tester.pump();
  }
}

void main() {
  testWidgets('waits for PC consent before enumerating or opening screens', (
    t,
  ) async {
    final link = PreparingLink();
    await show(t, link);
    expect(find.text('请在电脑上允许共享屏幕和键鼠控制'), findsOneWidget);
    expect(link.preparations, 1);
    expect(link.displaysRead, false);
    expect(link.opens, isEmpty);
    await t.pump(const Duration(milliseconds: 501));
    for (var i = 0; i < 12; i++) {
      await t.pump();
    }
    expect(link.preparations, 2);
    expect(link.displaysRead, true);
    expect(link.opens, hasLength(1));
    expect(find.text('请在电脑上允许共享屏幕和键鼠控制'), findsNothing);
    await t.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'revoking PC sharing stops the page without opening another picker',
    (t) async {
      final link = PreparingLink();
      await show(t, link);
      await t.pump(const Duration(milliseconds: 501));
      for (var i = 0; i < 12; i++) {
        await t.pump();
      }
      expect(link.opens, hasLength(1));
      link.revoked = true;
      await t.pump(const Duration(seconds: 1));
      for (var i = 0; i < 12; i++) {
        await t.pump();
      }
      expect(find.text('电脑已结束屏幕共享'), findsOneWidget);
      await t.pump(const Duration(seconds: 5));
      expect(link.preparations, 2);
      expect(link.opens, hasLength(1));
      await t.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('a single authorized screen can be explicitly reselected on PC', (
    t,
  ) async {
    final link = PreparingLink();
    await show(t, link);
    await t.pump(const Duration(milliseconds: 501));
    for (var i = 0; i < 12; i++) {
      await t.pump();
    }
    expect(link.opens, hasLength(1));
    await t.tap(find.byTooltip('切换屏幕'));
    await t.pumpAndSettle();
    await t.tap(find.text('重新选择共享屏幕'));
    for (var i = 0; i < 12; i++) {
      await t.pump();
    }
    expect(link.requests.last, {'control': true, 'fresh': true});
    expect(link.opens, hasLength(2));
    await t.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('late authorization after leaving cannot open a desktop lease', (
    t,
  ) async {
    final reply = Completer<Map<String, dynamic>>();
    final link = PreparingLink()..held = reply;
    await show(t, link);
    expect(link.preparations, 1);
    await t.pumpWidget(const SizedBox.shrink());
    reply.complete({'state': 'ready'});
    await t.pump(const Duration(seconds: 5));
    expect(link.displaysRead, false);
    expect(link.opens, isEmpty);
    expect(link.preparations, 1);
  });
  testWidgets(
    'cancelled PC authorization stops polling and reports the cause',
    (t) async {
      final link = PreparingLink()..denied = true;
      await show(t, link);
      expect(find.textContaining('已在电脑上取消屏幕共享授权'), findsOneWidget);
      await t.pump(const Duration(seconds: 5));
      expect(link.preparations, 1);
      expect(link.opens, isEmpty);
      await t.pumpWidget(const SizedBox.shrink());
    },
  );
}
