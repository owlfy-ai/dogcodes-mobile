// Authoring harness: production widgets with isolated, fictional PC data.
// Run with STORE_CAPTURE_DIR set; never connects to a real computer.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:dogcodes_app/l10n/strings.dart';
import 'package:dogcodes_app/app.dart';
import 'package:dogcodes_app/core/host_hub.dart';
import 'package:dogcodes_app/core/access_client.dart';
import 'package:dogcodes_app/core/mobile_runtime.dart';
import 'package:dogcodes_app/core/preferences.dart';
import 'package:dogcodes_app/core/security/secret_storage.dart';
import 'package:dogcodes_app/features/conversation/conversation_page.dart';
import 'package:dogcodes_app/features/conversation/new_session_page.dart';
import 'package:dogcodes_app/features/conversation/agent_picker.dart';
import 'package:dogcodes_app/features/tools/terminal_page.dart';
import 'package:dogcodes_app/features/computers/remote_desktop_page.dart';
import 'package:dogcodes_app/features/tools/changes_page.dart';
import 'package:dogcodes_app/features/tools/run_page.dart';
import 'package:dogcodes_app/features/tools/tool_context.dart';
import 'package:dogcodes_app/ui/theme.dart';
import 'fixture.dart';

ThemeData storeTheme() {
  final theme = dcTheme(Brightness.light);
  return theme.copyWith(
    platform: TargetPlatform.iOS,
    chipTheme: theme.chipTheme.copyWith(
      labelStyle: theme.textTheme.labelLarge?.copyWith(
        fontFamily: 'StoreUI',
        fontFamilyFallback: const ['Symbols'],
      ),
    ),
    textTheme: theme.textTheme.apply(fontFamily: 'StoreUI'),
    primaryTextTheme: theme.primaryTextTheme.apply(fontFamily: 'StoreUI'),
    appBarTheme: theme.appBarTheme.copyWith(
      titleTextStyle: theme.appBarTheme.titleTextStyle?.copyWith(
        fontFamily: 'StoreUI',
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: theme.filledButtonTheme.style?.copyWith(
        textStyle: const WidgetStatePropertyAll(
          TextStyle(
            fontFamily: 'StoreUI',
            fontFamilyFallback: ['Symbols'],
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: theme.outlinedButtonTheme.style?.copyWith(
        textStyle: const WidgetStatePropertyAll(
          TextStyle(
            fontFamily: 'StoreUI',
            fontFamilyFallback: ['Symbols'],
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: theme.textButtonTheme.style?.copyWith(
        textStyle: const WidgetStatePropertyAll(
          TextStyle(
            fontFamily: 'StoreUI',
            fontFamilyFallback: ['Symbols'],
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    ),
  );
}

Future<void> font(String name, String path) async {
  final loader = FontLoader(name)
    ..addFont(File(path).readAsBytes().then((b) => ByteData.sublistView(b)));
  await loader.load();
}

void main() {
  final output = Platform.environment['STORE_CAPTURE_DIR'];
  testWidgets(
    'capture actual app pages for store artwork',
    skip: output == null,
    (t) async {
      await t.runAsync(() async {
        await font(
          'StoreUI',
          '/System/Library/Fonts/Supplemental/Arial Unicode.ttf',
        );
        await font('Menlo', '/System/Library/Fonts/Menlo.ttc');
        await font('Symbols', '/System/Library/Fonts/Apple Symbols.ttf');
        final packages =
            jsonDecode(
                  File('.dart_tool/package_config.json').readAsStringSync(),
                )
                as Map;
        final flutter = (packages['packages'] as List).firstWhere(
          (p) => p['name'] == 'flutter',
        );
        final sdk = Directory.fromUri(
          Uri.parse(flutter['rootUri'] as String),
        ).parent.parent;
        await font(
          'MaterialIcons',
          '${sdk.path}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        );
      });
      for (final (language, device) in [
        for (final language in ['zh-Hans', 'en-US'])
          for (final device in ['iphone', 'ipad']) (language, device),
      ]) {
        t.binding.platformDispatcher.localesTestValue = [
          Locale(language == 'en-US' ? 'en' : 'zh'),
        ];
        final baseSize = device == 'iphone'
            ? const Size(440, 956)
            : const Size(1032, 1376);
        for (var page = 0; page < 10; page++) {
          if (page == 9 && device == 'ipad') continue;
          final requested = Platform.environment['STORE_PAGES'];
          if (requested != null && !requested.split(',').contains('$page')) {
            continue;
          }
          final size = page == 9 ? const Size(956, 440) : baseSize;
          await t.binding.setSurfaceSize(size);
          debugDefaultTargetPlatformOverride = (page == 7 || page == 9)
              ? TargetPlatform.linux
              : null;
          final hub = HostHub(
            storage: MemorySecretStorage(),
            lister: () async => [
              {'hostId': 'store-mac', 'displayName': 'MacBook Pro'},
            ],
          );
          await hub.load(connect: false);
          await hub.attach(
            hub.hosts.single,
            StoreLink(
              approvals: page == 3,
              english: language == 'en-US',
              working: page == 0,
              plainTerminal: page == 5,
            ),
          );
          final host = hub.hosts.single, preferences = AppPreferences();
          final tool = ToolContext(host, host.projects.first);
          final key = GlobalKey();
          final navigation = GlobalKey<NavigatorState>();
          final Widget home = switch (page) {
            1 => const ConversationPage(hostId: 'store-mac', taskId: 't0'),
            5 => TerminalPage(tool: tool),
            7 || 9 => RemoteDesktopPage(host: host),
            8 => const NewSessionPage(hostId: 'store-mac', projectId: 'p1'),
            4 => ChangesPage(tool: tool),
            6 => RunPage(tool: tool),
            _ => const HomeShell(),
          };
          await t.pumpWidget(
            RepaintBoundary(
              key: key,
              child: AppScope(
                hub: hub,
                preferences: preferences,
                runtime: page == 2
                    ? MobileRuntime(storage: MemorySecretStorage())
                    : null,
                client: AccessClient(
                  Uri.parse('https://store-fixture.invalid'),
                ),
                child: MaterialApp(
                  navigatorKey: navigation,
                  supportedLocales: const [Locale('en'), Locale('zh')],
                  localizationsDelegates: GlobalMaterialLocalizations.delegates,
                  debugShowCheckedModeBanner: false,
                  theme: storeTheme(),
                  builder: (context, child) => MediaQuery(
                    data: MediaQueryData(
                      size: size,
                      devicePixelRatio: 1,
                      padding: EdgeInsets.only(
                        left: page == 9 ? 44 : 0,
                        right: page == 9 ? 44 : 0,
                        top: page == 9
                            ? 0
                            : device == 'iphone'
                            ? 59
                            : 28,
                        bottom: device == 'iphone' ? 34 : 24,
                      ),
                      disableAnimations: true,
                    ),
                    child: Stack(
                      children: [
                        Positioned.fill(child: child!),
                        if (page != 9)
                          Positioned(
                            top: device == 'iphone' ? 17 : 5,
                            left: 28,
                            right: 26,
                            child: Row(
                              children: [
                                const Text(
                                  '9:41',
                                  style: TextStyle(
                                    fontFamily: 'StoreUI',
                                    fontSize: 17,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.black,
                                    decoration: TextDecoration.none,
                                  ),
                                ),
                                const Spacer(),
                                const Icon(Icons.signal_cellular_alt, size: 18),
                                const SizedBox(width: 6),
                                const Icon(Icons.wifi, size: 18),
                                const SizedBox(width: 6),
                                Row(
                                  children: [
                                    Container(
                                      width: 24,
                                      height: 12,
                                      decoration: BoxDecoration(
                                        color: Colors.black,
                                        borderRadius: BorderRadius.circular(3),
                                      ),
                                    ),
                                    const SizedBox(width: 1),
                                    Container(
                                      width: 2,
                                      height: 5,
                                      decoration: BoxDecoration(
                                        color: Colors.black,
                                        borderRadius: BorderRadius.circular(1),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        if (device == 'iphone' && page != 9)
                          Positioned(
                            top: 10,
                            left: (size.width - 116) / 2,
                            width: 116,
                            height: 32,
                            child: Container(
                              decoration: BoxDecoration(
                                color: Colors.black,
                                borderRadius: BorderRadius.circular(24),
                              ),
                            ),
                          ),
                        if (page == 9)
                          Positioned(
                            left: 8,
                            top: (size.height - 116) / 2,
                            width: 32,
                            height: 116,
                            child: Container(
                              decoration: BoxDecoration(
                                color: Colors.black,
                                borderRadius: BorderRadius.circular(24),
                              ),
                            ),
                          ),
                        Positioned(
                          bottom: 8,
                          left: (size.width - 120) / 2,
                          width: 120,
                          height: 5,
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.black,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  home: const HomeShell(),
                ),
              ),
            ),
          );
          for (var tick = 0; tick < 20; tick++) {
            await t.pump(const Duration(milliseconds: 50));
          }
          if (![0, 2, 3].contains(page)) {
            navigation.currentState!.push(
              MaterialPageRoute<void>(builder: (_) => home),
            );
            for (var tick = 0; tick < 10; tick++) {
              await t.pump(const Duration(milliseconds: 50));
            }
          }
          await t.runAsync(() async {
            for (final name in ['claude-code', 'codex', 'cursor']) {
              await precacheImage(
                AssetImage('assets/agents/$name.png'),
                key.currentContext!,
              );
            }
          });
          if (page == 2) {
            await t.tap(find.text(tr('电脑')).last);
          }
          if (page == 3) {
            await t.tap(find.text(tr('待处理')).last);
          }
          if (page == 4) {
            await t.tap(find.text('search.ts').first);
            await t.enterText(
              find
                  .descendant(
                    of: find.byType(ChangesPage),
                    matching: find.byType(TextField),
                  )
                  .first,
              language == 'en-US'
                  ? 'Improve search and restore saved filters'
                  : '优化搜索与筛选条件恢复',
            );
          }
          if (page == 5) {
            await t.enterText(find.byType(TextField).last, 'pnpm run build');
          }
          if (page == 8) {
            await t.enterText(
              find.byType(TextField).first,
              language == 'en-US'
                  ? 'Review the sign-in flow and add integration tests.'
                  : '检查登录流程，并补上集成测试。',
            );
          }
          for (var tick = 0; tick < 12; tick++) {
            await t.pump(const Duration(milliseconds: 50));
          }
          if (page == 4) {
            final field = t.widget<TextField>(
              find
                  .descendant(
                    of: find.byType(ChangesPage),
                    matching: find.byType(TextField),
                  )
                  .first,
            );
            expect(field.controller!.text, isNotEmpty);
          }
          if (page == 1) {
            final context = navigation.currentState!.context;
            if (!context.mounted) return;
            showAgentSheet(context, host: host, taskId: 't0', initial: null);
            for (var tick = 0; tick < 12; tick++) {
              await t.pump(const Duration(milliseconds: 50));
            }
          }
          if (page == 7 || page == 9) {
            await t.runAsync(() async {
              await Future<void>.delayed(const Duration(milliseconds: 250));
            });
            await t.pump();
            await t.runAsync(() async {
              await Future<void>.delayed(const Duration(milliseconds: 100));
            });
            await t.pump();
          }
          expect(
            t.takeException(),
            isNull,
            reason: '$device page $page must render cleanly',
          );
          await t.runAsync(() async {
            final boundary =
                key.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await boundary.toImage(
              pixelRatio: device == 'iphone' ? 3 : 2,
            );
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File('$output/$language/$device-${page + 1}.png');
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
          await t.pumpWidget(const SizedBox());
          hub.dispose();
          preferences.dispose();
        }
      }
      debugDefaultTargetPlatformOverride = null;
      t.binding.platformDispatcher.clearLocalesTestValue();
      await t.binding.setSurfaceSize(null);
    },
  );
}
