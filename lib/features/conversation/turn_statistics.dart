import 'package:dogcodes_app/l10n/strings.dart';
import '../../core/host_hub.dart';
import 'timeline_model.dart';

/// Match the desktop's native counters. Missing usage is never shown as zero.
List<(String, String)> turnStatistics(TurnActionsEntry turn) {
  bool valid(dynamic v) => v is num && v.isFinite && v >= 0;
  String number(num v, [int decimals = 0]) =>
      v.toStringAsFixed(decimals).replaceFirst(RegExp(r'\.0+$'), '');
  final rows = <(String, String)>[];
  final provider = turn.items
      .map((i) => i['providerId'])
      .whereType<String>()
      .firstOrNull;
  if (provider != null) rows.add(('Agent', agentLabel(provider)));
  final start = DateTime.tryParse('${turn.completion['startedAt']}');
  final end = DateTime.tryParse('${turn.completion['completedAt']}');
  if (start != null && end != null && !end.isBefore(start)) {
    rows.add((
      tr("本轮耗时"),
      tr("{0} 秒", [number(end.difference(start).inMilliseconds / 1000, 1)]),
    ));
  }
  final completions = [
    for (final i in turn.items)
      if (i['turnCompletion'] is Map) i['turnCompletion'] as Map,
  ];
  final first = completions
      .map((c) => c['firstOutputMs'])
      .where((v) => valid(v))
      .firstOrNull;
  if (first != null) {
    rows.add((tr("首个输出等待"), tr("{0} 秒", [number(first / 1000, 2)])));
  }
  final usage = completions.map((c) => c['usage']).whereType<Map>().firstOrNull;
  if (usage == null) {
    rows.add((tr("消耗数据"), tr("Agent 未提供")));
    return rows;
  }
  if (valid(usage['outputTokensPerSecond'])) {
    rows.add((
      tr("生成速度"),
      tr("{0} Tokens/秒", [number(usage['outputTokensPerSecond'], 1)]),
    ));
  }
  final models = (usage['models'] as List? ?? []).whereType<String>().toSet();
  if (models.isNotEmpty) rows.add((tr("模型"), models.join('、')));
  if (usage['scope'] == 'unknown') {
    rows.add((tr("消耗数据"), tr("未记录")));
    return rows;
  }
  final requests = usage['scope'] == 'observed_requests';
  for (final (key, label, suffix, decimals) in [
    ('requestCount', tr("模型请求"), tr(" 次"), 0),
    ('inputTokens', requests ? tr("输入 Tokens（含缓存）") : tr("输入 Tokens"), '', 0),
    ('outputTokens', requests ? tr("输出 Tokens（含推理）") : tr("输出 Tokens"), '', 0),
    ('cacheReadTokens', tr("缓存读取 Tokens"), '', 0),
    ('cacheWriteTokens', tr("缓存写入 Tokens"), '', 0),
    ('reasoningTokens', tr("推理 Tokens"), '', 0),
    ('costUsd', tr("原生费用（USD）"), '', 6),
    ('credits', 'Credits', '', 4),
  ]) {
    final value = usage[key];
    if (valid(value)) rows.add((label, '${number(value, decimals)}$suffix'));
  }
  if (requests && valid(usage['inputTokens']) && valid(usage['outputTokens'])) {
    rows.add((
      tr("合计 Tokens"),
      number(usage['inputTokens'] + usage['outputTokens']),
    ));
  }
  if (usage['partial'] == true || usage['completeness'] == 'partial') {
    rows.add((
      tr("统计范围"),
      tr("部分数据{0}", [
        usage['incompleteReason'] == null
            ? ''
            : ' · ${usage['incompleteReason']}',
      ]),
    ));
  }
  return rows;
}

String finalTurnReply(List<Item> items) {
  for (final i in items.reversed) {
    final text = i['kind'] == 'assistant_message'
        ? i['text'] as String?
        : activityOf(i)?.type == 'message'
        ? activityOf(i)?.text
        : null;
    if (text != null && text.trim().isNotEmpty) return text;
  }
  return '';
}
