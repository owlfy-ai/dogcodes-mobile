import 'dart:async';
import 'package:flutter/material.dart';
import '../../app.dart';
import '../../core/host_hub.dart';
import '../../core/live_timeline.dart';
import '../../core/mobile_operations.dart';
import '../../core/pc_api.dart';
import '../../ui/quota_ring.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../inbox/approval_card.dart';
import '../inbox/pending_operation.dart';
import 'agent_picker.dart';
import 'timeline_view.dart';
import 'turn_files.dart';
import '../sessions/session_menu.dart';

/// 02 对话: streamed timeline, tool activity, approvals and the composer.
/// Leaving this page never stops the task on the PC.
class ConversationPage extends StatefulWidget {
  const ConversationPage({
    super.key,
    required this.hostId,
    required this.taskId,
    this.focusTurnId,
  });
  final String hostId;
  final String taskId;
  final String? focusTurnId;
  @override
  State<ConversationPage> createState() => _ConversationPageState();
}

class _ConversationPageState extends State<ConversationPage> {
  final prompt = TextEditingController();
  final scroll = ScrollController();
  late HostHub hub;
  late final live = LiveTimeline(widget.taskId);
  List<Map<String, dynamic>> get timeline => live.items;
  StreamSubscription<Map<String, dynamic>>? _stream;
  AgentChoice? choice;
  bool loading = true, sending = false, stopping = false;
  String? error;
  int _revision = -1;
  Object? _streamVersion;
  bool _readingTimeline = false, _timelineDirty = false;
  final _focusKey = GlobalKey();
  bool _focused = false;

