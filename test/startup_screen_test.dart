import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/app.dart';
import 'package:dogcodes_app/core/host_hub.dart';
import 'package:dogcodes_app/core/security/secret_storage.dart';
import 'package:dogcodes_app/ui/startup_screen.dart';
import 'package:dogcodes_app/features/devices/connect_gate.dart';
import 'widget_test.dart' show FakeLink;

void main() {
  testWidgets(
    'startup covers local initialization and exits as soon as it is ready',
    (t) async {
      final records = Completer<List<Map<String, dynamic>>>();
      final hub = HostHub(
        storage: MemorySecretStorage(),
        lister: () => records.future,
      );
      await t.pumpWidget(DogCodesApp(hub: hub));
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byType(StartupScreen), findsOneWidget);
      expect(find.bySemanticsLabel('dog.codes'), findsOneWidget);
      expect(find.text('正在准备工作区'), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      records.complete([]);
      await t.pumpAndSettle();
      expect(find.byType(StartupScreen), findsNothing);
      // Nothing works without a computer: first run is the pairing step.
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.byType(ConnectGate), findsOneWidget);
      expect(find.text('把电脑上的工作带在身边'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      hub.dispose();
    },
  );

  testWidgets(
    'offline computers do not hold the startup screen waiting for a network',
    (t) async {
      final connection = Completer<FakeLink>();
      final hub = HostHub(
        storage: MemorySecretStorage(),
        lister: () async => [
          {'hostId': 'offline-pc'},
        ],
        connector: (_) => connection.future,
      );
      await t.pumpWidget(DogCodesApp(hub: hub));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(hub.loaded, isTrue);
      expect(connection.isCompleted, isFalse);
      expect(find.byType(StartupScreen), findsNothing);
      // Paired before: wait on a connecting step, not the startup artwork.
      expect(find.byType(ConnectGate), findsOneWidget);
      expect(find.textContaining('正在连接'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      hub.dispose();
      connection.complete(FakeLink('offline-pc'));
      await t.pump();
    },
  );

  testWidgets(
    'local storage failure opens the recoverable app instead of trapping startup',
    (t) async {
      final hub = HostHub(
        storage: MemorySecretStorage(),
        lister: () async => throw StateError('fixture storage unavailable'),
      );
      await t.pumpWidget(DogCodesApp(hub: hub));
      await t.pumpAndSettle();
      expect(hub.loadError, isNotNull);
      expect(find.byType(StartupScreen), findsNothing);
      expect(find.byType(ConnectGate), findsOneWidget);
      expect(find.text(hub.loadError!), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      hub.dispose();
    },
  );

  testWidgets(
    'reduced motion startup is static and fits compact screens and large text',
    (t) async {
      await t.binding.setSurfaceSize(const Size(320, 568));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 568),
              disableAnimations: true,
              textScaler: TextScaler.linear(2),
            ),
            child: const StartupScreen(),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(t.binding.hasScheduledFrame, isFalse);
      expect(find.bySemanticsLabel('正在准备工作区'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('launch artwork preview', (t) async {
    await t.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => t.binding.setSurfaceSize(null));
    final capture = GlobalKey();
    await t.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: capture,
          child: const MediaQuery(
            data: MediaQueryData(
              size: Size(390, 844),
              padding: EdgeInsets.only(top: 59, bottom: 34),
              disableAnimations: true,
            ),
            child: StartupScreen(),
          ),
        ),
      ),
    );
    await t.runAsync(
      () => precacheImage(
        const AssetImage('assets/branding/launch-lockup.png'),
        capture.currentContext!,
      ),
    );
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    final output = Platform.environment['DOGCODES_STARTUP_PREVIEW'];
    if (output != null) {
      await t.runAsync(() async {
        final boundary =
            capture.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final rendered = await boundary.toImage(pixelRatio: 3);
        final bytes = await rendered.toByteData(format: ui.ImageByteFormat.png);
        await File(output).writeAsBytes(bytes!.buffer.asUint8List());
        rendered.dispose();
      });
    }
  });
}
