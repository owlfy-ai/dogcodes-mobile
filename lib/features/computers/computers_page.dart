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
    final scope = AppScope.of(context);
    final hub = scope.hub;
    final canPair = scope.client != null && scope.runtime != null;
    return ListenableBuilder(
      listenable: hub,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          RootHeader(
            title: '电脑',
            actions: [
              IconButton(
                tooltip: '扫码连接',
                onPressed: canPair ? () => pair(context, scan: true) : null,
                icon: const Icon(Icons.qr_code_scanner),
              ),
              IconButton(
                tooltip: '偏好设置',
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
                    title: '把电脑上的工作带在身边',
                    body: '连接自己的电脑，查看会话、发送任务并处理 Agent 的权限请求。无需注册账号。',
                    action: FilledButton.icon(
                      onPressed: canPair ? () => pair(context) : null,
                      icon: const Icon(Icons.add),
                      label: const Text('连接电脑'),
                    ),
                    footnote:
                        hub.loadError ??
                        (scope.client == null
                            ? '当前内测版本尚未配置接入服务。'
                            : '在电脑端打开「连接手机」，扫描二维码。'),
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
                                  const Text('连接电脑'),
                                  Text(
                                    canPair
                                        ? '扫描电脑上的二维码，或粘贴配对链接'
                                        : '当前内测版本尚未配置接入服务',
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
    final hub = AppScope.of(context).hub;
    final c = context.dc;
    final h = host;
    final status = switch (h.status) {
      LinkStatus.online => const StatusLabel('在线', tone: Tone.accent),
      LinkStatus.connecting => const StatusLabel('连接中'),
      LinkStatus.offline => const StatusLabel('离线'),
    };
    final agents = h.installations;
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
                tooltip: '更多',
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
                        title: Text('从这部手机移除「${h.name}」？'),
                        content: const Text(
                          '手机会删除这台电脑的配对凭证，之后需重新扫码才能连接。'
                          '电脑上的任务不受影响；如需让电脑也拒绝这部手机，请在电脑的设备列表中撤销。',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(dialog).pop(),
                            child: const Text('取消'),
                          ),
                          TextButton(
                            onPressed: () async {
                              Navigator.of(dialog).pop();
                              try {
                                await hub.forget(h);
                              } catch (_) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('移除未完成，连接已关闭，请重试或核实安全存储。'),
                                    ),
                                  );
                                }
                              }
                            },
                            child: Text(
                              '移除',
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
                        title: const Text('撤销绑定'),
                        content: Text(
                          '请在「${h.name}」的设备列表中撤销这部手机。撤销后这部手机将无法再连接该电脑；'
                          '电脑上正在执行的任务不受影响。',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: const Text('知道了'),
                          ),
                        ],
                      ),
                    );
                  }
                },
                itemBuilder: (_) => [
                  if (AppScope.of(context).runtime != null)
                    const PopupMenuItem(
                      value: 'notifications',
                      child: Text('通知设置'),
                    ),
                  if (h.status == LinkStatus.offline)
                    const PopupMenuItem(value: 'connect', child: Text('重新连接')),
                  if (h.link != null)
                    const PopupMenuItem(
                      value: 'disconnect',
                      child: Text('断开连接'),
                    ),
                  const PopupMenuItem(value: 'revoke', child: Text('撤销绑定')),
                  const PopupMenuItem(value: 'forget', child: Text('从手机移除')),
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
                        if (h.syncedAt != null) '最后同步 ${shortTime(h.syncedAt)}',
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
                      child: const Text('重新连接'),
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
                  label: Text(h.online ? '远程桌面' : '远程桌面 · 电脑离线'),
                ),
                if (h.online)
                  KeepAwake(key: ValueKey('awake-${h.id}'), host: h),
                if (agents.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Divider(color: c.line),
                  for (final a in agents)
                    _AgentStatus(
                      installation: a,
                      quota: h.quotas[a['installationId']],
                    ),
                ] else if (h.snapshot != null)
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: Text('这台电脑上还没有检测到 Agent。'),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AgentStatus extends StatelessWidget {
  const _AgentStatus({required this.installation, this.quota});
  final Map<String, dynamic> installation;
  final Map<String, dynamic>? quota;

  @override
  Widget build(BuildContext context) {
    final i = installation;
    final ready = i['status'] == 'ready';
    final version = i['version'] as String?;
    final reading = QuotaReading.from(quota);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
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
          if (reading != null) ...[
            QuotaRing(reading: reading),
            const SizedBox(width: 12),
          ],
          StatusLabel(
            ready ? '已就绪' : _status(i['status'] as String?),
            tone: ready ? Tone.accent : Tone.muted,
          ),
        ],
      ),
    );
  }

  String _status(String? s) => switch (s) {
    'installed' => '已安装 · 未就绪',
    'not_configured' => '需要在电脑上配置',
    'unsupported_version' => '版本不支持',
    'broken' => '异常',
    _ => '不可用',
  };
}
