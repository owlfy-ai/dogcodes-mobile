import 'package:dogcodes_app/l10n/strings.dart';
import 'package:flutter/material.dart';
import '../../app.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../conversation/conversation_page.dart';
import 'approval_card.dart';
import 'approval_history_card.dart';

/// One inbox entry opened. While it waits it can be answered here; once
/// handled (here or elsewhere) the same page shows the read-only record.
class InboxDetailPage extends StatelessWidget {
  const InboxDetailPage({
    super.key,
    required this.hostId,
    required this.itemKey,
  });
  final String hostId, itemKey;
  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final hub = AppScope.of(context).hub;
    return ListenableBuilder(
      listenable: hub,
      builder: (context, _) {
        final waiting = hub.approvals
            .where((a) => a.host.id == hostId && a.key == itemKey)
            .firstOrNull;
        final handled = waiting != null
            ? null
            : hub.approvalHistory
                  .where(
                    (e) => e.host.id == hostId && e.entry['key'] == itemKey,
                  )
                  .firstOrNull;
        final isQuestion = waiting?.isQuestion ?? handled?.isQuestion ?? false;
        final taskId = waiting?.task['taskId'] as String? ?? handled?.taskId;
        final canOpen =
            taskId != null && hub.host(hostId)?.task(taskId) != null;
        return Scaffold(
          appBar: DetailBar(
            title: isQuestion ? tr("问题") : tr("权限请求"),
            subtitle: waiting != null
                ? '${waiting.task['title'] ?? ''}'
                : handled?.taskTitle,
            actions: [
              if (handled != null)
                IconButton(
                  tooltip: tr("删除"),
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () {
                    hub.deleteApprovalHistory([handled]);
                    Navigator.of(context).maybePop();
                  },
                ),
            ],
          ),
          body: waiting == null && handled == null
              ? EmptyNote(
                  icon: Icons.inbox_outlined,
                  title: tr("这条记录已删除"),
                  body: tr("可以返回收件箱查看其它事项。"),
                )
              : ListView(
                  padding: const EdgeInsets.all(DcSpace.page),
                  children: [
                    if (waiting != null)
                      ApprovalCard(key: ValueKey(itemKey), item: waiting)
                    else
                      ApprovalHistoryCard(item: handled!),
                    if (canOpen)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.chat_bubble_outline),
                          label: Text(tr("查看会话")),
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => ConversationPage(
                                hostId: hostId,
                                taskId: taskId,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
        );
      },
    );
  }
}
