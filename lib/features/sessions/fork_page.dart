import 'package:dogcodes_app/l10n/strings.dart';
import 'package:flutter/material.dart';
import '../../app.dart';
import '../../core/host_hub.dart';
import '../../core/mobile_operations.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../conversation/conversation_page.dart';
import '../inbox/pending_operation.dart';

class ForkPage extends StatefulWidget {
  const ForkPage({
    super.key,
    required this.session,
    required this.turnId,
    this.prompt,
  });
  final SessionRef session;
  final String turnId;
  final String? prompt;
  @override
  State<ForkPage> createState() => _ForkPageState();
}

class _ForkPageState extends State<ForkPage> {
  String? error;
  String environment = 'workspace';
  bool busy = false;

  Future<void> _fork() async {
    final s = widget.session,
        h = widget.session.host,
        hub = AppScope.of(context).hub;
    final link = h.link;
    final turn = widget.turnId;
    if (link == null || !h.online || busy) return;
    if (h.task(s.taskId)?['activePrimaryRun'] != null) {
      setState(() => error = tr("请等待当前任务结束后再 Fork。"));
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
    watchAppLanguage(context);
    final hub = AppScope.of(context).hub, s = widget.session;
    return Scaffold(
      appBar: DetailBar(
        title: tr("Fork 会话"),
        subtitle: '${s.title} · ${s.host.name}',
      ),
      body: ListenableBuilder(
        listenable: hub,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(DcSpace.page),
          children: [
            Text(tr("从本轮结束时的历史创建独立会话。")),
            if (widget.prompt != null) ...[
              const SizedBox(height: 12),
              Text(
                widget.prompt!,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            const Divider(),
            for (final (id, title, detail) in [
              ('workspace', tr("当前工作区"), tr("共享当前项目文件，仅复制对话历史。")),
              (
                'worktree',
                tr("新 Worktree"),
                tr("在电脑上创建独立工作区，并恢复选中轮次的文件快照。旧轮次可能没有快照；非 Git 项目只继承对话。"),
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
                onTap: busy ? null : () => setState(() => environment = id),
              ),
            if (error != null) InlineNotice(error!, danger: true),
            if (s.host.pendingOperation != null)
              PendingOperationCard(host: s.host),
            const SizedBox(height: 16),
            FilledButton(
              onPressed:
                  busy ||
                      !s.host.online ||
                      s.host.pendingOperation != null ||
                      s.host.task(s.taskId)?['activePrimaryRun'] != null
                  ? null
                  : _fork,
              child: Text(busy ? tr("正在创建…") : tr("创建 Fork")),
            ),
            if (s.host.task(s.taskId)?['activePrimaryRun'] != null)
              InlineNotice(tr("请等待当前任务结束后再 Fork。")),
          ],
        ),
      ),
    );
  }
}
