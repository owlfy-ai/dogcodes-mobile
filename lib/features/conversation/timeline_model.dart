import 'dart:convert';

/// Presentation of PC timeline items, ported from the desktop
/// (ConversationActivity.tsx / terminalPresentation.ts) so both clients show
/// the same conversation: activity JSON is decoded, read-only tool calls are
/// grouped, and finished turns collapse their process behind the answer.

typedef Item = Map<String, dynamic>;

/// Decoded `activity` row: an Agent message, thought, tool call or subagent.
class Activity {
  Activity(this.data);
  final Map<String, dynamic> data;
  String get type => data['type'] as String? ?? '';
  String? get name => data['name'] as String?;
  String? get title => data['title'] as String?;
  String? get status => data['status'] as String?;
  String? get text => data['text'] as String?;
  String? get category => data['category'] as String?;
  Object? get input => data['input'];
  Object? get output => data['output'] ?? data['content'];
  bool get partial => data['partial'] == true;
  num? get durationMs => data['durationMs'] as num?;
  DateTime? get startedAt =>
      DateTime.tryParse(data['startedAt'] as String? ?? '');
  String? get parentId => data['parentId'] as String?;
  String? get sessionId => data['sessionId'] as String?;
  String? get childSessionId =>
      (data['childSessionId'] ?? data['childId']) as String?;
  List<Map<String, dynamic>> get changes => [
    for (final c in (data['changes'] as List? ?? const []))
      if (c is Map) Map<String, dynamic>.from(c),
  ];

  /// A progress notification without any display field is not a row.
  bool get empty =>
      type == 'tool' &&
      name == null &&
      title == null &&
      status == null &&
      input == null &&
      output == null &&
      (text ?? '').isEmpty &&
      changes.isEmpty;
}

Activity? activityOf(Item item) {
  if (item['kind'] != 'activity') return null;
  try {
    final data = jsonDecode(item['text'] as String? ?? '');
    return data is Map && data['type'] is String
        ? Activity(Map<String, dynamic>.from(data))
        : null;
  } catch (_) {
    return null;
  }
}

bool isSubagent(Activity a) =>
    a.type == 'subagent' ||
    RegExp(r'^(agent|task)$', caseSensitive: false).hasMatch(a.name ?? '') ||
    (a.name ?? '').startsWith('Task:');

String categoryOf(Activity a) {
  if (isSubagent(a)) return '子智能体';
  final name = (a.name ?? '').toLowerCase();
  if (['edit', 'delete', 'move'].contains(a.category) ||
      RegExp(
        r'^(edit|write|multiedit|apply_patch|filechange|file_change|replace_in_file|write_file|write_to_file|replace_file_content)$',
      ).hasMatch(name)) {
    return '修改';
  }
  if (RegExp(r'^(websearch|web_search|search_web)$').hasMatch(name)) {
    return '网页搜索';
  }
  if (a.category == 'read' ||
      RegExp(r'^(read|read_file|view_file|readfile)$').hasMatch(name)) {
    return '读取';
  }
  if (a.category == 'search' ||
      RegExp(
        r'^(grep|glob|find_by_name|grep_search|search_files)$',
      ).hasMatch(name)) {
    return '搜索';
  }
  if (a.category == 'execute' ||
      RegExp(
        r'^(bash|terminal|commandexecution|command_execution|run_command|shell|exec_command)$',
      ).hasMatch(name)) {
    return '终端';
  }
  if (a.category == 'fetch' ||
      RegExp(r'^(webfetch|web_fetch|read_url_content)$').hasMatch(name)) {
    return '获取网页';
  }
  return '工具';
}

const _states = {
  'pending': '等待中',
  'running': '进行中',
  'started': '进行中',
  'in_progress': '进行中',
  'completed': '完成',
  'succeeded': '完成',
  // Tool failures are routine agent recovery steps, not user-facing alerts.
  'failed': '',
  'interrupted': '已中断',
  'cancelled': '已取消',
  'unknown': '状态未确认',
};
String statusLabel(Activity a) => _states[a.status ?? ''] ?? '状态未确认';

bool isRunning(Activity a, bool active) =>
    active && ['running', 'started', 'in_progress'].contains(a.status);

String printable(Object? v) => v is String
    ? v
    : v == null
    ? ''
    : const JsonEncoder.withIndent('  ').convert(v);

String outputText(Object? value) {
  if (value is List) return value.map(outputText).join('\n');
  if (value is Map) {
    if (value['text'] is String) return value['text'] as String;
    if (value['content'] != null) return outputText(value['content']);
  }
  return printable(value);
}

