import 'package:dogcodes_app/l10n/strings.dart';
import 'package:flutter/material.dart';
import '../../app.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../conversation/conversation_page.dart';
import '../../core/host_hub.dart';
import 'inbox_detail_page.dart';
import 'inbox_row.dart';
import 'pending_operation.dart';

/// 04 待处理: an inbox of approvals and questions across computers, newest
/// first. Waiting requests read as unread; handled ones stay as read-only
/// history until deleted. Unverified writes sit above the list.
class PendingPage extends StatefulWidget {
  const PendingPage({super.key});
  @override
  State<PendingPage> createState() => _PendingPageState();
}

class _PendingPageState extends State<PendingPage> {
  int filter = 0;
  static List<String> get filters => [tr("全部"), tr("权限"), tr("问题")];

  bool _kind(bool isQuestion) => filter == 0 || (filter == 2) == isQuestion;

  Future<void> _clearHistory(List<HandledApproval> handled) async {
    final hub = AppScope.of(context).hub;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(tr("清空已处理记录？")),
        content: Text(tr("只从这部手机删除，等待处理的请求不受影响。")),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: Text(tr("取消")),
          ),
          TextButton(
            onPressed: () => Navigator.pop(d, true),
            child: Text(tr("清空")),
          ),
        ],
      ),
    );
    if (ok == true) hub.deleteApprovalHistory(handled);
  }

  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final hub = AppScope.of(context).hub;
    return ListenableBuilder(
      listenable: hub,
      builder: (context, _) {
        final waiting = [
          for (final a in hub.approvals)
            if (_kind(a.isQuestion)) a,
        ];
        // An unconfirmed answer belongs with its kind: permissions or
        // questions. Every other unconfirmed write only shows under 全部.
        bool sameKind(Map<String, dynamic>? op) =>
            op?['kind'] == 'approval' && (filter == 2) == _answersQuestion(op!);
        final operations = hub.hostsWithPendingOperation
            .where((h) => filter == 0 || sameKind(h.pendingOperation))
            .toList();
        final handled = [
          for (final e in hub.approvalHistory)
            if (_kind(e.isQuestion)) e,
        ];
        final offline = hub.hosts.where((h) => !h.online).length;
        final small = Theme.of(context).textTheme.bodySmall;
        final rows = <Widget>[];
        if (waiting.isNotEmpty) {
          rows.add(_GroupLabel(tr("{0} 项需要你处理", [waiting.length])));
          for (final a in waiting) {
            rows.add(
              InboxRow.waiting(
                key: ValueKey('waiting:${a.host.id}/${a.key}'),
                item: a,
                onTap: () => _detail(context, a.host.id, a.key),
              ),
            );
          }
        }
        String? group;
        for (final e in handled) {
          final day = dayGroup(e.handledAt);
          if (day != group) rows.add(_GroupLabel(group = day));
          rows.add(
            Dismissible(
              key: ValueKey('handled:${e.host.id}/${e.entry['key']}'),
              direction: DismissDirection.endToStart,
              background: const _DeleteBackground(),
              onDismissed: (_) => hub.deleteApprovalHistory([e]),
              child: InboxRow.handled(
                item: e,
                onTap: () => _detail(context, e.host.id, '${e.entry['key']}'),
              ),
            ),
          );
        }
        final empty = rows.isEmpty && operations.isEmpty;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            RootHeader(
              title: tr("待处理"),
              actions: [
                if (handled.isNotEmpty)
                  PopupMenuButton<void>(
                    tooltip: tr("更多"),
                    icon: const Icon(Icons.more_horiz),
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        onTap: () => _clearHistory(handled),
                        child: Text(tr("清空已处理记录")),
                      ),
                    ],
                  ),
              ],
            ),
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
                child: empty
                    ? LayoutBuilder(
                        builder: (context, box) => SingleChildScrollView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              minHeight: box.maxHeight,
                            ),
                            child: _InboxEmpty(
                              filter: filter,
                              offline: offline,
                            ),
                          ),
                        ),
                      )
                    : ListView(
                        padding: const EdgeInsets.only(bottom: 24),
                        children: [
                          if (offline > 0)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(
                                DcSpace.page,
                                12,
                                DcSpace.page,
                                0,
                              ),
                              child: Text(
                                tr("{0} 台电脑离线，其待处理事项将在重新连接后显示。", [offline]),
                                style: small,
                              ),
                            ),
                          for (final card in _operationCards(operations))
                            Padding(
                              padding: const EdgeInsets.fromLTRB(
                                DcSpace.page,
                                12,
                                DcSpace.page,
                                0,
                              ),
                              child: card,
                            ),
                          ...rows,
                        ],
                      ),
              ),
            ),
          ],
        );
      },
    );
  }

  List<Widget> _operationCards(List<HostState> operations) => [
    for (final h in operations)
      if (filter != 0)
        PendingOperationCard(host: h)
      else ...[
        for (final cancellation in h.pendingCancellations)
          PendingOperationCard(
            key: ValueKey(cancellation['envelope']['commandId']),
            host: h,
            operation: cancellation,
          ),
        for (final stop in h.pendingTerminalStops)
          PendingOperationCard(
            key: ValueKey('stop:${stop['request']['operationId']}'),
            host: h,
            operation: stop,
          ),
        if (h.pendingOperation != null)
          PendingOperationCard(
            host: h,
            onSubmitted: (task) => _open(context, h.id, task),
          ),
        if (h.sideOperation != null)
          PendingOperationCard(host: h, operation: h.sideOperation),
      ],
  ];

  void _detail(BuildContext context, String host, String key) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => InboxDetailPage(hostId: host, itemKey: key),
        ),
      );

  void _open(BuildContext context, String host, String task) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ConversationPage(hostId: host, taskId: task),
        ),
      );
}

