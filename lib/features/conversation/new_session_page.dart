import 'package:dogcodes_app/l10n/strings.dart';
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
import '../workspace/add_project_page.dart';
import 'composer_state.dart';
import 'composer_attachments.dart';

/// 03 新会话: project, computer, task text and Agent / model / thinking.
class NewSessionPage extends StatefulWidget {
  const NewSessionPage({super.key, this.hostId, this.projectId});
  final String? hostId;
  final String? projectId;
  @override
  State<NewSessionPage> createState() => _NewSessionPageState();
}

class _NewSessionPageState extends State<NewSessionPage> {
  late ComposerState draft;
  TextEditingController get prompt => draft.prompt;
  late HostHub hub;
  bool _ready = false, sending = false;
  String? _sendingProviderId;
  String? hostId, projectId, error;
  AgentChoice? get choice => draft.choice;
  set choice(AgentChoice? value) => draft.choice = value;

  HostState? get host => hostId == null ? null : hub.host(hostId!);
  Future<void> _addProject() async {
    final result = await showAddProject(context, hostId: hostId);
    if (result == null || !mounted) return;
    setState(() {
      _selectHost(result.hostId, project: result.projectId, carry: true);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ready) return;
    _ready = true;
    hub = AppScope.of(context).hub;
    draft = ComposerState(hub)..addListener(_draftChanged);
    final online = hub.hosts.where((h) => h.online).toList();
    hostId = widget.hostId != null && hub.host(widget.hostId!) != null
        ? widget.hostId
        : online.firstOrNull?.id ?? hub.hosts.firstOrNull?.id;
    _selectHost(hostId, project: widget.projectId);
  }

  void _draftChanged() {
    if (mounted) setState(() {});
  }

  void _selectHost(String? id, {String? project, bool carry = false}) {
    hostId = id;
    final h = host, projects = host?.projects ?? const [];
    projectId = projects.any((p) => p['projectId'] == project)
        ? project
        : projects.firstOrNull?['projectId'] as String?;
    unawaited(
      draft.bind(h, projectId, null, carry: carry).catchError((Object e) {
        if (mounted) setState(() => error = '$e');
      }),
    );
  }

  Future<void> start() async {
    final h = host;
    final link = h?.link;
    final c = choice;
    final text = prompt.text;
    if (h == null || link == null || projectId == null || c == null) return;
    if (!draft.hasContent ||
        sending ||
        !h.online ||
        !draft.choiceValid ||
        draft.host != h ||
        draft.projectId != projectId ||
        draft.restoring) {
      return;
    }
    setState(() {
      sending = true;
      _sendingProviderId = c.executor['providerId'] as String?;
      error = null;
    });
    try {
      await draft.flush();
      final attachments = draft.attachments.isEmpty
          ? <Map<String, dynamic>>[]
          : await draft.prepareAttachments();
      final identity = draft.identity;
      final value = await h.operations.send(link, {
        'scope': 'mobile:${h.id}:$projectId:new',
        'taskId': null,
        'projectId': projectId,
        'target': c.executor,
        'input': {
          'prompt': text,
          'model': c.model,
          'thinking': c.thinking,
          'permissionMode': c.effectivePermission,
          'attachments': attachments,
        },
      }, draft: identity);
      await hub.refresh(h);
      if (value is Map &&
          value['state'] == 'closed' &&
          value['resolution']?['status'] == 'submitted') {
        await draft.submitted(identity);
        _open(h.id, value['resolution']['taskId'] as String);
        return;
      }
      if (value is Map && value['state'] == 'closed') {
        error = tr("电脑未受理这项任务，内容已保留。");
      }
    } catch (e) {
      error = '$e';
      await hub.refresh(h);
    }
    if (mounted) {
      setState(() {
        sending = false;
        _sendingProviderId = null;
      });
    }
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
    draft.removeListener(_draftChanged);
    draft.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    return ListenableBuilder(
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
            draft.choiceValid &&
            draft.host == h &&
            draft.projectId == projectId &&
            !draft.restoring &&
            !draft.uploading &&
            !draft.picking &&
            !sending;
        return Scaffold(
          appBar: DetailBar(
            title: tr("新会话"),
            actions: [
              IconButton(
                tooltip: tr("添加项目"),
                onPressed:
                    !sending &&
                        !draft.uploading &&
                        !draft.restoring &&
                        hub.hosts.any((h) => h.online)
                    ? _addProject
                    : null,
                icon: const Icon(Icons.create_new_folder_outlined),
              ),
            ],
          ),
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
                        label: projectLabel(project) ?? tr("选择项目"),
                        enabled:
                            !sending &&
                            !draft.restoring &&
                            !draft.uploading &&
                            h != null &&
                            h.projects.isNotEmpty,
                        values: {
                          for (final p in h?.projects ?? const [])
                            p['projectId'] as String: projectLabel(
                              Map<String, dynamic>.from(p),
                            )!,
                        },
                        onSelected: (v) =>
                            setState(() => _selectHost(hostId, project: v)),
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
                        label: h?.name ?? tr("没有已绑定的电脑"),
                        trailing: h == null
                            ? null
                            : StatusLabel(
                                h.online ? tr("在线") : tr("离线"),
                                tone: h.online ? Tone.accent : Tone.muted,
                              ),
                        enabled:
                            !sending &&
                            !draft.restoring &&
                            !draft.uploading &&
                            hub.hosts.length > 1,
                        values: {
                          for (final x in hub.hosts)
                            x.id: '${x.name}${x.online ? '' : tr(" · 离线")}',
                        },
                        onSelected: (v) => setState(() => _selectHost(v)),
                      ),
                      if (h != null && h.projects.isEmpty)
                        InlineNotice(tr("这台电脑还没有项目，点右上角「添加项目」选择电脑上的已有目录。")),
                      const SizedBox(height: 20),
                      Text(
                        tr("你想完成什么？"),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      if (h != null && !h.online)
                        InlineNotice(tr("电脑离线，任务和附件会保留为本机草稿。重连后请点击发送。")),
                      if (draft.restoring) const LinearProgressIndicator(),
                      TextField(
                        controller: prompt,
                        enabled:
                            !sending &&
                            !draft.restoring &&
                            !draft.restoreFailed &&
                            !draft.uploading,
                        minLines: 5,
                        maxLines: 12,
                        decoration: InputDecoration(hintText: tr("描述你的任务…")),
                      ),
                      ComposerAttachments(draft: draft, enabled: !sending),
                      const SizedBox(height: 12),
                      Panel(
                        outlined: true,
                        onTap:
                            h?.online == true &&
                                !sending &&
                                !draft.uploading &&
                                !draft.restoring &&
                                !draft.picking
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
                                  Text(choice?.agentName ?? tr("选择 Agent")),
                                  Text(
                                    choice == null
                                        ? (h?.executors.isEmpty ?? true)
                                              ? tr("没有已就绪的 Agent")
                                              : tr("加载中…")
                                        : [
                                            choice!.modelName,
                                            if (choice!
                                                .thinkingOptions
                                                .isNotEmpty)
                                              tr("思考 {0}", [
                                                choice!.thinkingName,
                                              ]),
                                          ].join(' · '),
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                            if (QuotaMeter.from(
                                  h?.quotas[choice?.executor['installationId']],
                                )
                                case final q?) ...[
                              QuotaBars(meter: q),
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
                            onDraftSubmitted: draft.submitted,
                            onSubmitted: (task) => _open(h.id, task),
                          ),
                        ),
                      if (draft.error != null)
                        InlineNotice(draft.error!, danger: true),
                      if (error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(
                            error!,
                            style: TextStyle(color: c.removed),
                          ),
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
                        onPressed: canStart && draft.hasContent ? start : null,
                        child: sending
                            ? Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const SizedBox.square(
                                    dimension: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Flexible(
                                    child: Text(
                                      tr("正在连接{0}", [
                                        agentLabel(_sendingProviderId),
                                      ]),
                                    ),
                                  ),
                                ],
                              )
                            : Text(tr("开始任务")),
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
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    return PopupMenuButton<T>(
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
}
