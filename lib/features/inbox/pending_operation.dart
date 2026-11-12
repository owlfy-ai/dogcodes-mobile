import 'package:dogcodes_app/l10n/strings.dart';
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
  const PendingOperationCard({
    super.key,
    required this.host,
    this.operation,
    this.onSubmitted,
    this.onProjectRegistered,
    this.onDraftSubmitted,
    this.onWorkspaceRecovered,
  });
  final HostState host;
  final Map<String, dynamic>? operation;

  /// Called with the task ID once a send is confirmed submitted.
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onWorkspaceRecovered;
  final ValueChanged<String>? onProjectRegistered;
  final Future<void> Function(Map<String, dynamic>)? onDraftSubmitted;
  @override
  State<PendingOperationCard> createState() => _PendingOperationCardState();
}

class _PendingOperationCardState extends State<PendingOperationCard> {
  bool busy = false;
  String? note;

  Future<void> recover(String action, {Map<String, dynamic>? original}) async {
    final hub = AppScope.of(context).hub;
    final h = widget.host;
    final link = h.link;
    final operation = original ?? widget.operation ?? h.pendingOperation;
    final draft = operation?['draft'];
    if (link == null || operation == null) return;
    setState(() {
      busy = true;
      note = null;
    });
    try {
      final result = switch (action) {
        'retry' =>
          operation['kind'] == 'cancel'
              ? await h.operations.retryCancel(link, operation)
              : operation['kind'] == 'terminal_stop'
              ? await h.operations.retryTerminalStop(link, operation)
              : await h.operations.retry(link, operation),
        'abandon' => await h.operations.abandon(link),
        'finish_cancel' => await h.operations.finishCancelTracking(
          link,
          operation,
        ),
        'finish_stop' => await h.operations.finishTerminalStopTracking(
          link,
          operation,
        ),
        'finish_session' => await h.operations.finishSessionCommandTracking(
          link,
          operation,
        ),
        _ =>
          operation['kind'] == 'cancel'
              ? await h.operations.verifyCancel(link, operation)
              : operation['kind'] == 'terminal_stop'
              ? await h.operations.verifyTerminalStop(link, operation)
              : await h.operations.verify(link, operation),
      };
      if (result is Map &&
          result['state'] == 'closed' &&
          result['resolution']?['status'] == 'submitted') {
        if (draft is Map) {
          await widget.onDraftSubmitted?.call(Map<String, dynamic>.from(draft));
        }
        final id = result['resolution']['taskId'];
        if (id is String) widget.onSubmitted?.call(id);
      } else if (result is Map && result['sessionReceipt'] is Map) {
        await hub.refresh(h);
        note = result['state'] == 'abandoned'
            ? tr("已不再等待。如果电脑收到了这项操作，它仍会生效。")
            : result['action'] == 'delete'
            ? tr("会话已经删除。")
            : tr("新名称已经生效。");
      } else if (result is Map && result['projectId'] is String) {
        await hub.refresh(h);
        note = tr("项目已在电脑上添加，可在「项目」中查看。");
        if (mounted) {
          widget.onProjectRegistered?.call(result['projectId'] as String);
        }
      } else if (result is Map && result['cancelReceipt'] is Map) {
        note = cancelResultMessage(result);
      } else if (result is Map && result['stopRequest'] is Map) {
        widget.onWorkspaceRecovered?.call();
        note = terminalStopMessage(result);
      } else if (result is Map && result['terminal'] is Map) {
        widget.onWorkspaceRecovered?.call();
        note = tr("已找到电脑上的原终端，可在终端或运行页面继续查看；未重新运行命令。");
      } else if (result is Map && result['runReceipt'] is Map) {
        widget.onWorkspaceRecovered?.call();
        note = switch (result['state']) {
          'running' => tr("分析已经开始，可在运行页面查看进度。"),
          'succeeded' => tr("原运行配置操作已完成。"),
          _ => tr("原运行配置操作已结束：{0}", [
            result['runReceipt']['error'] ?? result['state'],
          ]),
        };
      } else if (result is Map && result['state'] == 'retired') {
        note = tr("原启动已取消，未重新运行命令。");
      } else if (result is Map && result['intent'] is Map) {
        note = switch (result['state']) {
          'submitted' => tr("修复已提交给主 Agent。"),
          'abandoned' => tr("原修复已放弃。"),
          _ => tr("修复尚未提交，可继续原操作。{0}", [result['lastError'] ?? '']),
        };
      } else if (result is Map && result['receipt'] is Map) {
        note = gitResultMessage(result);
      } else if (result is Map && result['request']?['runId'] is String) {
        note = tr("已找到原审查，可在对应轮次的「本轮审查」中查看。");
      } else if (result == null) {
        note = tr("电脑上还查不到这项操作，可能没收到。可以重新发送，不会重复执行。");
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
              '${result['status'] == 'running' ? tr("Fork 正在后台执行。") : tr("Fork 尚未完成。")}${result['error'] ?? ''}';
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
    watchAppLanguage(context);
    final hub = AppScope.of(context).hub;
    final op = widget.operation ?? widget.host.pendingOperation;
    if (op == null) return const SizedBox.shrink();
    final send = op['kind'] == 'send';
    final closing = op['phase'] == 'closing';
    final session = [
      'history',
      'fork',
      'project',
      'review',
      'repair',
    ].contains(op['kind']);
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
                child: Text(
                  tr("{0}：还没收到电脑确认", [pendingLabel(op)]),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Tag(tr("待确认"), tone: Tone.warning),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            closing
                ? tr("{0} · 正在确认「不再等待」。重试仅确认原操作的结束状态，已经执行的内容不会撤销。", [
                    widget.host.name,
                  ])
                : widget.host.online
                ? tr("{0} · 网络中断时手机没收到电脑的回复。点「重新确认」查看结果；重新发送也不会重复执行。", [
                    widget.host.name,
                  ])
                : tr("{0} · 网络中断时手机没收到电脑的回复。连上电脑后会自动确认。", [widget.host.name]),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (prompt != null) ...[
            const SizedBox(height: 10),
            CodeBlock(prompt, maxLines: 6),
          ],
          if (op['kind'] == 'session') ...[
            const SizedBox(height: 8),
            SelectableText('${op['taskTitle'] ?? op['taskId']}'),
            if (op['action'] == 'rename')
              SelectableText(
                tr("新名称：{0}", [
                  op['envelope']?['payload']?['data']?['title'] ?? '',
                ]),
              ),
            if (op['action'] == 'delete') Text(tr("重新发送会继续你之前确认过的删除。")),
          ],
          if (op['kind'] == 'terminal_stop') ...[
            const SizedBox(height: 8),
            Text('${op['label'] ?? tr("原终端")}'),
          ],
          if (op['kind'] == 'cancel') ...[
            const SizedBox(height: 8),
            Text('${op['taskTitle'] ?? tr("原任务")}'),
            Text(tr("只会停止当时那次运行，不影响之后新开始的任务。")),
          ],
          if (op['kind'] == 'project')
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: SelectableText('${op['request']?['path'] ?? ''}'),
            ),
          if (note != null) InlineNotice(note!, danger: true),
          if (!widget.host.online)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                tr("电脑离线，连上后会自动确认。"),
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
                child: Text(tr("重新确认")),
              ),
              OutlinedButton(
                onPressed: enabled ? () => recover('retry') : null,
                child: Text(closing ? tr("继续确认结束") : tr("重新发送")),
              ),
              if (send)
                TextButton(
                  onPressed: enabled ? () => recover('abandon') : null,
                  child: Text(tr("不再发送")),
                ),
              if (op['kind'] == 'session')
                TextButton(
                  onPressed: enabled
                      ? () async {
                          final ok = await showDialog<bool>(
                            context: context,
                            builder: (d) => AlertDialog(
                              title: Text(tr("不再等待这项操作？")),
                              content: Text(
                                tr("只是不再在手机上等待结果。如果电脑已经收到，改名或删除仍会生效。"),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(d, false),
                                  child: Text(tr("继续等待")),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.pop(d, true),
                                  child: Text(tr("确定")),
                                ),
                              ],
                            ),
                          );
                          if (ok == true && mounted) {
                            await recover('finish_session', original: op);
                          }
                        }
                      : null,
                  child: Text(tr("不再等待")),
                ),
              if (session)
                TextButton(
                  onPressed: enabled
                      ? () async {
                          final ok = await showDialog<bool>(
                            context: context,
                            builder: (d) => AlertDialog(
                              title: Text(tr("不再等待这项操作？")),
                              content: Text(tr("只是不再在手机上等待结果。电脑上已经完成的操作会保留。")),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(d, false),
                                  child: Text(tr("继续等待")),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.pop(d, true),
                                  child: Text(tr("确定")),
                                ),
                              ],
                            ),
                          );
                          if (ok == true) {
                            try {
                              await widget.host.operations
                                  .finishSessionTracking(op);
                              await hub.refreshOperation(widget.host);
                            } catch (e) {
                              if (mounted) setState(() => note = '$e');
                            }
                          }
                        }
                      : null,
                  child: Text(tr("不再等待")),
                ),
              if (op['kind'] == 'cancel')
                TextButton(
                  onPressed: !enabled
                      ? null
                      : () async {
                          final ok = await showDialog<bool>(
                            context: context,
                            builder: (d) => AlertDialog(
                              title: Text(tr("不再等待这项操作？")),
                              content: Text(
                                tr("只是不再在手机上等待结果。如果电脑已经收到，任务仍会停下。"),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(d, false),
                                  child: Text(tr("继续等待")),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.pop(d, true),
                                  child: Text(tr("确定")),
                                ),
                              ],
                            ),
                          );
                          if (ok == true && mounted) {
                            await recover('finish_cancel', original: op);
                          }
                        },
                  child: Text(tr("不再等待")),
                ),
              if (op['kind'] == 'terminal_stop')
                TextButton(
                  onPressed: !enabled
                      ? null
                      : () async {
                          final ok = await showDialog<bool>(
                            context: context,
                            builder: (d) => AlertDialog(
                              title: Text(tr("不再等待这项操作？")),
                              content: Text(
                                tr(
                                  "只是不再在手机上等待结果。如果电脑已经收到，终端仍会关闭。终端是否还在运行，请在终端页查看。",
                                ),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(d, false),
                                  child: Text(tr("继续等待")),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.pop(d, true),
                                  child: Text(tr("确定")),
                                ),
                              ],
                            ),
                          );
                          if (ok == true && mounted) {
                            await recover('finish_stop', original: op);
                          }
                        },
                  child: Text(tr("不再等待")),
                ),
              if (op['kind'] == 'terminal')
                TextButton(
                  onPressed: !enabled
                      ? null
                      : () async {
                          final ok = await showDialog<bool>(
                            context: context,
                            builder: (d) => AlertDialog(
                              title: Text(tr("不再等待这项操作？")),
                              content: Text(
                                tr("如果终端还没启动，就不会再启动；已经启动的会保留，里面的命令照常运行。"),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(d, false),
                                  child: Text(tr("继续等待")),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.pop(d, true),
                                  child: Text(tr("确定")),
                                ),
                              ],
                            ),
                          );
                          if (ok != true ||
                              !mounted ||
                              widget.host.link == null) {
                            return;
                          }
                          try {
                            await widget.host.operations.finishLaunchTracking(
                              widget.host.link!,
                              op,
                            );
                            await hub.refreshOperation(widget.host);
                          } catch (e) {
                            if (mounted) setState(() => note = '$e');
                          }
                        },
                  child: Text(tr("不再等待")),
                ),
              if (['git', 'index'].contains(op['kind']))
                TextButton(
                  onPressed: !enabled
                      ? null
                      : () async {
                          final ok = await showDialog<bool>(
                            context: context,
                            builder: (d) => AlertDialog(
                              title: Text(tr("不再等待这项操作？")),
                              content: Text(
                                tr(
                                  "如果还没执行，就不会再提交或推送；已经完成的不会撤销。建议先在「变更」里看一下结果。",
                                ),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(d, false),
                                  child: Text(tr("继续等待")),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.pop(d, true),
                                  child: Text(tr("确定")),
                                ),
                              ],
                            ),
                          );
                          if (ok != true ||
                              !mounted ||
                              widget.host.link == null) {
                            return;
                          }
                          try {
                            await widget.host.operations.finishGitTracking(
                              widget.host.link!,
                              op,
                            );
                            await hub.refreshOperation(widget.host);
                          } catch (e) {
                            if (mounted) setState(() => note = '$e');
                          }
                        },
                  child: Text(tr("不再等待")),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// What the user did, in their words.
String pendingLabel(Map<String, dynamic> op) => switch (op['kind']) {
  'send' => tr("发送消息"),
  'fork' => tr("Fork 会话"),
  'history' => tr("置顶或归档"),
  'session' => op['action'] == 'delete' ? tr("删除会话") : tr("重命名会话"),
  'project' => tr("添加项目"),
  'review' => tr("本轮审查"),
  'repair' => tr("修复"),
  'git' => tr("Git 操作"),
  'index' => tr("暂存文件"),
  'undo' => tr("撤销本轮文件修改"),
  'cancel' => tr("停止任务"),
  'terminal' => tr("启动终端"),
  'terminal_stop' => tr("关闭终端"),
  'run_config' => tr("运行配置"),
  _ => tr("审批"),
};