class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(DcSpace.page, 18, DcSpace.page, 4),
      child: Text(
        text,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _DeleteBackground extends StatelessWidget {
  const _DeleteBackground();
  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    return Container(
      color: context.dc.removed,
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.delete_outline, color: Colors.white),
          const SizedBox(width: 6),
          Text(tr("删除"), style: const TextStyle(color: Colors.white)),
        ],
      ),
    );
  }
}

/// A friendly empty inbox: what will arrive here, drawn as a small stack of
/// message bubbles rather than a lone icon.
class _InboxEmpty extends StatelessWidget {
  const _InboxEmpty({required this.filter, required this.offline});
  final int filter, offline;
  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final c = context.dc;
    final theme = Theme.of(context).textTheme;
    final (title, body) = switch (filter) {
      1 => (tr("没有权限请求"), tr("Agent 需要运行命令或修改文件时，会在这里请你确认。")),
      2 => (tr("没有待回答的问题"), tr("Agent 需要你做选择或补充信息时，问题会出现在这里。")),
      _ => (tr("收件箱是空的"), tr("Agent 请求权限或向你提问时会出现在这里，处理过的记录也会保留，方便回看。")),
    };
    Widget bubble(IconData icon, double size, Color tint) => Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: c.canvas,
        borderRadius: BorderRadius.circular(size * .32),
        border: Border.all(color: c.line),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .06),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Icon(icon, size: size * .46, color: tint),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 24, 32, 48),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 200,
            height: 150,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: 132,
                  height: 132,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: c.accent.withValues(alpha: .10),
                  ),
                ),
                Container(
                  width: 92,
                  height: 92,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: c.accent.withValues(alpha: .16),
                  ),
                ),
                bubble(Icons.inbox_outlined, 64, c.accent),
                Positioned(
                  left: 12,
                  top: 18,
                  child: bubble(Icons.verified_user_outlined, 40, c.secondary),
                ),
                Positioned(
                  right: 14,
                  bottom: 14,
                  child: bubble(Icons.help_outline, 40, c.secondary),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Text(title, textAlign: TextAlign.center, style: theme.titleLarge),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: Text(
              body,
              textAlign: TextAlign.center,
              style: theme.bodyMedium?.copyWith(color: c.secondary),
            ),
          ),
          if (offline > 0) ...[
            const SizedBox(height: 16),
            Text(
              tr("{0} 台电脑离线，其待处理事项将在重新连接后显示。", [offline]),
              textAlign: TextAlign.center,
              style: theme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}

/// An approval record carries an answer only when it replies to a question.
bool _answersQuestion(Map<String, dynamic> op) =>
    op['envelope']?['payload']?['data']?['answer'] != null;

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
    watchAppLanguage(context);
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
