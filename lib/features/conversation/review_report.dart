import 'package:dogcodes_app/l10n/strings.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../../app.dart';
import '../../core/host_hub.dart';
import '../../core/mobile_operations.dart';
import '../../ui/widgets.dart';
import '../tools/changes_page.dart' show UnifiedDiff;
import '../tools/line_diff.dart';
import 'timeline_view.dart' show AgentMarkdown, TimelineView;
import 'turn_reviews_sheet.dart' show reviewActive;

Map<String, String> get _severity => {
  'critical': tr("严重"),
  'high': tr("高"),
  'medium': tr("中"),
  'low': tr("低"),
};
Map<String, String> get _verdict => {
  'confirmed': tr("AI 复核支持"),
  'refuted': tr("AI 复核不支持"),
  'uncertain': tr("待核实"),
};

class ReviewReportView extends StatefulWidget {
  const ReviewReportView({
    super.key,
    required this.session,
    required this.run,
    required this.busy,
    required this.onChanged,
    this.onCancel,
    this.onRetry,
    this.onRecheck,
    this.activeRecheckTurns = const {},
  });
  final SessionRef session;
  final Map<String, dynamic> run;
  final bool busy;
  final Future<void> Function() onChanged;
  final VoidCallback? onCancel, onRetry;
  final void Function(String turnId)? onRecheck;
  final Set<String> activeRecheckTurns;
  @override
  State<ReviewReportView> createState() => _ReviewReportViewState();
}

class _ReviewReportViewState extends State<ReviewReportView> {
  final selected = <int>{};
  Map<String, dynamic>? repair;
  String? error;
  bool reading = false, busy = false, repairKnown = false;
  HostState get host => widget.session.host;
  String get task => widget.session.taskId;
  String get runId => widget.run['request']['runId'] as String;
  @override
  void initState() {
    super.initState();
    _loadRepair();
  }

  @override
  void didUpdateWidget(ReviewReportView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _loadRepair();
  }

  Future<void> _loadRepair() async {
    if (reading || !host.online || host.link == null) return;
    reading = true;
    final link = host.link!, epoch = host.connectionEpoch;
    try {
      final value = await link.call('review_repair', [
        {'action': 'get', 'taskId': task, 'runId': runId},
      ]);
      if (!mounted || host.link != link || host.connectionEpoch != epoch) {
        return;
      }
      setState(() {
        repair = value is Map ? Map<String, dynamic>.from(value) : null;
        repairKnown = true;
      });
    } catch (e) {
      if (mounted && host.link == link && host.connectionEpoch == epoch) {
        setState(() {
          repairKnown = false;
          error = tr("无法核实修复状态：{0}", [e]);
        });
      }
    } finally {
      reading = false;
    }
  }

