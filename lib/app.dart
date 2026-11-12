import 'package:dogcodes_app/l10n/strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'core/access_client.dart';
import 'core/host_hub.dart';
import 'core/mobile_runtime.dart';
import 'core/preferences.dart';
import 'core/security/secret_storage.dart';
import 'demo/demo_banner.dart';
import 'demo/demo_link.dart';
import 'features/computers/computers_page.dart';
import 'features/inbox/pending_page.dart';
import 'features/sessions/sessions_page.dart';
import 'features/workspace/workspace_page.dart';
import 'ui/theme.dart';
import 'ui/startup_screen.dart';
import 'features/conversation/conversation_page.dart';
import 'features/devices/connect_gate.dart';

/// Shared app services for every page below the shell.
class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.hub,
    required this.preferences,
    required this.runtime,
    required this.client,
    this.demo = false,
    required super.child,
  });
  final HostHub hub;
  final AppPreferences preferences;
  final MobileRuntime? runtime;
  final AccessClient? client;

  /// The fictional example computer is shown (示例模式). Pairing, push and
  /// the device's own services are unavailable then: [runtime] and [client]
  /// are null.
  final bool demo;
  static AppScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!;
  @override
  bool updateShouldNotify(AppScope old) =>
      hub != old.hub || preferences != old.preferences || demo != old.demo;
}

class DogCodesApp extends StatefulWidget {
  const DogCodesApp({super.key, this.client, this.runtime, this.hub});
  final AccessClient? client;
  final MobileRuntime? runtime;
  final HostHub? hub;

  /// Opens the example computer, kept in memory only, without pairing.
  static Future<void> enterDemo(BuildContext context) async =>
      context.findAncestorStateOfType<_DogCodesAppState>()?._enterDemo();

  /// Leaves the example and discards everything done in it.
  static void exitDemo(BuildContext context) =>
      context.findAncestorStateOfType<_DogCodesAppState>()?._exitDemo();
  @override
  State<DogCodesApp> createState() => _DogCodesAppState();
}

class _DogCodesAppState extends State<DogCodesApp> {
  late final AppPreferences preferences;
  late final HostHub _paired;

  /// The example's own hub while 示例模式 is open; never the paired one.
  HostHub? _demo;
  HostHub get hub => _demo ?? _paired;
  final navigator = GlobalKey<NavigatorState>();
  final messenger = GlobalKey<ScaffoldMessengerState>();
  bool _pushScheduled = false;

  /// Set once a computer was reachable (or offline records were chosen);
  /// later drops then show banners inside the tabs instead of the gate.
  bool _entered = false;
  @override
  void initState() {
    super.initState();
    final runtime = widget.runtime;
    preferences = AppPreferences(runtime?.storage)..load();
    _paired =
        widget.hub ??
        HostHub(
          storage: runtime?.storage ?? MemorySecretStorage(),
          connector: runtime?.reconnect,
          lister: runtime == null ? null : () => runtime.hosts.list(),
          forgetter: runtime?.hosts.forget,
          local: runtime?.local,
        );
    if (runtime != null) {
      runtime.push.addListener(_pushChanged);
      _paired.addListener(_pushChanged);
      runtime.push.initialize(_paired);
    }
    if (!_paired.loaded) {
      if (runtime == null) {
        _paired.load();
      } else {
        runtime.initialize().then((_) {
          if (mounted) _paired.load();
        });
      }
    }
  }

  Future<void> _enterDemo() async {
    if (_demo != null) return;
    final demo = HostHub(
      storage: MemorySecretStorage(),
      lister: () async => [
        {'hostId': DemoLink.id, 'displayName': tr("示例电脑")},
      ],
    );
    await demo.load(connect: false);
    await demo.attach(demo.hosts.single, DemoLink());
    if (!mounted || _demo != null) {
      demo.dispose();
      return;
    }
    navigator.currentState?.popUntil((r) => r.isFirst);
    setState(() => _demo = demo);
  }

  void _exitDemo() {
    final demo = _demo;
    if (demo == null) return;
    navigator.currentState?.popUntil((r) => r.isFirst);
    messenger.currentState?.clearSnackBars();
    setState(() => _demo = null);
    // Pages leaving with the example may still read it during this frame.
    WidgetsBinding.instance.addPostFrameCallback((_) => demo.dispose());
    _pushChanged();
  }

  @override
  void dispose() {
    if (widget.runtime != null) {
      widget.runtime!.push.removeListener(_pushChanged);
      _paired.removeListener(_pushChanged);
      widget.runtime!.push.dispose();
    }
    _demo?.dispose();
    if (widget.hub == null) _paired.dispose();
    preferences.dispose();
    super.dispose();
  }

