import 'package:dogcodes_app/l10n/strings.dart';
import 'package:flutter/material.dart';
import '../../app.dart';
import '../../core/host_hub.dart';
import '../../ui/theme.dart';
import '../../ui/quota_ring.dart';
import '../../ui/widgets.dart';
import '../devices/pairing_page.dart';
import 'remote_desktop_page.dart';
import 'keep_awake.dart';
import '../settings/preferences_page.dart';
import '../settings/notification_settings_page.dart';

/// 11 电脑: paired computers, their status, device-level remote desktop and
/// read-only Agent status, plus pairing.
class ComputersPage extends StatelessWidget {
  const ComputersPage({super.key});

  static Future<void> pair(BuildContext context, {bool scan = false}) {
    final scope = AppScope.of(context);
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PairingPage(
          trustedService: scope.client!.origin,
          runtime: scope.runtime,
          hub: scope.hub,
          startScanning: scan,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final scope = AppScope.of(context);
    final hub = scope.hub;
    final canPair = scope.client != null && scope.runtime != null;
    return ListenableBuilder(
      listenable: hub,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          RootHeader(
            title: tr("电脑"),
            actions: [
              IconButton(
                tooltip: tr("扫码连接"),
                onPressed: canPair ? () => pair(context, scan: true) : null,
                icon: const Icon(Icons.qr_code_scanner),
              ),
              IconButton(
                tooltip: tr("偏好设置"),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const PreferencesPage(),
                  ),
                ),
                icon: const Icon(Icons.settings_outlined),
              ),
            ],
          ),
          Expanded(
            child: hub.loaded && hub.hosts.isEmpty
                ? EmptyNote(
                    icon: Icons.devices_outlined,
                    title: tr("把电脑上的工作带在身边"),
                    body: tr("连接自己的电脑，查看会话、发送任务并处理 Agent 的权限请求。无需注册账号。"),
                    action: FilledButton.icon(
                      onPressed: canPair ? () => pair(context) : null,
                      icon: const Icon(Icons.add),
                      label: Text(tr("连接电脑")),
                    ),
                    footnote:
                        hub.loadError ??
                        (scope.client == null
                            ? tr("当前内测版本尚未配置接入服务。")
                            : tr("在电脑端打开「连接手机」，扫描二维码。")),
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(
                      DcSpace.page,
                      4,
                      DcSpace.page,
                      24,
                    ),
                    children: [
                      if (hub.loadError != null)
                        InlineNotice(hub.loadError!, danger: true),
                      for (final h in hub.hosts)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _HostCard(host: h),
                        ),
                      const SizedBox(height: 8),
                      Panel(
                        outlined: true,
                        onTap: canPair ? () => pair(context) : null,
                        child: Row(
                          children: [
                            const Icon(Icons.add, size: 22),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(tr("连接电脑")),
                                  Text(
                                    canPair
                                        ? tr("扫描电脑上的二维码，或粘贴配对链接")
                                        : tr("当前内测版本尚未配置接入服务"),
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                            const Icon(Icons.chevron_right),
                          ],
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _HostCard extends StatelessWidget {
  const _HostCard({required this.host});
  final HostState host;
  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final hub = AppScope.of(context).hub;
    final c = context.dc;
    final h = host;
    final status = switch (h.status) {
      LinkStatus.online => StatusLabel(tr("在线"), tone: Tone.accent),
      LinkStatus.connecting => StatusLabel(tr("连接中")),
      LinkStatus.offline => StatusLabel(tr("离线")),
    };
    // This computer's own Agents; each server lists its own below.
    final agents = orderAgents(
      [
        for (final i in h.installations)
          if (i['targetId'] == null) i,
      ],
      (agent) => '${agent['providerId']}',
      h.agentOrder,
    );
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: c.line),
        borderRadius: BorderRadius.circular(DcSpace.control),
      ),
      padding: const EdgeInsets.fromLTRB(14, 6, 4, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.laptop_mac_outlined),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  h.name,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              const SizedBox(width: 10),
              status,
              const Spacer(),
              PopupMenuButton<String>(
                tooltip: tr("更多"),
                onSelected: (v) {
                  if (v == 'notifications') {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => NotificationSettingsPage(host: h),
                      ),
                    );
                  }
                  if (v == 'connect') hub.connect(h);
                  if (v == 'disconnect') hub.disconnect(h);
                  if (v == 'forget') {
                    showDialog<void>(
                      context: context,
                      builder: (dialog) => AlertDialog(
                        title: Text(tr("从这部手机移除「{0}」？", [h.name])),
                        content: Text(
                          tr(
                            "手机会删除这台电脑的配对凭证，之后需重新扫码才能连接。电脑上的任务不受影响；如需让电脑也拒绝这部手机，请在电脑的设备列表中撤销。",
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(dialog).pop(),
                            child: Text(tr("取消")),
                          ),
                          TextButton(
                            onPressed: () async {
                              Navigator.of(dialog).pop();
                              try {
                                await hub.forget(h);
                              } catch (_) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        tr("移除未完成，连接已关闭，请重试或核实安全存储。"),
                                      ),
                                    ),
                                  );
                                }
                              }
                            },
                            child: Text(
                              tr("移除"),
                              style: TextStyle(color: context.dc.removed),
                            ),
                          ),
                        ],
                      ),
                    );
                  }
                  if (v == 'revoke') {
                    showDialog<void>(
                      context: context,
                      builder: (_) => AlertDialog(
                        title: Text(tr("撤销绑定")),
                        content: Text(
                          tr(
                            "请在「{0}」的设备列表中撤销这部手机。撤销后这部手机将无法再连接该电脑；电脑上正在执行的任务不受影响。",
                            [h.name],
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: Text(tr("知道了")),
                          ),
                        ],
                      ),
                    );
                  }
                },
                itemBuilder: (_) => [
                  if (AppScope.of(context).runtime != null)
                    PopupMenuItem(
                      value: 'notifications',
                      child: Text(tr("通知设置")),
                    ),
                  if (h.status == LinkStatus.offline)
                    PopupMenuItem(value: 'connect', child: Text(tr("重新连接"))),
                  if (h.link != null)
                    PopupMenuItem(value: 'disconnect', child: Text(tr("断开连接"))),
                  PopupMenuItem(value: 'revoke', child: Text(tr("撤销绑定"))),
                  PopupMenuItem(value: 'forget', child: Text(tr("从手机移除"))),
                ],
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (h.online && h.route != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      h.route!.label,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                if (!h.online)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      [
                        if (h.syncedAt != null)
                          tr("最后同步 {0}", [shortTime(h.syncedAt)]),
                        if (h.status == LinkStatus.offline && h.error != null)
                          h.error!,
                      ].join(' · '),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                if (h.status == LinkStatus.offline)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: OutlinedButton(
                      onPressed: () => hub.connect(h),
                      child: Text(tr("重新连接")),
                    ),
                  ),
                // Remote desktop belongs to the device, never to an Agent.
                OutlinedButton.icon(
                  onPressed: h.online
                      ? () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => RemoteDesktopPage(host: h),
                          ),
                        )
                      : null,
                  icon: const Icon(Icons.desktop_windows_outlined),
                  label: Text(h.online ? tr("远程桌面") : tr("远程桌面 · 电脑离线")),
                ),
                if (h.online)
                  KeepAwake(key: ValueKey('awake-${h.id}'), host: h),
                if (agents.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Divider(color: c.line),
                  for (var index = 0; index < agents.length; index++) ...[
                    if (index > 0)
                      Divider(
                        height: 1,
                        thickness: 1,
                        color: c.line,
                        indent: 8,
                        endIndent: 8,
                      ),
                    _AgentStatus(
                      installation: agents[index],
                      quota: h.quotas[agents[index]['installationId']],
                    ),
                  ],
                ] else if (h.snapshot != null)
                  Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: Text(tr("这台电脑上还没有检测到 Agent。")),
                  ),
                if (h.servers.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Divider(color: c.line),
                  Padding(
                    padding: const EdgeInsets.only(top: 8, bottom: 4),
                    child: Text(
                      tr("远程主机"),
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ),
                  for (final server in h.servers)
                    _ServerRow(host: h, server: server),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A server this computer reaches over SSH: its state, its Agents, and a way
/// to reconnect it. Passwords and host keys are only handled on the computer.
class _ServerRow extends StatefulWidget {
  const _ServerRow({required this.host, required this.server});
  final HostState host;
  final Map<String, dynamic> server;
  @override
  State<_ServerRow> createState() => _ServerRowState();
}

class _ServerRowState extends State<_ServerRow> {
  bool busy = false;

  Future<void> _reconnect() async {
    final hub = AppScope.of(context).hub;
    setState(() => busy = true);
    try {
      await hub.reconnectServer(widget.host, '${widget.server['targetId']}');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final s = widget.server;
    final phase = s['phase'];
    final needsInput = s['needsInput'] == true;
    final (label, tone) = switch (phase) {
      _ when needsInput => (tr("需在电脑上确认"), Tone.muted),
      'connected' when s['scanning'] == true => (tr("正在检测 Agent"), Tone.accent),
      'connected' => (tr("已连接"), Tone.accent),
      'connecting' => (tr("连接中"), Tone.muted),
      'failed' => (serverErrorLabel(s['error'] as String?), Tone.muted),
      _ => (tr("未连接"), Tone.muted),
    };
    // A changed host key must be reviewed where the key can be checked.
    final canReconnect =
        widget.host.online &&
        !needsInput &&
        s['error'] != 'host_key_changed' &&
        const ['failed', 'disconnected', 'idle'].contains(phase);
    final agents = [
      for (final i in widget.host.installations)
        if (i['targetId'] == s['targetId']) i,
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.dns_outlined, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '${s['name'] ?? ''}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              StatusLabel(label, tone: tone),
            ],
          ),
          if (needsInput || s['error'] == 'host_key_changed')
            Padding(
              padding: const EdgeInsets.only(left: 32, top: 4),
              child: Text(
                tr("密码、密钥口令和主机密钥只在电脑上的 DogCodes 中处理。"),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (canReconnect)
            Padding(
              padding: const EdgeInsets.only(left: 32, top: 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: busy ? null : _reconnect,
                  icon: busy
                      ? const SizedBox.square(
                          dimension: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh, size: 18),
                  label: Text(tr("重新连接")),
                ),
              ),
            ),
          if (phase == 'connected' && agents.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 32, top: 6),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final a in agents)
                    Tooltip(
                      message: agentLabel(a['providerId'] as String?),
                      child: AgentGlyph(
                        providerId: a['providerId'] as String?,
                        size: 24,
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Why a server connection failed, in the user's words.
String serverErrorLabel(String? kind) => switch (kind) {
  'auth_failed' => tr("登录失败"),
  'host_key_changed' => tr("主机密钥已变化"),
  'host_key_rejected' => tr("主机密钥未被信任"),
  'host_unreachable' => tr("无法访问服务器"),
  'timeout' => tr("连接超时"),
  'connection_closed' => tr("服务器断开了连接"),
  _ => tr("连接失败"),
};

class _AgentStatus extends StatelessWidget {
  const _AgentStatus({required this.installation, this.quota});
  final Map<String, dynamic> installation;
  final Map<String, dynamic>? quota;

  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final i = installation;
    final ready = i['status'] == 'ready';
    final version = i['version'] as String?;
    final meter = QuotaMeter.from(quota);
    final showsFigure = meter?.showsFigure ?? false;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          AgentGlyph(providerId: i['providerId'] as String?, size: 32),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(agentLabel(i['providerId'] as String?)),
                if (version != null)
                  Text(version, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          if (meter != null) ...[
            QuotaBars(meter: meter),
            if (!showsFigure || !ready) const SizedBox(width: 12),
          ],
          if (!ready || !showsFigure)
            StatusLabel(
              ready ? tr("已就绪") : _status(i['status'] as String?),
              tone: ready ? Tone.accent : Tone.muted,
            ),
        ],
      ),
    );
  }

  String _status(String? s) => switch (s) {
    'installed' => tr("已安装 · 未就绪"),
    'not_configured' => tr("需要在电脑上配置"),
    'unsupported_version' => tr("版本不支持"),
    'broken' => tr("异常"),
    _ => tr("不可用"),
  };
}
