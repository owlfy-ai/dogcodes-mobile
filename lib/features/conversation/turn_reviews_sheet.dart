import 'package:dogcodes_app/l10n/strings.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import '../../app.dart';
import '../../core/host_hub.dart';
import '../../core/mobile_operations.dart';
import '../../core/protocol.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../inbox/pending_operation.dart';
import 'review_report.dart';

Map<String, String> get reviewLabels => {
  'code': tr("审查代码"),
  'security': tr("安全检查"),
  'performance': tr("性能分析"),
  'tests': tr("检查测试"),
  'requirements': tr("对照要求"),
  'impact': tr("评估影响"),
};
Map<String, String> get reviewStatuses => {
  'queued': tr("准备中"),
  'running': tr("检查中"),
  'cancelling': tr("正在取消"),
  'completed': tr("已完成"),
  'failed': tr("失败"),
  'cancelled': tr("已取消"),
  'interrupted': tr("连接中断"),
};
bool reviewActive(Map run) =>
    ['queued', 'running', 'cancelling'].contains(run['status']);

/// One shared query while the sheet is open, rather than polling every turn.
class TurnReviewsSheet extends StatefulWidget {
  const TurnReviewsSheet({
    super.key,
    required this.session,
    required this.turnId,
  });
  final SessionRef session;
  final String turnId;
  @override
  State<TurnReviewsSheet> createState() => _TurnReviewsSheetState();
}