  Future<void> _repair([String? action]) async {
    if (busy || widget.busy || !host.online || host.link == null) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (action == null) {
        await host.operations.startRepair(
          host.link!,
          taskId: task,
          run: widget.run,
          findings: selected.toList(),
        );
      } else {
        final entry = repair!;
        await host.link!.call('review_repair', [
          {
            'action': action,
            'taskId': task,
            'runId': runId,
            'operationId': entry['intent']['operationId'],
          },
        ]);
        // A service-owned repair can also be pending in this phone's slot.
        final pending = await host.operations.pending();
        if (pending?['kind'] == 'repair' &&
            pending?['request']?['reference']?['runId'] == runId) {
          await host.operations.verify(host.link!);
        }
      }
      if (mounted) setState(() => selected.clear());
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) {
        await AppScope.of(context).hub.refreshOperation(host);
        await _loadRepair();
        await widget.onChanged();
        if (mounted) setState(() => busy = false);
      }
    }
  }

  Future<void> _source(Map finding) async {
    final link = host.link;
    if (link == null || !host.online) return;
    final future = link.call('review_source', [task, runId, finding['fileId']]);
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => FractionallySizedBox(
        heightFactor: .85,
        child: FutureBuilder<dynamic>(
          future: future,
          builder: (context, snap) => ListView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            children: [
              Text(tr("审查代码证据"), style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              SelectableText(
                tr("{0} · {1}–{2} 行", [
                  finding['path'] ?? finding['fileId'],
                  finding['startLine'],
                  finding['endLine'],
                ]),
              ),
              InlineNotice(tr("这是审查时保存的版本，当前文件可能已变化。")),
              if (snap.hasError)
                InlineNotice(tr("读取审查代码失败：{0}", [snap.error]), danger: true)
              else if (!snap.hasData)
                const LinearProgressIndicator()
              else if (snap.data is Map)
                UnifiedDiff(
                  lines: diffLines(
                    snap.data['before'] is String
                        ? const LineSplitter().convert(
                            snap.data['before'] as String,
                          )
                        : [],
                    snap.data['after'] is String
                        ? const LineSplitter().convert(
                            snap.data['after'] as String,
                          )
                        : [],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final run = widget.run, active = reviewActive(widget.run);
    final report = run['report'] as Map?;
    final findings = [
      for (final f in report?['findings'] as List? ?? const [])
        if (f is Map) f,
    ];
    final pendingRepair = repair?['state'] == 'pending';
    final enabled = host.online && !widget.busy && !busy;
    final taskRunning = host.task(task)?['activePrimaryRun'] != null;
    final failure = run['error'] as String?;
    final networkFailure = RegExp(
      r'timed?\s*out|timeout|HTTP/2|connection|network',
      caseSensitive: false,
    ).hasMatch(failure ?? '');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (failure != null && failure.isNotEmpty) ...[
          InlineNotice(
            networkFailure ? tr("审查连接中断，本次审查未完成。请检查网络后重新检查。") : failure,
            danger: true,
          ),
          if (networkFailure)
            ExpansionTile(
              title: Text(tr("错误详情")),
              children: [SelectableText(failure)],
            ),
        ],
        if (run['status'] == 'interrupted' && failure == null)
          InlineNotice(tr("审查连接中断，本次审查未完成。"), danger: true),
        if (report != null) ...[
          for (final warning in report['warnings'] as List? ?? const [])
            InlineNotice('$warning'),
          if ((report['files'] as List? ?? []).isNotEmpty)
            ExpansionTile(
              title: Text(tr("文件覆盖情况")),
              children: [
                for (final f in report['files'] as List)
                  if (f is Map)
                    ListTile(
                      title: Text(
                        '${f['rootLabel'] == null ? '' : '${f['rootLabel']}/'}${f['path']}',
                      ),
                      subtitle: Text(
                        '${{'reported': tr("已检查"), 'partial': tr("部分原文缺失"), 'not_reported': tr("未报告检查"), 'unavailable': tr("原文不可用")}[f['status']] ?? tr("待核实")}${(f['rules'] as List? ?? []).isEmpty ? '' : '\n${(f['rules'] as List).join('\n')}'}',
                      ),
                    ),
              ],
            ),
          if (findings.isEmpty)
            Text(
              run['status'] == 'completed' && report['structured'] == true
                  ? tr("本次审查未报告问题。")
                  : tr("审查尚未形成完整问题报告，不能据此判断是否存在问题。"),
            ),
          for (var i = 0; i < findings.length; i++)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Checkbox(
                  value: selected.contains(i),
                  onChanged: active || !enabled || pendingRepair
                      ? null
                      : (value) => setState(() {
                          value == true ? selected.add(i) : selected.remove(i);
                        }),
                ),
                Expanded(
                  child: ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: Text(
                      '${run['request']['kind'] == 'security' ? tr("潜在{0}风险", [_severity[findings[i]['severity']] ?? '']) : _severity[findings[i]['severity']] ?? ''} · ${findings[i]['title']}',
                    ),
                    subtitle: Text(
                      tr("{0}{1} · {2}{3}–{4} 行", [
                        findings[i]['rootLabel'] == null
                            ? ''
                            : '${findings[i]['rootLabel']}/',
                        findings[i]['path'] ?? findings[i]['fileId'],
                        findings[i]['side'] == 'before' ? tr("改动前 · ") : '',
                        findings[i]['startLine'],
                        findings[i]['endLine'],
                      ]),
                    ),
                    children: [
                      SelectableText('${findings[i]['description'] ?? ''}'),
                      if (findings[i]['verification'] is Map) ...[
                        const SizedBox(height: 8),
                        Text(
                          _verdict[findings[i]['verification']['verdict']] ??
                              tr("待核实"),
                        ),
                        SelectableText(
                          '${findings[i]['verification']['reason'] ?? ''}',
                        ),
                      ],
                      if ('${findings[i]['evidence'] ?? ''}'.isNotEmpty)
                        CodeBlock('${findings[i]['evidence']}'),
                      if ('${findings[i]['suggestion'] ?? ''}'.isNotEmpty)
                        SelectableText(
                          tr("建议：{0}", [findings[i]['suggestion']]),
                        ),
                      if (findings[i]['locationVerified'] != true)
                        Text(
                          '${findings[i]['locationNote'] ?? tr("位置尚未校验，请先核实。")}',
                        ),
                      TextButton.icon(
                        onPressed:
                            host.online &&
                                findings[i]['locationVerified'] == true
                            ? () => _source(findings[i])
                            : null,
                        icon: const Icon(Icons.difference_outlined, size: 18),
                        label: Text(tr("查看审查时的代码")),
                      ),
                    ],
                  ),
                ),
              ],
            ),
        ],
        if (findings.isNotEmpty && !active) ...[
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TextButton(
                onPressed: !enabled || pendingRepair
                    ? null
                    : () => setState(() {
                        if (selected.length == findings.length) {
                          selected.clear();
                        } else {
                          selected.addAll(
                            List.generate(findings.length, (i) => i),
                          );
                        }
                      }),
                child: Text(
                  selected.length == findings.length ? tr("取消全选") : tr("全选问题"),
                ),
              ),
              Text(tr("已选 {0} 项", [selected.length])),
              FilledButton(
                onPressed:
                    !enabled ||
                        !repairKnown ||
                        pendingRepair ||
                        taskRunning ||
                        selected.isEmpty ||
                        host.pendingOperation != null
                    ? null
                    : () => _repair(),
                child: Text(tr("开始修复")),
              ),
            ],
          ),
          if (taskRunning) InlineNotice(tr("主对话正在回复，结束后可提交修复。")),
          if (repair?['state'] == 'submitted')
            InlineNotice(tr("修复已提交给主 Agent，携带所选问题及原审查上下文。")),
        ],
        if (pendingRepair) ...[
          InlineNotice(tr("有一项修复尚未提交。{0}", [repair?['lastError'] ?? ''])),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: enabled ? () => _repair('resume') : null,
                child: Text(tr("继续原修复")),
              ),
              TextButton(
                onPressed: enabled ? () => _repair('abandon') : null,
                child: Text(tr("放弃这次修复")),
              ),
            ],
          ),
        ],
        for (final r in run['repairs'] as List? ?? const [])
          if (r is Map)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                tr("问题 {0} · {1}", [
                  (r['findingIndices'] as List? ?? [])
                      .map((i) => (i as num).toInt() + 1)
                      .join('、'),
                  {
                        'running': tr("修复中"),
                        'completed': tr("修复已完成"),
                        'failed': tr("修复失败"),
                        'cancelled': tr("修复已取消"),
                        'interrupted': tr("修复已中断"),
                      }[r['status']] ??
                      tr("待核实"),
                ]),
              ),
              subtitle: r['status'] == 'completed'
                  ? TextButton(
                      onPressed:
                          widget.onRecheck == null ||
                              widget.activeRecheckTurns.contains(r['turnId'])
                          ? null
                          : () => widget.onRecheck!(r['turnId'] as String),
                      child: Text(tr("复审修复后的版本")),
                    )
                  : null,
            ),
        if (error != null) InlineNotice(error!, danger: true),
        if ('${run['result'] ?? ''}'.isNotEmpty)
          ExpansionTile(
            title: Text(tr("审查原文")),
            children: [AgentMarkdown('${run['result']}')],
          ),
        if ((run['activities'] as List? ?? []).isNotEmpty)
          ExpansionTile(
            title: Text(tr("审查过程")),
            children: [
              TimelineView(
                items: [
                  for (final a in run['activities'] as List)
                    if (a is Map && a['data'] is Map)
                      {
                        'itemId': a['itemId'],
                        'kind': 'activity',
                        'text': jsonEncode(a['data']),
                      },
                ],
              ),
            ],
          ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: active ? widget.onCancel : widget.onRetry,
            child: Text(active ? tr("取消审查") : tr("重新检查")),
          ),
        ),
      ],
    );
  }
}