String inputPath(Activity a) {
  final i = a.input;
  if (i is! Map) return '';
  final v =
      i['file_path'] ?? i['path'] ?? i['target_file'] ?? i['AbsolutePath'];
  return v == null ? '' : '$v';
}

String terminalCommand(Object? value) {
  if (value is String) return value;
  if (value is! Map) return '';
  for (final key in const [
    'command',
    'cmd',
    'command_line',
    'commandLine',
    'CommandLine',
    'argv',
  ]) {
    final command = value[key];
    if (command is String) return command;
    if (command is List && command.every((a) => a is String)) {
      return command
          .map(
            (a) => RegExp(r'^[\w./:=@%-]+$').hasMatch(a as String)
                ? a
                : "'${a.replaceAll("'", "'\\''")}'",
          )
          .join(' ');
    }
  }
  return '';
}

String terminalOutput(Object? value) {
  if (value is String) return value;
  if (value is List) {
    return value.map(terminalOutput).where((s) => s.isNotEmpty).join('\n');
  }
  if (value is! Map) return '';
  if (value['stdout'] != null || value['stderr'] != null) {
    return [
      value['stdout'],
      value['stderr'],
    ].map(terminalOutput).where((s) => s.isNotEmpty).join('\n');
  }
  for (final key in const [
    'text',
    'content',
    'output',
    'aggregated_output',
    'aggregatedOutput',
    'result',
  ]) {
    if (value[key] != null) return terminalOutput(value[key]);
  }
  return '';
}

({String text, bool truncated}) truncateOutput(String text) {
  final preview = text.split('\n').take(12).join('\n');
  final clipped = preview.length > 3000 ? preview.substring(0, 3000) : preview;
  return (text: clipped, truncated: clipped.length < text.length);
}

/// Title shown on a tool row: command, path, pattern or tool name.
String toolTitle(Activity a) {
  if (categoryOf(a) == '终端') {
    final command = terminalCommand(a.input);
    if (command.isNotEmpty) return command;
  }
  final path = inputPath(a);
  if (path.isNotEmpty) return path;
  final input = a.input;
  if (input is String && input.isNotEmpty) return input;
  if (input is Map) {
    final v =
        input['command'] ?? input['pattern'] ?? input['query'] ?? input['url'];
    if (v is String && v.isNotEmpty) return v;
  }
  return a.title ?? a.name ?? '工具';
}

String _nativeId(Item i) => (i['itemId'] as String? ?? '').replaceFirst(
  'tool:${i['taskId']}:${i['turnId']}:',
  '',
);

/// Whether [item] is a step of the subagent [parent].
bool belongsTo(Item item, Item parent) {
  final a = activityOf(item), p = activityOf(parent);
  if (a == null || p == null) return false;
  if (item['turnId'] != parent['turnId'] ||
      item['itemId'] == parent['itemId']) {
    return false;
  }
  return ((a.parentId ?? '').isNotEmpty && a.parentId == _nativeId(parent)) ||
      ((a.sessionId ?? '').isNotEmpty && a.sessionId == p.childSessionId);
}

bool _readOnly(Item i) {
  final a = activityOf(i);
  return a != null &&
      a.data['artifact'] == null &&
      a.type == 'tool' &&
      ['completed', 'succeeded'].contains(a.status) &&
      ['读取', '搜索', '网页搜索', '获取网页'].contains(categoryOf(a));
}

bool _isAnswer(Item i) {
  if (i['kind'] == 'assistant_message') {
    return (i['text'] as String? ?? '').trim().isNotEmpty;
  }
  final a = activityOf(i);
  return a?.type == 'message' && (a?.text ?? '').trim().isNotEmpty;
}

/// One rendered block: a single item, a group of read-only lookups, or the
/// collapsed process of a finished turn.
sealed class Entry {}

class ItemEntry extends Entry {
  ItemEntry(this.item, {this.children = const [], this.agent});
  final Item item;

  /// Steps of a subagent row.
  final List<Item> children;

  /// Agent label shown above the first response of a turn.
  final String? agent;
}

class LookupEntry extends Entry {
  LookupEntry(this.items);
  final List<Item> items;
  String get summary {
    final counts = <String, int>{};
    for (final i in items) {
      final c = categoryOf(activityOf(i)!);
      counts[c] = (counts[c] ?? 0) + 1;
    }
    return counts.entries.map((e) => '${e.key} ${e.value} 次').join(' · ');
  }
}

class ProcessEntry extends Entry {
  ProcessEntry(this.entries, {this.startedAt, this.completedAt});
  final List<Entry> entries;
  final DateTime? startedAt, completedAt;
  int get steps => entries.length;
}

