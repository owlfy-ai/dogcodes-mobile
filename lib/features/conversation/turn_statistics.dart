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
      '本轮耗时',
      '${number(end.difference(start).inMilliseconds / 1000, 1)} 秒',
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
  if (first != null) rows.add(('首个输出等待', '${number(first / 1000, 2)} 秒'));
  final usage = completions.map((c) => c['usage']).whereType<Map>().firstOrNull;
  if (usage == null) {
    rows.add(('消耗数据', 'Agent 未提供'));
    return rows;
  }
  if (valid(usage['outputTokensPerSecond'])) {
    rows.add(('生成速度', '${number(usage['outputTokensPerSecond'], 1)} Tokens/秒'));
  }
  final models = (usage['models'] as List? ?? []).whereType<String>().toSet();
  if (models.isNotEmpty) rows.add(('模型', models.join('、')));
  if (usage['scope'] == 'unknown') {
    rows.add(('消耗数据', '未记录'));
    return rows;
  }
  final requests = usage['scope'] == 'observed_requests';
  for (final (key, label, suffix, decimals) in [
    ('requestCount', '模型请求', ' 次', 0),
    ('inputTokens', requests ? '输入 Tokens（含缓存）' : '输入 Tokens', '', 0),
    ('outputTokens', requests ? '输出 Tokens（含推理）' : '输出 Tokens', '', 0),
    ('cacheReadTokens', '缓存读取 Tokens', '', 0),
    ('cacheWriteTokens', '缓存写入 Tokens', '', 0),
    ('reasoningTokens', '推理 Tokens', '', 0),
    ('costUsd', '原生费用（USD）', '', 6),
    ('credits', 'Credits', '', 4),
  ]) {
    final value = usage[key];
    if (valid(value)) rows.add((label, '${number(value, decimals)}$suffix'));
  }
  if (requests && valid(usage['inputTokens']) && valid(usage['outputTokens'])) {
    rows.add((
      '合计 Tokens',
      number(usage['inputTokens'] + usage['outputTokens']),
    ));
  }
  if (usage['partial'] == true || usage['completeness'] == 'partial') {
    rows.add((
      '统计范围',
      '部分数据${usage['incompleteReason'] == null ? '' : ' · ${usage['incompleteReason']}'}',
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
