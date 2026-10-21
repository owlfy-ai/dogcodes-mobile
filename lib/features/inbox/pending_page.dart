import 'package:flutter/material.dart';
import '../../app.dart';
import '../../core/host_hub.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../conversation/conversation_page.dart';
import 'approval_card.dart';
import 'pending_operation.dart';

/// 04 待处理: approvals, questions and unverified writes across computers.
class PendingPage extends StatefulWidget {
  const PendingPage({super.key});
  @override
  State<PendingPage> createState() => _PendingPageState();
}

class _PendingPageState extends State<PendingPage> {
  int filter = 0;
  static const filters = ['全部', '权限', '问题'];

  @override
  Widget build(BuildContext context) {
    final hub = AppScope.of(context).hub;
    return ListenableBuilder(
      listenable: hub,
      builder: (context, _) {
        final all = hub.approvals;
        final items = switch (filter) {
          1 => all.where((a) => !a.isQuestion).toList(),
          2 => all.where((a) => a.isQuestion).toList(),
          _ => all,
        };
        final operations = filter == 0
            ? hub.hostsWithPendingOperation
            : const <HostState>[];
        final count = items.length + operations.length;
        final offline = hub.hosts.where((h) => !h.online).length;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const RootHeader(title: '待处理'),
            _Filters(
              labels: filters,
              selected: filter,
              onSelected: (i) => setState(() => filter = i),
            ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: () => Future.wait([
                  for (final h in hub.hosts)
                    if (h.online) hub.refresh(h),
                ]),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(
                    DcSpace.page,
                    12,
                    DcSpace.page,
                    24,
                  ),
                  children: [
                    Text(
                      count == 0 ? '没有需要你处理的事项' : '$count 项需要你处理',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (offline > 0)
                      Text(
                        '$offline 台电脑离线，其待处理事项将在重新连接后显示。',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    for (final h in operations)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: PendingOperationCard(
                          host: h,
                          onSubmitted: (task) => _open(context, h.id, task),
                        ),
                      ),
                    for (final a in items)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            ApprovalCard(
                              key: ValueKey(
                                '${a.host.id}/${a.approval['approvalId']}',
                              ),
                              item: a,
                            ),
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton(
                                onPressed: () => _open(
                                  context,
                                  a.host.id,
                                  a.task['taskId'] as String,
                                ),
                                child: const Text('查看会话'),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  void _open(BuildContext context, String host, String task) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ConversationPage(hostId: host, taskId: task),
        ),
      );
}

class _Filters extends StatelessWidget {
  const _Filters({
    required this.labels,
    required this.selected,
    required this.onSelected,
  });
  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelected;
  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.line)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++)
            Expanded(
              child: Semantics(
                selected: i == selected,
                button: true,
                child: InkWell(
                  onTap: () => onSelected(i),
                  child: Container(
                    height: DcSpace.touch,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(
                          width: 2,
                          color: i == selected ? c.accent : Colors.transparent,
                        ),
                      ),
                    ),
                    child: Text(
                      labels[i],
                      style: TextStyle(
                        fontWeight: i == selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                        color: i == selected ? c.text : c.secondary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