/// Kinds the desktop does not show in the conversation.
const _hiddenKinds = {'review_result', 'handoff', 'reconciliation'};

List<Entry> buildEntries(
  List<Item> items, {
  String? activeTurnId,
  String Function(String? providerId)? agentName,
}) {
  final parents = [
    for (final i in items)
      if (activityOf(i) case final a? when isSubagent(a)) i,
  ];
  final visible = items.where((i) {
    if (_hiddenKinds.contains(i['kind'])) return false;
    final a = activityOf(i);
    if (i['kind'] == 'activity' && a == null) return false;
    if (a != null && (a.type == 'status' || a.empty)) return false;
    final emptyMessage = i['kind'] == 'assistant_message'
        ? (i['text'] as String? ?? '').trim().isEmpty
        : a?.type == 'message' && (a?.text ?? '').trim().isEmpty;
    return !emptyMessage && !parents.any((p) => belongsTo(i, p));
  }).toList();

  // First response per turn carries the Agent label.
  final firstResponse = <String, String>{};
  for (final i in visible) {
    final turn = i['turnId'] as String?;
    if (turn == null || i['kind'] == 'user_message') continue;
    if (i['kind'] == 'turn_files') continue;
    firstResponse.putIfAbsent(turn, () => i['itemId'] as String);
  }

  Entry single(Item i) => ItemEntry(
    i,
    children: [
      if (activityOf(i) case final a? when isSubagent(a))
        for (final c in items)
          if (belongsTo(c, i)) c,
    ],
    agent: firstResponse[i['turnId']] == i['itemId'] && agentName != null
        ? agentName(i['providerId'] as String?)
        : null,
  );

  // Consecutive completed read-only lookups in one turn become one group.
  final groups = <List<Item>>[];
  for (final i in visible) {
    final last = groups.isEmpty ? null : groups.last;
    if (last != null &&
        _readOnly(i) &&
        _readOnly(last.first) &&
        last.first['turnId'] == i['turnId']) {
      last.add(i);
    } else {
      groups.add([i]);
    }
  }
  Entry entry(List<Item> g) => g.length == 1 ? single(g.first) : LookupEntry(g);

  final completions = <String, Map>{};
  for (final i in visible) {
    final c = i['turnCompletion'];
    if (i['turnId'] != null && c is Map) completions[i['turnId'] as String] = c;
  }
  final byTurn = <String, List<List<Item>>>{};
  for (final g in groups) {
    final t = g.first['turnId'] as String?;
    if (t != null) byTurn.putIfAbsent(t, () => []).add(g);
  }

  final out = <Entry>[];
  final done = <String>{};
  for (final g in groups) {
    final turn = g.first['turnId'] as String?;
    final completion = turn == null ? null : completions[turn];
    if (turn == null || completion == null || turn == activeTurnId) {
      out.add(entry(g));
      continue;
    }
    if (!done.add(turn)) continue;
    final turnGroups = byTurn[turn]!;
    var finalIndex = -1;
    for (var k = turnGroups.length - 1; k >= 0; k--) {
      if (turnGroups[k].any(_isAnswer)) {
        finalIndex = k;
        break;
      }
    }
    bool userOrFiles(List<Item> e) =>
        e.first['kind'] == 'user_message' || e.first['kind'] == 'turn_files';
    final process = turnGroups
        .take(finalIndex < 0 ? 0 : finalIndex)
        .where((e) => !userOrFiles(e))
        .toList();
    if (process.isEmpty) {
      out.addAll(turnGroups.map(entry));
      continue;
    }
    out.addAll(
      turnGroups.where((e) => e.first['kind'] == 'user_message').map(entry),
    );
    out.add(
      ProcessEntry(
        process.map(entry).toList(),
        startedAt: DateTime.tryParse('${completion['startedAt']}'),
        completedAt: DateTime.tryParse('${completion['completedAt']}'),
      ),
    );
    out.addAll(
      turnGroups.skip(finalIndex).where((e) => !userOrFiles(e)).map(entry),
    );
    out.addAll(
      turnGroups.where((e) => e.first['kind'] == 'turn_files').map(entry),
    );
  }
  return out;
}

/// Unified-diff lines for an edit given as old/new strings.
String editPatch(String oldText, String newText) => [
  for (final l in oldText.split('\n')) '-$l',
  for (final l in newText.split('\n')) '+$l',
].join('\n');

String durationLabel(Duration d) {
  final s = d.inSeconds;
  if (s < 60) return '$s 秒';
  final m = d.inMinutes;
  if (m < 60) return '$m 分 ${s % 60} 秒';
  return '${d.inHours} 小时 ${m % 60} 分';
}
