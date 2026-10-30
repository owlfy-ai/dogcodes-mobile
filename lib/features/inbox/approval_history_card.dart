import 'package:dogcodes_app/l10n/strings.dart';
import 'package:flutter/material.dart';
import '../../core/host_hub.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'approval_card.dart';
import 'approval_presentation.dart';
import 'question_form.dart';

/// A handled approval or question, kept for reference. Nothing on it can be
/// answered again.
class ApprovalHistoryCard extends StatelessWidget {
  const ApprovalHistoryCard({super.key, required this.item, this.onOpen});
  final HandledApproval item;
  final VoidCallback? onOpen;
  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final c = context.dc;
    final theme = Theme.of(context).textTheme;
    final a = item.approval;
    final form = a['question'] is Map
        ? Map<String, dynamic>.from(a['question'] as Map)
        : null;
    final view = item.isQuestion
        ? null
        : approvalPresentation(
            '${a['commandSummary'] ?? ''}',
            (a['toolName'] as String?)?.trim() ?? '',
          );
    final choice = item.choice;
    final answer = choice?['answer'] is Map ? choice!['answer'] as Map : null;
    final outcome = choice == null
        ? [tr("已在电脑上处理，或请求已失效")]
        : item.isQuestion
        ? [tr("你的回答"), ...answerSummary(form, answer)]
        : [
            tr("你的选择：{0}", [tr('${choice['label']}')]),
          ];
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: c.line),
        borderRadius: BorderRadius.circular(DcSpace.control),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.computer_outlined, size: 16, color: c.secondary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${item.projectName} · ${item.host.name}',
                  overflow: TextOverflow.ellipsis,
                  style: theme.bodySmall,
                ),
              ),
              Tag(view?.category ?? tr("问题"), tone: Tone.muted),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            view?.question ?? '${form?['title'] ?? tr("Agent 有一个问题")}',
            style: theme.titleMedium?.copyWith(color: c.secondary),
          ),
          if (item.taskTitle.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              item.taskTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.bodySmall,
            ),
          ],
          if (view != null) ApprovalDetails(view),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                choice == null ? Icons.history : Icons.check_circle_outline,
                size: 16,
                color: c.secondary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final line in outcome)
                      Text(line, style: theme.bodySmall),
                  ],
                ),
              ),
              Text(shortTime(item.handledAt), style: theme.bodySmall),
            ],
          ),
          if (onOpen != null)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: onOpen, child: Text(tr("查看会话"))),
            ),
        ],
      ),
    );
  }
}
