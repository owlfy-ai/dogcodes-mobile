import 'package:flutter/material.dart';
import 'question_form.dart';
import '../../app.dart';
import '../../core/host_hub.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

bool _rejects(Map option) {
  final role = '${option['semanticRole']}'.toLowerCase();
  return role.contains('reject') ||
      role.contains('deny') ||
      role.contains('cancel') ||
      role.contains('abort');
}

/// One approval or question with its computer, project and full operation.
/// Each request is answered on its own; there is no unscoped "allow all".
class ApprovalCard extends StatefulWidget {
  const ApprovalCard({super.key, required this.item, this.showContext = true});
  final ApprovalRef item;
  final bool showContext;
  @override
  State<ApprovalCard> createState() => _ApprovalCardState();
}

class _ApprovalCardState extends State<ApprovalCard> {
  bool busy = false;

  Future<void> respond(String optionId, {Map<String, dynamic>? answer}) async {
    final hub = AppScope.of(context).hub;
    final messenger = ScaffoldMessenger.of(context);
    final h = widget.item.host;
    final link = h.link;
    if (link == null) return;
    setState(() => busy = true);
    try {
      await h.operations.approval(
        link,
        widget.item.task,
        widget.item.approval,
        optionId,
        answer: answer,
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      await hub.refresh(h);
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final a = item.approval;
    final c = context.dc;
    final options = [
      for (final o in (a['options'] as List? ?? const []))
        Map<String, dynamic>.from(o as Map),
    ];
    final reject = options.where(_rejects).toList();
    final accept = options.where((o) => !_rejects(o)).toList();
    final blocked = !item.host.online || item.host.pendingOperation != null;
    final enabled = !busy && !blocked;
    final form = a['question'] is Map
        ? Map<String, dynamic>.from(a['question'] as Map)
        : null;
    final tool = (a['toolName'] as String?)?.trim();
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: c.line),
        borderRadius: BorderRadius.circular(DcSpace.control),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.showContext)
            Row(
              children: [
                Icon(Icons.computer_outlined, size: 16, color: c.secondary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${item.projectName} · ${item.host.name}',
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                Tag(
                  item.isQuestion ? '问题' : '权限',
                  tone: item.isQuestion ? Tone.muted : Tone.warning,
                ),
              ],
            ),
          if (widget.showContext) const SizedBox(height: 10),
          Text(
            item.isQuestion
                ? '${form?['title'] ?? 'Agent 有一个问题'}'
                : tool == null || tool.isEmpty
                ? '允许这项操作？'
                : '允许 $tool？',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            item.isQuestion
                ? '会话「${item.task['title'] ?? ''}」需要你的回答。'
                : '会话「${item.task['title'] ?? ''}」请求以下操作。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (!item.isQuestion) ...[
            const SizedBox(height: 10),
            CodeBlock('${a['commandSummary'] ?? ''}'),
          ],
          const SizedBox(height: 12),
          if (item.isQuestion && !supportsQuestion(form))
            Text(
              '这个问题的格式暂不支持在手机上回答，请在电脑上回答，回答后这里会自动更新。',
              style: Theme.of(context).textTheme.bodySmall,
            )
          else if (!item.host.online)
            Text('电脑离线，重新连接后再处理。', style: Theme.of(context).textTheme.bodySmall)
          else if (item.host.pendingOperation != null)
            Text(
              '这台电脑有一项操作结果待核实，请先核实。',
              style: Theme.of(context).textTheme.bodySmall,
            )
          else if (item.isQuestion)
            QuestionFormView(
              form: form!,
              enabled: enabled,
              onSubmit: (answer) => respond('', answer: answer),
            )
          else
            Row(
              children: [
                for (final o in reject) ...[
                  Expanded(
                    child: OutlinedButton(
                      onPressed: enabled
                          ? () => respond(o['optionId'] as String)
                          : null,
                      child: Text(o['label'] as String),
                    ),
                  ),
                  const SizedBox(width: 10),
                ],
                if (accept.isNotEmpty)
                  Expanded(
                    child: FilledButton(
                      onPressed: enabled
                          ? () => respond(accept.first['optionId'] as String)
                          : null,
                      child: busy
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(
                              accept.first['label'] as String,
                              overflow: TextOverflow.ellipsis,
                            ),
                    ),
                  ),
                if (accept.length > 1) ...[
                  const SizedBox(width: 6),
                  PopupMenuButton<String>(
                    enabled: enabled,
                    tooltip: '其他授权范围',
                    onSelected: respond,
                    itemBuilder: (_) => [
                      for (final o in accept.skip(1))
                        PopupMenuItem(
                          value: o['optionId'] as String,
                          child: Text(o['label'] as String),
                        ),
                    ],
                    child: Container(
                      width: DcSpace.touch,
                      height: DcSpace.touch,
                      decoration: BoxDecoration(
                        border: Border.all(color: c.line),
                        borderRadius: BorderRadius.circular(DcSpace.control),
                      ),
                      child: const Icon(Icons.expand_more),
                    ),
                  ),
                ],
              ],
            ),
        ],
      ),
    );
  }
}
