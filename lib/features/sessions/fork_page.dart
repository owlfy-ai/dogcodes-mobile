import 'package:flutter/material.dart';
import '../../app.dart';
import '../../core/host_hub.dart';
import '../../core/mobile_operations.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../conversation/conversation_page.dart';
import '../inbox/pending_operation.dart';

class ForkPage extends StatefulWidget {
  const ForkPage({super.key, required this.session});
  final SessionRef session;
  @override
  State<ForkPage> createState() => _ForkPageState();
}

class _ForkPageState extends State<ForkPage> {
  List<Map<String, dynamic>> turns = [];
  String? turnId, error;
  String environment = 'workspace';
  bool loading = true, busy = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = widget.session, link = widget.session.host.link;
    if (link == null) {
      setState(() {
        loading = false;
        error = '电脑离线';
      });
      return;
    }
    try {
      final value = await link.call('timeline_snapshot', [s.taskId]);
      final seen = <String>{};
      final list = <Map<String, dynamic>>[
        for (final i in value['items'] as List)
          if (i['kind'] == 'user_message' &&
              i['turnId'] is String &&
              seen.add(i['turnId'] as String))
            Map<String, dynamic>.from(i as Map),
      ];
      if (mounted) {
        setState(() {
          turns = list;
          turnId = list.lastOrNull?['turnId'] as String?;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _fork() async {
    final s = widget.session,
        h = widget.session.host,
        hub = AppScope.of(context).hub;
    final link = h.link, turn = turnId;
    if (link == null || turn == null || busy) return;
    if (h.task(s.taskId)?['activePrimaryRun'] != null) {
      setState(() => error = '请等待当前任务结束后再 Fork。');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await h.operations.fork(link, s.taskId, turn, environment);
      await hub.refresh(h);
      if (mounted &&
          result is Map &&
          result['completed'] == true &&
          result['taskAvailable'] == true) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(
            builder: (_) => ConversationPage(
              hostId: h.id,
              taskId: result['request']['newTaskId'] as String,
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      await hub.refreshOperation(h);
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hub = AppScope.of(context).hub, s = widget.session;
    return Scaffold(
      appBar: DetailBar(
        title: 'Fork 会话',
        subtitle: '${s.title} · ${s.host.name}',
      ),
      body: ListenableBuilder(
        listenable: hub,
        builder: (context, _) => loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(DcSpace.page),
                children: [
                  const Text('从选中轮次结束时的历史创建独立会话。'),
                  const SizedBox(height: 16),
                  if (turns.isEmpty) const InlineNotice('没有可 Fork 的对话轮次。'),
                  for (var i = 0; i < turns.length; i++)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        turnId == turns[i]['turnId']
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                      ),
                      title: Text(
                        '第 ${i + 1} 轮 · ${turns[i]['text']}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: busy
                          ? null
                          : () => setState(
                              () => turnId = turns[i]['turnId'] as String,
                            ),
                    ),
                  const Divider(),
                  for (final (id, title, detail) in const [
                    ('workspace', '当前工作区', '共享当前项目文件，仅复制对话历史。'),
                    (
                      'worktree',
                      '新 Worktree',
                      '在电脑上创建独立工作区，并恢复选中轮次的文件快照。旧轮次可能没有快照。',
                    ),
                  ])
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        environment == id
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                      ),
                      title: Text(title),
                      subtitle: Text(detail),
                      onTap: busy
                          ? null
                          : () => setState(() => environment = id),
                    ),
                  if (error != null) InlineNotice(error!, danger: true),
                  if (s.host.pendingOperation != null)
                    PendingOperationCard(host: s.host),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed:
                        busy ||
                            turnId == null ||
                            !s.host.online ||
                            s.host.pendingOperation != null ||
                            s.host.task(s.taskId)?['activePrimaryRun'] != null
                        ? null
                        : _fork,
                    child: Text(busy ? '正在创建…' : '创建 Fork'),
                  ),
                  if (s.host.task(s.taskId)?['activePrimaryRun'] != null)
                    const InlineNotice('请等待当前任务结束后再 Fork。'),
                ],
              ),
      ),
    );
  }
}
