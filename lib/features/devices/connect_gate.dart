import 'package:dogcodes_app/l10n/strings.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import '../../app.dart';
import '../../core/host_hub.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../computers/computers_page.dart';
import '../settings/preferences_page.dart';

enum GatePhase { welcome, connecting, unreachable }

/// What the app needs before its tabs are useful: a paired computer that is
/// reachable. Everything (sessions, workspace, approvals) lives on the PC.
GatePhase? gatePhase(HostHub hub) {
  if (hub.hosts.isEmpty) return GatePhase.welcome;
  if (hub.hosts.any((h) => h.online)) return null;
  final waiting = hub.hosts.any(
    (h) =>
        h.status == LinkStatus.connecting ||
        // Loaded but its first attempt has not started yet.
        (hub.canConnect &&
            h.status == LinkStatus.offline &&
            h.connectAttempts == 0),
  );
  return waiting ? GatePhase.connecting : GatePhase.unreachable;
}

/// Full-screen connection step shown instead of the tabs: first-run pairing,
/// or waiting for / retrying the paired computers on later launches.
class ConnectGate extends StatelessWidget {
  const ConnectGate({super.key, required this.phase, this.onBrowseOffline});
  final GatePhase phase;

  /// Enters the tabs with the last synced copy; null when there is none.
  final VoidCallback? onBrowseOffline;

  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    return AnnotatedRegion(
      value: overlayStyle(Theme.of(context).brightness),
      child: Scaffold(
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                  child: IconButton(
                    tooltip: tr("偏好设置"),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const PreferencesPage(),
                      ),
                    ),
                    icon: const Icon(Icons.settings_outlined),
                  ),
                ),
              ),
              Expanded(
                child: AnimatedSwitcher(
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : const Duration(milliseconds: 180),
                  child: switch (phase) {
                    GatePhase.welcome => const _Welcome(key: ValueKey('w')),
                    _ => _Reconnect(
                      key: const ValueKey('r'),
                      onBrowseOffline: onBrowseOffline,
                    ),
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Welcome extends StatelessWidget {
  const _Welcome({super.key});
  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final scope = AppScope.of(context);
    final c = context.dc;
    final canPair = scope.client != null && scope.runtime != null;
    final text = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(DcSpace.page, 8, DcSpace.page, 24),
      children: [
        const SizedBox(height: 16),
        Center(
          child: _Mark(icon: Icons.devices_outlined, color: c.accent),
        ),
        const SizedBox(height: 24),
        Text(
          tr("把电脑上的工作带在身边"),
          textAlign: TextAlign.center,
          style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text(
          tr("DogCodes 手机端连接你自己的电脑：查看会话、继续交给 Agent、处理权限请求。无需注册账号。"),
          textAlign: TextAlign.center,
          style: TextStyle(color: c.secondary, height: 1.5),
        ),
        const SizedBox(height: 28),
        _Step(1, tr("在电脑上打开 DogCodes")),
        _Step(2, tr("点击「连接手机」，屏幕上会显示二维码")),
        _Step(3, tr("用这部手机扫码，或粘贴配对链接")),
        const SizedBox(height: 28),
        FilledButton.icon(
          onPressed: canPair
              ? () => ComputersPage.pair(context, scan: true)
              : null,
          icon: const Icon(Icons.qr_code_scanner),
          label: Text(tr("扫码连接电脑")),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: canPair ? () => ComputersPage.pair(context) : null,
          icon: const Icon(Icons.link),
          label: Text(tr("粘贴配对链接")),
        ),
        const SizedBox(height: 16),
        Text(
          scope.hub.loadError ??
              (canPair
                  ? tr("连接经过端到端加密，手机只能访问你在电脑上授权的内容。")
                  : tr("当前内测版本尚未配置接入服务。")),
          textAlign: TextAlign.center,
          style: text.bodySmall,
        ),
        const SizedBox(height: 20),
        TextButton.icon(
          onPressed: () => DogCodesApp.enterDemo(context),
          icon: const Icon(Icons.visibility_outlined),
          label: Text(tr("先看看示例")),
        ),
      ],
    );
  }
}

class _Step extends StatelessWidget {
  const _Step(this.n, this.text);
  final int n;
  final String text;
  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final c = context.dc;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: c.surface,
              shape: BoxShape.circle,
              border: Border.all(color: c.line),
            ),
            child: Text(
              '$n',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 15))),
        ],
      ),
    );
  }
}

class _Mark extends StatelessWidget {
  const _Mark({required this.icon, required this.color, this.busy = false});
  final IconData icon;
  final Color color;
  final bool busy;
  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final c = context.dc;
    return SizedBox.square(
      dimension: 88,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(24),
            ),
          ),
          Icon(icon, size: 40, color: color),
          if (busy)
            const Positioned.fill(
              child: Padding(
                padding: EdgeInsets.all(2),
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
        ],
      ),
    );
  }
}

