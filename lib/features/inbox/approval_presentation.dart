import 'dart:convert';
import 'package:dogcodes_app/l10n/strings.dart';

/// One labelled part of an approval request; long parts start collapsed.
typedef ApprovalSection = ({String label, String text, bool expandable});

/// What the phone shows for a permission request. Mirrors the desktop's
/// approvalPresentation so both ask the same question about the same content.
typedef ApprovalPresentation = ({
  String category,
  String question,
  List<ApprovalSection> sections,
  String? warning,
});

Map<String, dynamic>? _object(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : null;

String _text(Object? value) => value is String ? value : '';

String _first(Map<String, dynamic> value, List<String> keys) => keys
    .map((k) => _text(value[k]))
    .firstWhere((t) => t.isNotEmpty, orElse: () => '');

String _quoteArgument(String value) =>
    RegExp(r'^[a-zA-Z0-9_./:=@%-]+$').hasMatch(value)
    ? value
    : "'${value.replaceAll("'", r"'\''")}'";

String _commandText(Object? value) {
  if (value is String) return value;
  if (value is List && value.every((v) => v is String)) {
    return value.cast<String>().map(_quoteArgument).join(' ');
  }
  return '';
}

/// Convert a native approval input to reviewable content; protocol envelopes
/// never reach the screen.
ApprovalPresentation approvalPresentation(
  String summary, [
  String toolName = '',
]) {
  Object? parsed = summary;
  var malformedEnvelope = false;
  try {
    parsed = jsonDecode(summary);
  } catch (_) {
    // Do not expose truncated protocol objects; shell expressions remain
    // plain text.
    malformedEnvelope = RegExp(r'^\s*(?:\{\s*"|\[\s*[{"])').hasMatch(summary);
  }
  final truncated = _object(parsed)?['detailsTruncated'] == true;
  var input = _object(parsed);
  for (var depth = 0; input != null && depth < 4; depth++) {
    final nested =
        _object(input['rawInput']) ??
        _object(input['raw_input']) ??
        _object(input['input']) ??
        _object(input['arguments']) ??
        _object(input['args']);
    if (nested == null) break;
    input = {
      ...input,
      ...nested,
      for (final k in ['rawInput', 'raw_input', 'input', 'arguments', 'args'])
        if (!nested.containsKey(k)) k: null,
    };
  }
  final value = input ?? const <String, dynamic>{};
  final command =
      ['command', 'cmd', 'command_line', 'commandLine', 'argv', 'CommandLine']
          .map((k) => _commandText(value[k]))
          .firstWhere((c) => c.isNotEmpty, orElse: () => '');
  final path = _first(value, [
    'file_path',
    'filePath',
    'path',
    'target_file',
    'targetFile',
    'TargetFile',
    'AbsolutePath',
  ]);
  final url = _first(value, ['url', 'uri', 'website']);
  bool tool(String pattern) =>
      RegExp(pattern, caseSensitive: false).hasMatch(toolName);
  final fileLike =
      path.isNotEmpty ||
      value['files'] != null ||
      tool(r'read|edit|write|patch|filechange|修改|写入|文件');
  final terminal =
      command.isNotEmpty ||
      tool(r'command|shell|bash|terminal|终端|命令') ||
      (input == null && !fileLike && url.isEmpty);
  final reading = tool(r'read|读取');
  final category = terminal
      ? tr("终端")
      : fileLike
      ? (reading ? tr("读取文件") : tr("修改文件"))
      : url.isNotEmpty
      ? tr("网络访问")
      : tool(r'search|grep|glob|搜索')
      ? tr("搜索")
      : tr("操作确认");
  final question = terminal
      ? tr("是否允许运行以下命令？")
      : fileLike
      ? (reading ? tr("是否允许读取以下文件？") : tr("是否允许修改以下文件？"))
      : url.isNotEmpty
      ? tr("是否允许访问以下地址？")
      : tr("是否允许执行以下操作？");

  final sections = <ApprovalSection>[];
  void add(String label, String content, [bool expandable = false]) {
    if (content.trim().isNotEmpty) {
      sections.add((label: label, text: content, expandable: expandable));
    }
  }

  add(tr("命令"), command);
  add(tr("操作内容"), _text(value['detailText']), true);
  add(tr("文件路径"), path);
  add(tr("地址"), url);
  add(tr("授权目录"), _text(value['grantRoot']));
  void fileSection(Object? file, [String fallbackPath = '']) {
    if (file is String) return add(tr("文件路径"), file);
    final entry = _object(file);
    if (entry == null) return;
    final kind = entry['kind'] is String
        ? entry['kind'] as String
        : _text(_object(entry['kind'])?['type']);
    final label = kind == 'delete'
        ? tr("删除文件")
        : kind == 'add'
        ? tr("新建文件")
        : tr("文件路径");
    final entryPath = _first(entry, ['path', 'file_path', 'filePath']);
    add(label, entryPath.isEmpty ? fallbackPath : entryPath);
    add(
      tr("移动到"),
      _first(_object(entry['kind']) ?? entry, ['movePath', 'move_path']),
    );
    add(tr("修改内容"), _first(entry, ['diff', 'patch', 'content']), true);
  }

  final files = value['files'];
  if (files is List) {
    files.forEach(fileSection);
  } else if (files is Map) {
    files.forEach((name, file) => fileSection(file, '$name'));
  }
  final chunks = value['ReplacementChunks'];
  if (chunks is List) {
    for (final chunk in chunks) {
      final entry = _object(chunk);
      if (entry == null) continue;
      add(tr("替换前"), _text(entry['TargetContent']), true);
      add(tr("替换后"), _text(entry['ReplacementContent']), true);
    }
  }
  add(tr("修改内容"), _first(value, ['diff', 'patch', 'unified_diff']), true);
  add(tr("替换前"), _first(value, ['old_string', 'old_str', 'oldText']), true);
  add(tr("替换后"), _first(value, ['new_string', 'new_str', 'newText']), true);
  if (fileLike) {
    add(tr("文件内容"), _first(value, ['content', 'CodeContent']), true);
  }
  add(tr("搜索内容"), _first(value, ['query', 'pattern', 'glob']));
  if (input == null && parsed is String && !malformedEnvelope) {
    add(terminal ? tr("命令") : tr("操作内容"), parsed);
  }
  // The agent's own words are data, not app messages.
  final reason = _first(value, ['justification', 'reason', 'description']);
  String? warning;
  if (malformedEnvelope) {
    warning = tr("审批详情格式不完整，请让 Agent 重新发起审批。");
  } else if (truncated) {
    warning = tr("操作详情过长，下方仅展示部分内容。请让 Agent 拆分操作后重新发起审批，以查看完整范围。");
  } else if (value['scope'] == 'unknown') {
    warning = tr("Agent 未提供文件修改范围，请让 Agent 补充文件路径和修改内容。");
  } else if (sections.isEmpty) {
    warning = tr("未能从审批请求中读取文件路径、命令或修改内容，请让 Agent 补充详情后重新发起审批。");
  }
  if (sections.isEmpty && toolName.isNotEmpty) add(tr("请求的工具"), toolName);
  return (
    category: category,
    question: reason.isNotEmpty ? reason : question,
    sections: sections,
    warning: warning,
  );
}