  void _pushChanged() {
    if (!mounted ||
        _demo != null ||
        !hub.loaded ||
        _pushScheduled ||
        widget.runtime?.push.hasPendingOpen != true) {
      return;
    }
    _pushScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _pushScheduled = false;
      if (!mounted || navigator.currentState == null) return;
      final runtime = widget.runtime;
      final opened = runtime?.push.takeOpen();
      if (runtime == null || opened == null) return;
      final host = hub.host(opened.hostId);
      if (host == null) {
        messenger.currentState?.showSnackBar(
          SnackBar(content: Text(tr("这台电脑已移除，请核实电脑列表中的绑定。"))),
        );
        return;
      }
      try {
        final record = await runtime.hosts.read(host.id);
        if (!mounted) return;
        if (record == null ||
            record['bindingEpoch'] != host.bindingEpoch ||
            hub.host(host.id) != host) {
          messenger.currentState?.showSnackBar(
            SnackBar(content: Text(tr("电脑绑定已改变，请从电脑列表重新打开。"))),
          );
          return;
        }
      } catch (_) {
        if (mounted) {
          messenger.currentState?.showSnackBar(
            SnackBar(content: Text(tr("暂时无法读取电脑绑定，请稍后重试。"))),
          );
        }
        return;
      }
      if (!host.online) hub.connect(host);
      navigator.currentState?.push(
        MaterialPageRoute<void>(
          builder: (_) =>
              ConversationPage(hostId: host.id, taskId: opened.taskId),
        ),
      );
    });
  }

  Widget _home() {
    if (_demo != null) return const HomeShell(key: ValueKey('demo'));
    if (!hub.loaded) return const StartupScreen(key: ValueKey('startup'));
    final phase = gatePhase(hub);
    if (hub.hosts.isEmpty) _entered = false;
    if (phase == null) _entered = true;
    if (_entered) return const HomeShell(key: ValueKey('home'));
    final cached = hub.hosts.any((h) => h.snapshot != null);
    return ConnectGate(
      key: const ValueKey('gate'),
      phase: phase!,
      onBrowseOffline: cached ? () => setState(() => _entered = true) : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final demo = _demo != null;
    return AppScope(
      hub: hub,
      preferences: preferences,
      runtime: demo ? null : widget.runtime,
      client: demo ? null : widget.client,
      demo: demo,
      child: ListenableBuilder(
        listenable: preferences,
        builder: (context, _) => MaterialApp(
          navigatorKey: navigator,
          scaffoldMessengerKey: messenger,
          title: 'DogCodes',
          supportedLocales: [for (final l in appLanguages) l.locale],
          // Widgets follow the language chosen in 偏好设置; tr() reads the
          // same override.
          locale: appLanguages
              .where((l) => l.id == preferences.language)
              .firstOrNull
              ?.locale,
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          debugShowCheckedModeBanner: false,
          theme: dcTheme(Brightness.light),
          darkTheme: dcTheme(Brightness.dark),
          themeMode: preferences.themeMode,
          builder: (context, child) =>
              DemoFrame(visible: demo, child: child ?? const SizedBox()),
          home: ListenableBuilder(
            listenable: hub,
            builder: (context, _) => AnimatedSwitcher(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 180),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              child: _home(),
            ),
          ),
        ),
      ),
    );
  }
}

/// Four root entries in fixed order: 会话、工作区、待处理、电脑.
/// Only root pages show this bar; detail pages are pushed with a back button.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  static void select(BuildContext context, int index) =>
      context.findAncestorStateOfType<_HomeShellState>()?.select(index);
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  int tab = 0;
  void select(int index) => setState(() => tab = index);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      final scope = AppScope.of(context);
      scope.hub.resume();
      scope.runtime?.push.refresh();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final hub = AppScope.of(context).hub;
    return AnnotatedRegion(
      value: overlayStyle(Theme.of(context).brightness),
      child: Scaffold(
        body: SafeArea(
          bottom: false,
          child: IndexedStack(
            index: tab,
            children: const [
              SessionsPage(),
              WorkspacePage(),
              PendingPage(),
              ComputersPage(),
            ],
          ),
        ),
        bottomNavigationBar: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: context.dc.line)),
          ),
          child: ListenableBuilder(
            listenable: hub,
            builder: (context, _) {
              final pending = hub.pendingCount;
              return NavigationBar(
                selectedIndex: tab,
                onDestinationSelected: select,
                destinations: [
                  NavigationDestination(
                    icon: Icon(Icons.chat_bubble_outline),
                    selectedIcon: Icon(Icons.chat_bubble),
                    label: tr("会话"),
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.folder_outlined),
                    selectedIcon: Icon(Icons.folder),
                    label: tr("项目"),
                  ),
                  NavigationDestination(
                    icon: Badge(
                      isLabelVisible: pending > 0,
                      label: Text('$pending'),
                      child: const Icon(Icons.error_outline),
                    ),
                    selectedIcon: Badge(
                      isLabelVisible: pending > 0,
                      label: Text('$pending'),
                      child: const Icon(Icons.error),
                    ),
                    label: tr("待处理"),
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.computer_outlined),
                    selectedIcon: Icon(Icons.computer),
                    label: tr("电脑"),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
