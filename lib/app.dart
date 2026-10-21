import 'package:flutter/material.dart';
import 'core/access_client.dart';
import 'core/host_hub.dart';
import 'core/mobile_runtime.dart';
import 'core/preferences.dart';
import 'core/security/secret_storage.dart';
import 'features/computers/computers_page.dart';
import 'features/inbox/pending_page.dart';
import 'features/sessions/sessions_page.dart';
import 'features/workspace/workspace_page.dart';
import 'ui/theme.dart';

/// Shared app services for every page below the shell.
class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.hub,
    required this.preferences,
    required this.runtime,
    required this.client,
    required super.child,
  });
  final HostHub hub;
  final AppPreferences preferences;
  final MobileRuntime? runtime;
  final AccessClient? client;
  static AppScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!;
  @override
  bool updateShouldNotify(AppScope old) =>
      hub != old.hub || preferences != old.preferences;
}

class DogCodesApp extends StatefulWidget {
  const DogCodesApp({super.key, this.client, this.runtime, this.hub});
  final AccessClient? client;
  final MobileRuntime? runtime;
  final HostHub? hub;
  @override
  State<DogCodesApp> createState() => _DogCodesAppState();
}

class _DogCodesAppState extends State<DogCodesApp> {
  late final AppPreferences preferences;
  late final HostHub hub;
  @override
  void initState() {
    super.initState();
    final runtime = widget.runtime;
    preferences = AppPreferences(runtime?.storage)..load();
    hub =
        widget.hub ??
        HostHub(
          storage: runtime?.storage ?? MemorySecretStorage(),
          connector: runtime?.reconnect,
          lister: runtime == null ? null : () => runtime.hosts.list(),
          forgetter: runtime?.hosts.forget,
        );
    if (!hub.loaded) hub.load();
  }

  @override
  void dispose() {
    if (widget.hub == null) hub.dispose();
    preferences.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppScope(
    hub: hub,
    preferences: preferences,
    runtime: widget.runtime,
    client: widget.client,
    child: ListenableBuilder(
      listenable: preferences,
      builder: (context, _) => MaterialApp(
        title: 'DogCodes',
        debugShowCheckedModeBanner: false,
        theme: dcTheme(Brightness.light),
        darkTheme: dcTheme(Brightness.dark),
        themeMode: preferences.themeMode,
        home: const HomeShell(),
      ),
    ),
  );
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
  bool _started = false;
  void select(int index) => setState(() => tab = index);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    // First launch without a paired computer starts on 电脑 for pairing.
    final hub = AppScope.of(context).hub;
    void initial() {
      if (!hub.loaded) return;
      hub.removeListener(initial);
      if (hub.hosts.isEmpty && mounted && tab == 0) setState(() => tab = 3);
    }

    hub.addListener(initial);
    initial();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      AppScope.of(context).hub.resume();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
                  const NavigationDestination(
                    icon: Icon(Icons.chat_bubble_outline),
                    selectedIcon: Icon(Icons.chat_bubble),
                    label: '会话',
                  ),
                  const NavigationDestination(
                    icon: Icon(Icons.folder_outlined),
                    selectedIcon: Icon(Icons.folder),
                    label: '工作区',
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
                    label: '待处理',
                  ),
                  const NavigationDestination(
                    icon: Icon(Icons.computer_outlined),
                    selectedIcon: Icon(Icons.computer),
                    label: '电脑',
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
