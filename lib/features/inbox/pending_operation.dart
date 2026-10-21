import 'package:flutter/material.dart';
import '../../app.dart';
import '../../core/host_hub.dart';
import '../../core/mobile_operations.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../conversation/conversation_page.dart';

/// A write whose result is unknown. The original content is kept, and the
/// user explicitly verifies, retries the same operation, or abandons it.
class PendingOperationCard extends StatefulWidget {
  const PendingOperationCard({super.key, required this.host, this.onSubmitted});
  final HostState host;

  /// Called with the task ID once a send is confirmed submitted.
  final ValueChanged<String>? onSubmitted;
  @override
  State<PendingOperationCard> createState() => _PendingOperationCardState();
}

class _PendingOperationCardState extends State<PendingOperationCard> {
  bool busy = false;
  String? note;

  Future<void> recover(String action) async {
    final hub = AppScope.of(context).hub;
    final h = widget.host;
    final link = h.link;
    if (link == null) return;
    setState(() {
      busy = true;
      note = null;
    });
    try {
      final result = switch (action) {
        'retry' => await h.operations.retry(link),
        'abandon' => await h.operations.abandon(link),
        _ => await h.operations.verify(link),
      };
      if (result is Map &&
          result['state'] == 'closed' &&
          result['resolution']?['status'] == 'submitted') {
        final id = result['resolution']['taskId'];
        if (id is String) widget.onSubmitted?.call(id);
      } else if (result == null) {
        note = '尚未查到原操作回执；可使用原操作重试，内容不会更换。';
      } else if (result is Map && result['request'] is Map) {
        if (result['completed'] == true && result['taskAvailable'] == true) {
          await hub.refresh(h);
          if (mounted) {
            await Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ConversationPage(
                  hostId: h.id,
                  taskId: result['request']['newTaskId'] as String,
                ),
              ),
            );
          }
        } else {
          note =
              '${result['status'] == 'running' ? 'Fork 正在后台执行。' : 'Fork 尚未完成。'}${result['error'] ?? ''}';
        }
      }
    } catch (e) {
      note = '$e';
    } finally {
      await hub.refresh(h);
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hub = AppScope.of(context).hub;
    final op = widget.host.pendingOperation;
    if (op == null) return const SizedBox.shrink();
    final send = op['kind'] == 'send';
    final session = op['kind'] == 'history' || op['kind'] == 'fork';
    final prompt = send
        ? (op['request']?['input']?['prompt'] as String?)
        : null;
    final enabled = !busy && widget.host.online;
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: context.dc.line),
        borderRadius: BorderRadius.circular(DcSpace.control),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(switch (op['kind']) {
                  'send' => '发送结果待核实',
                  'fork' => 'Fork 结果待核实',
                  'history' => '会话设置结果待核实',
                  _ => '审批结果待核实',
                }, style: Theme.of(context).textTheme.titleMedium),
              ),
              const Tag('待核实', tone: Tone.warning),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${widget.host.name} · 原始内容已保留，不会自动重发。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (prompt != null) ...[
            const SizedBox(height: 10),
            CodeBlock(prompt, maxLines: 6),
          ],
          if (note != null) InlineNotice(note!, danger: true),
          if (!widget.host.online)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '电脑离线，重新连接后再核实。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: enabled ? () => recover('verify') : null,
                child: const Text('核实结果'),
              ),
              OutlinedButton(
                onPressed: enabled ? () => recover('retry') : null,
                child: const Text('使用原操作重试'),
              ),
              if (send)
                TextButton(
                  onPressed: enabled ? () => recover('abandon') : null,
                  child: const Text('放弃原发送'),
                ),
              if (session)
                TextButton(
                  onPressed: enabled
                      ? () async {
                          final ok = await showDialog<bool>(
                            context: context,
                            builder: (d) => AlertDialog(
                              title: const Text('结束原操作跟踪？'),
                              content: const Text(
                                '这不会取消电脑上已受理的操作，也不会删除 Fork 或 Worktree。请先核实电脑上的实际结果。',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(d, false),
                                  child: const Text('继续保留'),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.pop(d, true),
                                  child: const Text('已核实，结束跟踪'),
                                ),
                              ],
                            ),
                          );
                          if (ok == true) {
                            await widget.host.operations
                                .finishSessionTracking();
                            await hub.refreshOperation(widget.host);
                          }
                        }
                      : null,
                  child: const Text('结束跟踪'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