  HostState? get host => hub.host(widget.hostId);
  Map<String, dynamic>? get task => host?.task(widget.taskId);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = AppScope.of(context).hub;
    if (_revision == -1) {
      hub = next..addListener(_changed);
      _changed();
    }
  }

  void _changed() {
    final h = host;
    if (h == null || !mounted) return;
    final project = task?['projectId'];
    if (project is String) hub.followProject(h, project);
    _stream ??= h.events.listen(_streamed);
    final version = task?['streamVersion'];
    if (h.online && (h.revision != _revision || version != _streamVersion)) {
      _revision = h.revision;
      _streamVersion = version;
      unawaited(loadTimeline());
      if (choice == null) unawaited(_initChoice());
    }
    setState(() {});
  }

  /// Streamed answer text and activity merge in place, without a reload.
  void _streamed(Map<String, dynamic> event) {
    if (!mounted) return;
    final atEnd = _atEnd;
    final changed = live.apply(event);
    if (live.needsSnapshot) unawaited(loadTimeline());
    if (!changed) return;
    setState(() {});
    if (atEnd) _toEnd();
  }

  bool get _atEnd =>
      !scroll.hasClients ||
      scroll.position.pixels >= scroll.position.maxScrollExtent - 80;

  Future<void> loadTimeline() async {
    if (_readingTimeline) {
      _timelineDirty = true;
      return;
    }
    final h = host, link = host?.link;
    if (link == null) return;
    final epoch = h!.connectionEpoch;
    _readingTimeline = true;
    try {
      final value = await link.call('timeline_snapshot', [widget.taskId]);
      if (!mounted ||
          h.link != link ||
          h.connectionEpoch != epoch ||
          !h.online) {
        return;
      }
      final atEnd = _atEnd;
      setState(() {
        live.reset(Map<String, dynamic>.from(value as Map));
        loading = false;
        error = null;
      });
      if (atEnd) _toEnd();
      if (!_focused && widget.focusTurnId != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final target = _focusKey.currentContext;
          if (mounted && target != null) {
            _focused = true;
            Scrollable.ensureVisible(target, alignment: .1);
          }
        });
      }
    } catch (e) {
      if (mounted && h.link == link && h.connectionEpoch == epoch) {
        setState(() {
          loading = false;
          error = '$e';
        });
      }
    } finally {
      _readingTimeline = false;
      if (_timelineDirty && mounted) {
        _timelineDirty = false;
        unawaited(loadTimeline());
      }
    }
  }

  bool _loadingExecutors = false;

  Future<void> _initChoice() async {
    final h = host;
    final link = h?.link;
    // Opened before the background refresh delivered the PC's Agents.
    if (h != null && link != null && h.executors.isEmpty) {
      if (_loadingExecutors) return;
      _loadingExecutors = true;
      await hub.loadExecutors(h);
      _loadingExecutors = false;
      if (!mounted || choice != null) return;
    }
    final e = h == null ? null : defaultExecutor(h, task);
    if (link == null || e == null) return;
    // Show the Agent (and its quota) while the model catalog loads.
    if (mounted) setState(() => choice = AgentChoice(e));
    try {
      final value = await loadChoice(link, e, widget.taskId);
      if (mounted) setState(() => choice = value);
    } catch (_) {}
  }

  void _toEnd() {
    if (widget.focusTurnId != null && !_focused) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (scroll.hasClients) {
        scroll.jumpTo(scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _rename() async {
    final t = task, link = host?.link;
    if (t == null || link == null) return;
    final controller = TextEditingController(text: t['title'] as String? ?? '');
    final title = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('重命名会话'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 120,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(d, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (title == null || title.isEmpty || title == t['title']) return;
    try {
      await link.renameTask(t, title);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
    await hub.refresh(host!);
  }

  Future<void> _delete() async {
    final t = task, h = host, link = host?.link;
    if (t == null || h == null || link == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('删除这个会话？'),
        content: Text('将在「${h.name}」上永久删除「${t['title']}」及其记录，无法恢复。项目文件不会被删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(d, true),
            child: Text('删除', style: TextStyle(color: context.dc.removed)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await link.deleteTask(t);
      await hub.refresh(h);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> stop() async {
    final h = host;
    final link = h?.link;
    final t = task;
    if (h == null || link == null || t == null || stopping) return;
    setState(() => stopping = true);
    try {
      await h.operations.cancel(link, t);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('停止请求未确认：$e。请刷新核实任务状态。')));
      }
    } finally {
      await hub.refresh(h);
      if (mounted) setState(() => stopping = false);
    }
  }

  Future<void> send() async {
    final h = host;
    final link = h?.link;
    final t = task;
    final c = choice;
    final text = prompt.text;
    if (h == null || link == null || t == null || c == null) return;
    if (text.trim().isEmpty || sending) return;
    setState(() {
      sending = true;
      error = null;
    });
    try {
      final value = await h.operations.send(link, {
        'scope': 'mobile:${h.id}:${t['projectId']}:${widget.taskId}',
        'taskId': widget.taskId,
        'projectId': t['projectId'],
        'target': c.executor,
        'input': {
          'prompt': text,
          'model': c.model,
          'thinking': c.thinking,
          'permissionMode': null,
          'attachments': [],
        },
      });
      if (value is Map &&
          value['state'] == 'closed' &&
          value['resolution']?['status'] == 'submitted') {
        if (prompt.text == text) prompt.clear();
        _toEnd();
      } else if (value is Map && value['state'] == 'closed') {
        error = '电脑未受理这次发送，内容已保留。';
      }
    } catch (e) {
      error = '$e';
    } finally {
      await hub.refresh(h);
      if (mounted) setState(() => sending = false);
    }
  }

  @override
  void dispose() {
    hub.removeListener(_changed);
    _stream?.cancel();
    prompt.dispose();
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final h = host;
    final t = task;
    if (h == null) {
      return const Scaffold(
        appBar: DetailBar(title: '会话'),
        body: EmptyNote(
          icon: Icons.link_off,
          title: '这台电脑已不在列表中',
          body: '可能已在电脑上撤销配对。',
        ),
      );
    }
    final projectName = projectLabel(h.project(t?['projectId'] as String?));
    final approvals = [
      for (final a in h.approvals[widget.taskId] ?? const [])
        if (t != null) ApprovalRef(h, t, a),
    ];
    final running = t?['activePrimaryRun'] != null;
    return Scaffold(
      appBar: DetailBar(
        title: t?['title'] as String? ?? '会话',
        subtitle: [?projectName, h.name].join(' · '),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: h.online ? () => hub.refresh(h) : null,
            icon: const Icon(Icons.refresh),
          ),
          PopupMenuButton<String>(
            tooltip: '更多',
            enabled: h.online && t != null,
            onSelected: (v) async {
              if (v == 'rename') {
                await _rename();
              } else if (v == 'delete') {
                await _delete();
              } else if (t != null) {
                await sessionAction(context, SessionRef(h, t), v);
              }
            },
            itemBuilder: (_) => [
              if (t != null) ...sessionMenuItems(SessionRef(h, t)),
              const PopupMenuDivider(),
              const PopupMenuItem(value: 'rename', child: Text('重命名')),
              const PopupMenuItem(value: 'delete', child: Text('删除会话')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (!h.online) _OfflineBar(host: h, onRetry: () => hub.connect(h)),
          if (error != null) InlineNotice(error!, danger: true),
          Expanded(
            child: loading && timeline.isEmpty
                ? Center(
                    child: h.online
                        ? const CircularProgressIndicator()
                        : Text(
                            '电脑离线，暂无已缓存的对话内容。',
                            style: TextStyle(color: context.dc.secondary),
                          ),
                  )
                : ListView(
                    controller: scroll,
                    padding: const EdgeInsets.fromLTRB(
                      DcSpace.page,
                      8,
                      DcSpace.page,
                      16,
                    ),
                    children: [
                      TurnScope(
                        link: h.link,
                        taskId: widget.taskId,
                        executor: defaultExecutor(h, t),
                        executors: h.executors,
                        child: TimelineView(
                          items: timeline,
                          focusTurnId: widget.focusTurnId,
                          focusKey: _focusKey,
                          activeTurnId:
                              (t?['activePrimaryRun'] as Map?)?['turnId']
                                  as String?,
                        ),
                      ),
                      if (running)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Row(
                            children: [
                              const SizedBox.square(
                                dimension: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Text(
                                'Agent 正在电脑上工作…',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                      for (final a in approvals)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: ApprovalCard(item: a, showContext: false),
                        ),
                    ],
                  ),
          ),
          if (h.pendingOperation != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                DcSpace.page,
                0,
                DcSpace.page,
                8,
              ),
              child: PendingOperationCard(host: h),
            ),
          _Composer(
            controller: prompt,
            choice: choice,
            quota: QuotaReading.from(
              h.quotas[choice?.executor['installationId']],
            ),
            loading: choice == null && h.online,
            sending: sending,
            enabled:
                h.online && t != null && h.pendingOperation == null && !sending,
            onSend: send,
            onStop: running && h.online && !stopping ? stop : null,
            running: running,
            onPick: h.online
                ? () async {
                    final value = await showAgentSheet(
                      context,
                      host: h,
                      initial: choice,
                      taskId: widget.taskId,
                    );
                    if (value != null && mounted) {
                      setState(() => choice = value);
                    }
                  }
                : null,
          ),
        ],
      ),
    );
  }
}

class _OfflineBar extends StatelessWidget {
  const _OfflineBar({required this.host, required this.onRetry});
  final HostState host;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Container(
    color: context.dc.surface,
    padding: const EdgeInsets.fromLTRB(DcSpace.page, 4, 8, 4),
    child: Row(
      children: [
        Expanded(
          child: Text(
            host.status == LinkStatus.connecting
                ? '正在连接电脑…'
                : '电脑离线${host.syncedAt == null ? '' : ' · 最后同步 ${shortTime(host.syncedAt)}'}。任务不会因此停止。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        if (host.status == LinkStatus.offline)
          TextButton(onPressed: onRetry, child: const Text('重新连接')),
      ],
    ),
  );
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.choice,
    this.quota,
    this.loading = false,
    required this.sending,
    required this.enabled,
    required this.onSend,
    required this.onStop,
    required this.running,
    required this.onPick,
  });
  final TextEditingController controller;
  final AgentChoice? choice;
  final QuotaReading? quota;
  final bool loading;
  final bool sending, enabled;
  final VoidCallback onSend;
  final VoidCallback? onStop;
  final bool running;
  final VoidCallback? onPick;
  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        decoration: BoxDecoration(
          color: c.canvas,
          border: Border.all(color: c.line),
          borderRadius: BorderRadius.circular(DcSpace.composer),
        ),
        child: Column(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    minLines: 1,
                    maxLines: 6,
                    enabled: enabled || sending,
                    decoration: const InputDecoration(
                      hintText: '继续交给 Agent…',
                      filled: false,
                      contentPadding: EdgeInsets.symmetric(vertical: 10),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                if (running)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: IconButton.outlined(
                      tooltip: '停止',
                      onPressed: onStop,
                      icon: const Icon(Icons.stop_rounded),
                    ),
                  ),
                ListenableBuilder(
                  listenable: controller,
                  builder: (context, _) => IconButton.filled(
                    style: accentIconButton(context),
                    tooltip: '发送',
                    onPressed:
                        enabled &&
                            choice != null &&
                            controller.text.trim().isNotEmpty
                        ? onSend
                        : null,
                    icon: sending
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.arrow_upward),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: AgentChips(
                choice: choice,
                onTap: onPick,
                quota: quota,
                loading: loading,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
