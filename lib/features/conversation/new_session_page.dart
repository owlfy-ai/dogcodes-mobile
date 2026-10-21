import 'dart:async';
import 'package:flutter/material.dart';
import '../../app.dart';
import '../../core/host_hub.dart';
import '../../ui/theme.dart';
import '../../ui/quota_ring.dart';
import '../../ui/widgets.dart';
import '../inbox/pending_operation.dart';
import 'agent_picker.dart';
import 'conversation_page.dart';

/// 03 新会话: project, computer, task text and Agent / model / thinking.
class NewSessionPage extends StatefulWidget {
  const NewSessionPage({super.key, this.hostId, this.projectId});
  final String? hostId;
  final String? projectId;
  @override
  State<NewSessionPage> createState() => _NewSessionPageState();
}

class _NewSessionPageState extends State<NewSessionPage> {
  final prompt = TextEditingController();
  late HostHub hub;
  bool _ready = false, sending = false;
  String? hostId, projectId, error;
  AgentChoice? choice;

  HostState? get host => hostId == null ? null : hub.host(hostId!);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ready) return;
    _ready = true;
    hub = AppScope.of(context).hub;
    final online = hub.hosts.where((h) => h.online).toList();
    hostId = widget.hostId != null && hub.host(widget.hostId!)?.online == true
        ? widget.hostId
        : online.isEmpty
        ? null
        : online.first.id;
    _selectHost(hostId, project: widget.projectId);
  }

  void _selectHost(String? id, {String? project}) {
    hostId = id;
    final h = host;
    final projects = h?.projects ?? const [];
    projectId = projects.any((p) => p['projectId'] == project)
        ? project
        : projects.isEmpty
        ? null
        : projects.first['projectId'] as String;
    choice = null;
    final e = h == null ? null : defaultExecutor(h, null);
    final link = h?.link;
    if (e != null && link != null) {
      choice = AgentChoice(e);
      unawaited(
        loadChoice(link, e, null)
            .then((v) {
              if (mounted && hostId == h!.id) setState(() => choice = v);
            })
            .catchError((Object _) {}),
      );
    }
  }

  Future<void> start() async {
    final h = host;
    final link = h?.link;
    final c = choice;
    final text = prompt.text;
    if (h == null || link == null || projectId == null || c == null) return;
    if (text.trim().isEmpty) return;
    setState(() {
      sending = true;
      error = null;
    });
    try {
      final value = await h.operations.send(link, {
        'scope': 'mobile:${h.id}:$projectId:new',
        'taskId': null,
        'projectId': projectId,
        'target': c.executor,
        'input': {
          'prompt': text,
          'model': c.model,
          'thinking': c.thinking,
          'permissionMode': null,
          'attachments': [],
        },
      });
      await hub.refresh(h);
      if (value is Map &&
          value['state'] == 'closed' &&
          value['resolution']?['status'] == 'submitted') {
        _open(h.id, value['resolution']['taskId'] as String);
        return;
      }
      if (value is Map && value['state'] == 'closed') {
        error = '电脑未受理这项任务，内容已保留。';
      }
    } catch (e) {
      error = '$e';
      await hub.refresh(h);
    }
    if (mounted) setState(() => sending = false);
  }

  void _open(String host, String task) {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => ConversationPage(hostId: host, taskId: task),
      ),
    );
  }

  @override
  void dispose() {
    prompt.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: hub,
    builder: (context, _) {
      final h = host;
      final project = h?.project(projectId);
      final c = context.dc;
      final canStart =
          h != null &&
          h.online &&
          h.pendingOperation == null &&
          project != null &&
          choice != null &&
          !sending;
      return Scaffold(
        appBar: const DetailBar(title: '新会话'),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(DcSpace.page),
                  children: [
                    _Picker<String>(
                      icon: Icons.folder_outlined,
                      label: projectLabel(project) ?? '选择项目',
                      enabled: h != null && h.projects.isNotEmpty,
                      values: {
                        for (final p in h?.projects ?? const [])
                          p['projectId'] as String: projectLabel(
                            Map<String, dynamic>.from(p),
                          )!,
                      },
                      onSelected: (v) => setState(() => projectId = v),
                    ),
                    if (project != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4, left: 4),
                        child: Text(
                          project['path'] as String? ?? '',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    const SizedBox(height: 8),
                    _Picker<String>(
                      icon: Icons.computer_outlined,
                      label: h?.name ?? '没有在线的电脑',
                      trailing: h == null
                          ? null
                          : StatusLabel(
                              h.online ? '在线' : '离线',
                              tone: h.online ? Tone.accent : Tone.muted,
                            ),
                      enabled: hub.hosts.where((x) => x.online).length > 1,
                      values: {
                        for (final x in hub.hosts)
                          if (x.online) x.id: x.name,
                      },
                      onSelected: (v) => setState(() => _selectHost(v)),
                    ),
                    if (h != null && h.projects.isEmpty)
                      const InlineNotice('这台电脑还没有项目。请先在电脑上添加项目目录。'),
                    const SizedBox(height: 20),
                    Text(
                      '你想完成什么？',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: prompt,
                      minLines: 5,
                      maxLines: 12,
                      decoration: const InputDecoration(hintText: '描述你的任务…'),
                    ),
                    const SizedBox(height: 20),
                    Panel(
                      outlined: true,
                      onTap: h?.online == true
                          ? () async {
                              final value = await showAgentSheet(
                                context,
                                host: h!,
                                initial: choice,
                              );
                              if (value != null && mounted) {
                                setState(() => choice = value);
                              }
                            }
                          : null,
                      child: Row(
                        children: [
                          AgentGlyph(
                            providerId:
                                choice?.executor['providerId'] as String?,
                            size: 32,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(choice?.agentName ?? '选择 Agent'),
                                Text(
                                  choice == null
                                      ? (h?.executors.isEmpty ?? true)
                                            ? '没有已就绪的 Agent'
                                            : '加载中…'
                                      : [
                                          choice!.modelName,
                                          if (choice!
                                              .thinkingOptions
                                              .isNotEmpty)
                                            '思考 ${choice!.thinkingName}',
                                        ].join(' · '),
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                          if (QuotaReading.from(
                                h?.quotas[choice?.executor['installationId']],
                              )
                              case final q?) ...[
                            QuotaRing(reading: q),
                            const SizedBox(width: 8),
                          ],
                          Icon(Icons.chevron_right, color: c.secondary),
                        ],
                      ),
                    ),
                    if (h?.pendingOperation != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: PendingOperationCard(
                          host: h!,
                          onSubmitted: (task) => _open(h.id, task),
                        ),
                      ),
                    if (error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(error!, style: TextStyle(color: c.removed)),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  DcSpace.page,
                  8,
                  DcSpace.page,
                  12,
                ),
                child: ListenableBuilder(
                  listenable: prompt,
                  builder: (context, _) => SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: canStart && prompt.text.trim().isNotEmpty
                          ? start
                          : null,
                      child: sending
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('开始任务'),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _Picker<T> extends StatelessWidget {
  const _Picker({
    required this.icon,
    required this.label,
    required this.values,
    required this.onSelected,
    this.enabled = true,
    this.trailing,
  });
  final IconData icon;
  final String label;
  final Map<T, String> values;
  final ValueChanged<T> onSelected;
  final bool enabled;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => PopupMenuButton<T>(
    enabled: enabled,
    onSelected: onSelected,
    itemBuilder: (_) => [
      for (final e in values.entries)
        PopupMenuItem(value: e.key, child: Text(e.value)),
    ],
    child: Panel(
      child: Row(
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(label, overflow: TextOverflow.ellipsis)),
          ?trailing,
          if (enabled) const Icon(Icons.expand_more, size: 20),
        ],
      ),
    ),
  );
}
