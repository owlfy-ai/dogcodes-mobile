import 'package:dogcodes_app/l10n/strings.dart';
import 'package:flutter/material.dart';
import '../../core/host_hub.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'approval_presentation.dart';
import 'question_form.dart';

/// One line of preview for a request: the command or file it is about, or
/// the question's title.
String requestPreview(Map<String, dynamic> approval) {
  final form = approval['question'];
  if (form is Map) return '${form['title'] ?? tr("Agent 有一个问题")}';
  final view = approvalPresentation(
    '${approval['commandSummary'] ?? ''}',
    (approval['toolName'] as String?)?.trim() ?? '',
  );
  final first = view.sections.firstOrNull;
  if (first == null) return view.question;
  return '${first.label}：${first.text.replaceAll(RegExp(r'\s+'), ' ').trim()}';
}

/// An inbox entry styled like a message list: the agent's avatar with a
/// small kind badge, the chat title, a preview and the time. Waiting
/// requests read as unread.
class InboxRow extends StatelessWidget {
  InboxRow.waiting({super.key, required ApprovalRef item, required this.onTap})
    : host = item.host,
      providerId = item.providerId,
      title = '${item.task['title'] ?? ''}',
      approval = item.approval,
      isQuestion = item.isQuestion,
      time = item.seenAt,
      project = item.projectName,
      unread = true,
      outcome = null;

  InboxRow.handled({
    super.key,
    required HandledApproval item,
    required this.onTap,
  }) : host = item.host,
       providerId = item.providerId,
       title = item.taskTitle,
       approval = item.approval,
       isQuestion = item.isQuestion,
       time = item.handledAt,
       project = item.projectName,
       unread = false,
       outcome = _outcome(item);

  final HostState host;
  final String? providerId;
  final String title, project;
  final Map<String, dynamic> approval;
  final bool isQuestion, unread;
  final DateTime? time;
  final String? outcome;
  final VoidCallback onTap;

  static String _outcome(HandledApproval item) {
    final choice = item.choice;
    if (choice == null) return tr("已在电脑上处理，或请求已失效");
    if (!item.isQuestion) {
      return tr("你的选择：{0}", [tr('${choice['label']}')]);
    }
    final form = item.approval['question'] as Map?;
    final lines = answerSummary(form, choice['answer'] as Map?);
    return lines.isEmpty ? tr("你的回答") : lines.join('；');
  }

  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final c = context.dc;
    final theme = Theme.of(context).textTheme;
    return InkWell(
      onTap: onTap,
      child: Container(
        color: c.canvas,
        padding: const EdgeInsets.fromLTRB(DcSpace.page, 12, DcSpace.page, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 48,
              height: 48,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Opacity(
                    opacity: unread ? 1 : .7,
                    child: AgentGlyph(providerId: providerId, size: 44),
                  ),
                  Positioned(
                    right: -2,
                    bottom: -2,
                    child: Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: unread ? c.warning : c.surface,
                        border: Border.all(color: c.canvas, width: 2),
                      ),
                      child: Icon(
                        isQuestion
                            ? Icons.question_mark
                            : Icons.shield_outlined,
                        size: 12,
                        color: unread ? Colors.white : c.secondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title.isEmpty ? tr("未命名会话") : title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.titleMedium?.copyWith(
                            fontWeight: unread
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        shortTime(time),
                        style: theme.bodySmall?.copyWith(
                          color: unread ? c.accent : null,
                          fontWeight: unread ? FontWeight.w600 : null,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          requestPreview(approval),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.bodyMedium?.copyWith(
                            color: unread ? c.text : c.secondary,
                          ),
                        ),
                      ),
                      if (unread) ...[
                        const SizedBox(width: 8),
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: c.accent,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  // The chat's project first, then what is (or was) asked.
                  Row(
                    children: [
                      Icon(Icons.folder_outlined, size: 13, color: c.secondary),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          project,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.bodySmall,
                        ),
                      ),
                      Text(' · ', style: theme.bodySmall),
                      Expanded(
                        child: Text(
                          outcome ?? (isQuestion ? tr("等待你回答") : tr("等待你确认")),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.bodySmall?.copyWith(
                            color: outcome == null ? c.warning : null,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