class _TurnReviewsSheetState extends State<TurnReviewsSheet> {
  List<Map<String, dynamic>> runs = [], executors = [];
  Set<String> activeRechecks = {};
  int? catalogEpoch;
  String? selected, openRun, error, readError;
  bool loading = true, reading = false, busy = false, catalogLoaded = false;
  Timer? timer;
  HostState get host => widget.session.host;
  Map<String, dynamic>? get executor =>
      executors.where((e) => _key(e) == selected).firstOrNull ??
      executors.firstOrNull;
  String _key(Map e) => '${e['providerId']}:${e['installationId'] ?? ''}';
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool catalog = false}) async {
    if (reading) return;
    timer?.cancel();
    reading = true;
    final link = host.link, epoch = host.connectionEpoch;
    try {
      if (!host.online || link == null) {
        throw ProtocolException(tr("电脑离线，请重新连接后查看审查。"));
      }
      final all = await link.call('turn_reviews', [widget.session.taskId]);
      if (all is! List) throw ProtocolException(tr("电脑端暂不支持本轮审查，请更新电脑端后重试。"));
      List<Map<String, dynamic>>? choices;
      if (!catalogLoaded || catalogEpoch != epoch || catalog) {
        final found = await link.call('review_executors', []);
        if (found is! List) throw ProtocolException(tr("无法读取可用的审查 Agent。"));
        choices = [
          for (final e in found)
            if (e is Map) Map<String, dynamic>.from(e),
        ];
      }
      if (!mounted ||
          host.link != link ||
          host.connectionEpoch != epoch ||
          !host.online) {
        return;
      }
      setState(() {
        activeRechecks = {
          for (final r in all)
            if (r is Map &&
                reviewActive(r) &&
                r['request']?['recheckOf'] is Map)
              '${r['request']['recheckOf']['runId']}:${r['request']['recheckOf']['repairTurnId']}',
        };
        runs = [
          for (final r in all)
            if (r is Map && r['request']?['turnId'] == widget.turnId)
              Map<String, dynamic>.from(r),
        ];
        if (choices != null) {
          executors = choices;
          catalogLoaded = true;
          catalogEpoch = epoch;
        }
        readError = null;
      });
    } catch (e) {
      if (mounted && host.link == link && host.connectionEpoch == epoch) {
        setState(() => readError = '$e');
      }
    } finally {
      reading = false;
      if (mounted) {
        setState(() => loading = false);
        timer = Timer(Duration(seconds: runs.any(reviewActive) ? 2 : 8), _load);
      }
    }
  }

  Future<void> _operate(Future<dynamic> Function() action) async {
    if (busy || !host.online) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) {
        await AppScope.of(context).hub.refreshOperation(host);
        await _load();
        if (mounted) setState(() => busy = false);
      }
    }
  }

  Future<void> _start(
    String kind, {
    Map<String, dynamic>? previous,
    String? repairTurn,
  }) async {
    final target = executor, link = host.link;
    if (target == null || link == null) return;
    await _operate(() async {
      final result = await host.operations.startReview(
        link,
        taskId: widget.session.taskId,
        turnId: repairTurn ?? widget.turnId,
        kind: kind,
        executor: target,
        retryOf: previous?['workspaceReview'] == true && repairTurn == null
            ? previous!['request']['runId'] as String
            : null,
        recheckOf: repairTurn == null
            ? previous?['request']?['recheckOf'] as Map<String, dynamic>?
            : {
                'runId': previous!['request']['runId'],
                'repairTurnId': repairTurn,
              },
      );
      if (mounted && result is Map) {
        setState(() => openRun = result['request']['runId'] as String);
        if (repairTurn != null) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(tr("已发起复审，可在修复轮次底部查看。"))));
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final hub = AppScope.of(context).hub;
    return ListenableBuilder(
      listenable: hub,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    tr("本轮审查"),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  tooltip: tr("刷新审查"),
                  onPressed: busy ? null : () => _load(catalog: true),
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              children: [
                if (!host.online) InlineNotice(tr("电脑离线，审查会继续在电脑上运行。")),
                if (loading) const LinearProgressIndicator(),
                if (!loading && executors.isEmpty)
                  InlineNotice(tr("暂无可用的审查 Agent，请在电脑上连接或重新检测 Agent。")),
                if (executors.isNotEmpty)
                  DropdownButtonFormField<String>(
                    key: ValueKey('review-agent:${_key(executor!)}'),
                    initialValue: _key(executor!),
                    isExpanded: true,
                    decoration: InputDecoration(labelText: tr("审查使用的 Agent")),
                    items: [
                      for (final e in executors)
                        DropdownMenuItem(
                          value: _key(e),
                          child: Text(agentLabel(e['providerId'] as String?)),
                        ),
                    ],
                    onChanged: busy
                        ? null
                        : (v) => setState(() => selected = v),
                  ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final (kind, icon) in const [
                      ('code', Icons.code),
                      ('security', Icons.shield_outlined),
                      ('performance', Icons.speed),
                    ])
                      OutlinedButton.icon(
                        icon: Icon(icon, size: 18),
                        label: Text(reviewLabels[kind]!),
                        onPressed:
                            !host.online ||
                                busy ||
                                loading ||
                                executor == null ||
                                host.pendingOperation != null ||
                                runs.any(
                                  (r) =>
                                      reviewActive(r) &&
                                      r['request']['kind'] == kind,
                                )
                            ? null
                            : () => _start(kind),
                      ),
                  ],
                ),
                if (error != null) InlineNotice(error!, danger: true),
                if (readError != null) InlineNotice(readError!, danger: true),
                if (host.pendingOperation != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: PendingOperationCard(host: host),
                  ),
                const SizedBox(height: 12),
                if (!loading && runs.isEmpty && readError == null)
                  Text(tr("本轮尚未发起审查。")),
                for (final run in runs.reversed) ...[
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      reviewLabels[run['request']['kind']] ?? tr("历史审查"),
                    ),
                    subtitle: Text(
                      '${agentLabel(run['request']['executor']['providerId'] as String?)} · ${shortTime(DateTime.tryParse('${run['createdAt']}'))}',
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          reviewStatuses[run['status']] ?? tr("状态未知"),
                          style: TextStyle(
                            color: run['status'] == 'completed'
                                ? context.dc.accent
                                : context.dc.secondary,
                          ),
                        ),
                        Icon(
                          openRun == run['request']['runId']
                              ? Icons.expand_less
                              : Icons.expand_more,
                        ),
                      ],
                    ),
                    onTap: () => setState(
                      () => openRun = openRun == run['request']['runId']
                          ? null
                          : run['request']['runId'] as String,
                    ),
                  ),
                  if (openRun == run['request']['runId'])
                    ReviewReportView(
                      key: ValueKey(run['request']['runId']),
                      session: widget.session,
                      run: run,
                      busy: busy,
                      activeRecheckTurns: {
                        for (final id in activeRechecks)
                          if (id.startsWith('${run['request']['runId']}:'))
                            id.substring('${run['request']['runId']}:'.length),
                      },
                      onChanged: () async {
                        await hub.refresh(host);
                        await _load();
                      },
                      onCancel:
                          busy || !host.online || run['status'] == 'cancelling'
                          ? null
                          : () => _operate(
                              () => host.link!.call('cancel_turn_review', [
                                widget.session.taskId,
                                run['request']['runId'],
                              ]),
                            ),
                      onRetry:
                          busy ||
                              !host.online ||
                              executor == null ||
                              host.pendingOperation != null ||
                              ![
                                'code',
                                'security',
                                'performance',
                              ].contains(run['request']['kind'])
                          ? null
                          : () => _start(
                              run['request']['kind'] as String,
                              previous: run,
                            ),
                      onRecheck:
                          busy ||
                              !host.online ||
                              executor == null ||
                              host.pendingOperation != null ||
                              ![
                                'code',
                                'security',
                                'performance',
                              ].contains(run['request']['kind'])
                          ? null
                          : (turn) => _start(
                              run['request']['kind'] as String,
                              previous: run,
                              repairTurn: turn,
                            ),
                    ),
                  const Divider(),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