/// Paired before: waiting for the computers, or explaining why they can't be
/// reached. Retries are explicit; a lost connection never resends work.
class _Reconnect extends StatefulWidget {
  const _Reconnect({super.key, this.onBrowseOffline});
  final VoidCallback? onBrowseOffline;
  @override
  State<_Reconnect> createState() => _ReconnectState();
}

class _ReconnectState extends State<_Reconnect> {
  Timer? _slow;
  bool slow = false;

  @override
  void initState() {
    super.initState();
    _slow = Timer(const Duration(seconds: 8), () {
      if (mounted) setState(() => slow = true);
    });
    // A computer loaded without connecting (e.g. after pairing another one)
    // would otherwise wait here forever.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final hub = AppScope.of(context).hub;
      if (hub.hosts.any(
        (h) => h.status == LinkStatus.offline && h.connectAttempts == 0,
      )) {
        unawaited(hub.connectAll());
      }
    });
  }

  @override
  void dispose() {
    _slow?.cancel();
    super.dispose();
  }

  void _retry(HostHub hub) {
    setState(() => slow = false);
    _slow?.cancel();
    _slow = Timer(const Duration(seconds: 8), () {
      if (mounted) setState(() => slow = true);
    });
    unawaited(hub.connectAll());
  }

  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final scope = AppScope.of(context);
    final hub = scope.hub;
    final c = context.dc;
    final text = Theme.of(context).textTheme;
    final waiting = gatePhase(hub) == GatePhase.connecting;
    final hosts = hub.hosts;
    return ListView(
      padding: const EdgeInsets.fromLTRB(DcSpace.page, 8, DcSpace.page, 24),
      children: [
        const SizedBox(height: 16),
        Center(
          child: _Mark(
            icon: waiting ? Icons.laptop_mac_outlined : Icons.portable_wifi_off,
            color: waiting ? c.text : c.secondary,
            busy: waiting,
          ),
        ),
        const SizedBox(height: 24),
        Text(
          waiting ? tr("正在连接电脑") : tr("暂时连接不上电脑"),
          textAlign: TextAlign.center,
          style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text(
          waiting
              ? (slow ? tr("连接时间比平时长，仍在尝试。") : tr("会话、项目和待处理都在电脑上，连接后即可使用。"))
              : tr("电脑上的任务不受影响，连接恢复后可继续操作。"),
          textAlign: TextAlign.center,
          style: TextStyle(color: c.secondary, height: 1.5),
        ),
        const SizedBox(height: 24),
        for (final h in hosts) _HostLine(host: h),
        if (!waiting || slow) ...[
          const SizedBox(height: 16),
          SectionLabel(tr("请检查")),
          _Tip(tr("电脑已开机，没有进入睡眠")),
          _Tip(tr("电脑上的 DogCodes 正在运行")),
          _Tip(tr("手机网络可用；同一局域网下连接更快")),
        ],
        const SizedBox(height: 24),
        if (!waiting)
          FilledButton.icon(
            onPressed: hub.canConnect ? () => _retry(hub) : null,
            icon: const Icon(Icons.refresh),
            label: Text(tr("重新连接")),
          ),
        if (widget.onBrowseOffline != null) ...[
          const SizedBox(height: 10),
          OutlinedButton(
            onPressed: widget.onBrowseOffline,
            child: Text(_offlineLabel(hosts)),
          ),
        ],
        const SizedBox(height: 8),
        // Wraps instead of overflowing in longer languages.
        Wrap(
          alignment: WrapAlignment.center,
          children: [
            TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      Scaffold(appBar: AppBar(), body: const ComputersPage()),
                ),
              ),
              child: Text(tr("管理电脑")),
            ),
            TextButton(
              onPressed: scope.client != null && scope.runtime != null
                  ? () => ComputersPage.pair(context)
                  : null,
              child: Text(tr("连接其他电脑")),
            ),
          ],
        ),
      ],
    );
  }

  static String _offlineLabel(List<HostState> hosts) {
    DateTime? last;
    for (final h in hosts) {
      final t = h.syncedAt;
      if (t != null && (last == null || t.isAfter(last))) last = t;
    }
    return last == null
        ? tr("查看离线记录")
        : tr("查看离线记录（{0} 同步）", [shortTime(last)]);
  }
}

class _HostLine extends StatelessWidget {
  const _HostLine({required this.host});
  final HostState host;
  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final c = context.dc;
    final h = host;
    final connecting =
        h.status == LinkStatus.connecting ||
        (h.status == LinkStatus.offline && h.connectAttempts == 0);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Panel(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.computer_outlined, size: 20, color: c.secondary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(h.name, overflow: TextOverflow.ellipsis),
                  if (!connecting && h.error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        h.error!.replaceFirst('Exception: ', ''),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            StatusLabel(connecting ? tr("连接中") : tr("离线")),
          ],
        ),
      ),
    );
  }
}

class _Tip extends StatelessWidget {
  const _Tip(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            Icons.check_circle_outline,
            size: 16,
            color: context.dc.secondary,
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 14))),
        ],
      ),
    );
  }
}
