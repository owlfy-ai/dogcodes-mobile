import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/host_hub.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../sessions/fork_page.dart';
import 'timeline_model.dart';
import 'turn_statistics.dart';
import 'turn_reviews_sheet.dart';

/// Compact touch targets; longer content lives in scrollable bottom sheets.
class TurnActions extends StatelessWidget {
  const TurnActions({super.key, required this.entry, this.session});
  final TurnActionsEntry entry;
  final SessionRef? session;

  @override
  Widget build(BuildContext context) {
    final reply = finalTurnReply(entry.items), s = session;
    final finishedAt = DateTime.tryParse('${entry.completion['completedAt']}');
    final forkBlocked = s == null
        ? null
        : !s.host.online
        ? '电脑离线，连接后才能 Fork'
        : s.running
        ? '会话正在运行，结束后才能从本轮 Fork'
        : null;
    return Padding(
      key: ValueKey('turn-actions:${entry.turnId}'),
      padding: const EdgeInsets.only(top: 4, bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              IconButton(
                tooltip: '复制本轮回复',
                icon: const Icon(Icons.copy_outlined, size: 19),
                onPressed: reply.isEmpty
                    ? null
                    : () async {
                        try {
                          await Clipboard.setData(ClipboardData(text: reply));
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('已复制本轮回复')),
                            );
                          }
                        } catch (_) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('复制失败，请重试')),
                            );
                          }
                        }
                      },
              ),
              IconButton(
                tooltip: '本轮消耗',
                icon: const Icon(Icons.bar_chart_outlined, size: 21),
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  useSafeArea: true,
                  showDragHandle: true,
                  isScrollControlled: true,
                  builder: (_) => ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.sizeOf(context).height * .8,
                    ),
                    child: ListView(
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                      children: [
                        Text(
                          '本轮消耗',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 12),
                        for (final (label, value) in turnStatistics(entry))
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Text(
                                    label,
                                    style: TextStyle(
                                      color: context.dc.secondary,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: SelectableText(
                                    value,
                                    textAlign: TextAlign.end,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              IconButton(
                // Stays tappable while blocked so the phone can say why.
                tooltip: forkBlocked ?? '从本轮 Fork',
                icon: Icon(
                  Icons.fork_right,
                  size: 21,
                  color: forkBlocked == null ? null : context.dc.secondary,
                ),
                onPressed: s == null
                    ? null
                    : forkBlocked != null
                    ? () => ScaffoldMessenger.of(context)
                        ..hideCurrentSnackBar()
                        ..showSnackBar(SnackBar(content: Text(forkBlocked)))
                    : () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => ForkPage(
                            session: s,
                            turnId: entry.turnId,
                            prompt:
                                entry.items
                                        .where(
                                          (i) => i['kind'] == 'user_message',
                                        )
                                        .firstOrNull?['text']
                                    as String?,
                          ),
                        ),
                      ),
              ),
              TextButton.icon(
                icon: const Icon(Icons.fact_check_outlined, size: 19),
                label: const Text('本轮审查'),
                onPressed: s == null
                    ? null
                    : () => showModalBottomSheet<void>(
                        context: context,
                        useSafeArea: true,
                        showDragHandle: true,
                        isScrollControlled: true,
                        builder: (_) => FractionallySizedBox(
                          heightFactor: .9,
                          child: TurnReviewsSheet(
                            session: s,
                            turnId: entry.turnId,
                          ),
                        ),
                      ),
              ),
            ],
          ),
          if (finishedAt != null)
            Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Text(
                shortTime(finishedAt),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }
}
