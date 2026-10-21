import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import '../../core/host_hub.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'timeline_model.dart';
import 'turn_files.dart';

/// Renders a task timeline the way the desktop does: open Agent answers,
/// compact tool rows, and finished turns folded behind their answer.
class TimelineView extends StatelessWidget {
  const TimelineView({
    super.key,
    required this.items,
    this.activeTurnId,
    this.focusTurnId,
    this.focusKey,
  });
  final List<Item> items;
  final String? activeTurnId;
  final String? focusTurnId;
  final GlobalKey? focusKey;
  @override
  Widget build(BuildContext context) {
    final entries = buildEntries(
      items,
      activeTurnId: activeTurnId,
      agentName: (p) => agentLabel(p),
    );
    var focused = false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ...entries.map((e) {
          final target =
              !focused &&
              focusTurnId != null &&
              e is ItemEntry &&
              e.item['turnId'] == focusTurnId;
          if (target) focused = true;
          return Container(
            key: target ? focusKey : null,
            decoration: target
                ? BoxDecoration(
                    border: Border(
                      left: BorderSide(color: context.dc.accent, width: 2),
                    ),
                  )
                : null,
            child: EntryView(entry: e, activeTurnId: activeTurnId),
          );
        }),
      ],
    );
  }
}

class EntryView extends StatelessWidget {
  const EntryView({super.key, required this.entry, this.activeTurnId});
  final Entry entry;
  final String? activeTurnId;
  @override
  Widget build(BuildContext context) => switch (entry) {
    ItemEntry e => _ItemView(entry: e, activeTurnId: activeTurnId),
    LookupEntry e => _Expandable(
      icon: Icons.manage_search,
      label: '查阅',
      title: e.summary,
      child: Column(
        children: [
          for (final i in e.items)
            _ItemView(entry: ItemEntry(i), activeTurnId: activeTurnId),
        ],
      ),
    ),
    ProcessEntry e => _Expandable(
      icon: Icons.checklist,
      label: '过程',
      title: [
        '${e.steps} 个步骤',
        if (e.startedAt != null && e.completedAt != null)
          '用时 ${durationLabel(e.completedAt!.difference(e.startedAt!))}',
      ].join(' · '),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final c in e.entries)
            EntryView(entry: c, activeTurnId: activeTurnId),
        ],
      ),
    ),
  };
}

class _ItemView extends StatelessWidget {
  const _ItemView({required this.entry, this.activeTurnId});
  final ItemEntry entry;
  final String? activeTurnId;

  @override
  Widget build(BuildContext context) {
    final item = entry.item;
    final active = activeTurnId != null && item['turnId'] == activeTurnId;
    final body = _body(context, item, active);
    if (entry.agent == null) return body;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Row(
            children: [
              AgentGlyph(
                providerId: entry.item['providerId'] as String?,
                size: 18,
              ),
              const SizedBox(width: 6),
              Text(entry.agent!, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        body,
      ],
    );
  }

  Widget _body(BuildContext context, Item item, bool active) {
    final text = (item['text'] as String? ?? '').trimRight();
    final time = shortTime(
      DateTime.tryParse(item['occurredAt'] as String? ?? ''),
    );
    switch (item['kind']) {
      case 'user_message':
        return _UserBubble(
          text: text,
          time: time,
          attachments: item['attachments'],
        );
      case 'assistant_message':
        return AgentMarkdown(text);
      case 'activity':
        final a = activityOf(item);
        return a == null
            ? const SizedBox.shrink()
            : _ActivityView(a: a, active: active, children: entry.children);
      case 'turn_files':
        final meta = _json(text);
        return meta == null
            ? const SizedBox.shrink()
            : TurnFilesCard(key: ValueKey(meta['artifactId']), metadata: meta);
      case 'fork_context':
        return _ForkContext(text: text);
      case 'tool.started' || 'tool.completed' || 'tool.failed' || 'tool':
        return _Expandable(
          icon: Icons.build_outlined,
          label: '工具',
          title: text.split('\n').first,
          child: text.contains('\n') ? CodeBlock(text) : null,
        );
      case 'error':
        return _Notice(icon: Icons.error_outline, text: text, danger: true);
      // Core also records a user stop as turn.failed; like the desktop,
      // these stay neutral system lines.
      case 'turn.failed':
        return _Notice(icon: Icons.info_outline, text: text);
      case 'quota.exhausted':
        return _Notice(icon: Icons.hourglass_empty, text: text, danger: true);
      default:
        if (text.isEmpty) return const SizedBox.shrink();
        // Structured records the phone has no view for stay collapsed.
        if (text.startsWith('{') || text.startsWith('[')) {
          try {
            final data = jsonDecode(text);
            return _Expandable(
              icon: Icons.info_outline,
              label: '记录',
              title: '${item['kind']}',
              child: CodeBlock(printable(data)),
            );
          } catch (_) {}
        }
        return _Notice(icon: Icons.info_outline, text: text);
    }
  }
}

/// Agent answers are Markdown; code scrolls horizontally instead of shrinking.
class AgentMarkdown extends StatelessWidget {
  const AgentMarkdown(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = context.dc;
    final base = theme.textTheme.bodyLarge!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: MarkdownBody(
        data: text,
        selectable: true,
        softLineBreak: true,
        styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
          p: base,
          listBullet: base,
          h1: theme.textTheme.titleLarge,
          h2: theme.textTheme.titleLarge?.copyWith(fontSize: 17),
          h3: theme.textTheme.titleMedium,
          a: base.copyWith(color: c.accent),
          code: TextStyle(
            fontFamily: monoFamily,
            fontFamilyFallback: monoFallback,
            fontSize: 13.5,
            backgroundColor: c.surface,
          ),
          codeblockDecoration: BoxDecoration(
            color: c.code,
            borderRadius: BorderRadius.circular(8),
          ),
          codeblockPadding: const EdgeInsets.all(12),
          blockquoteDecoration: BoxDecoration(
            border: Border(left: BorderSide(color: c.line, width: 3)),
          ),
          blockquotePadding: const EdgeInsets.only(left: 12),
          horizontalRuleDecoration: BoxDecoration(
            border: Border(top: BorderSide(color: c.line)),
          ),
          tableBorder: TableBorder.all(color: c.line),
          tableHead: base.copyWith(fontWeight: FontWeight.w600),
          tableBody: base,
          blockSpacing: 10,
        ),
      ),
    );
  }
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.text, required this.time, this.attachments});
  final String text, time;
  final Object? attachments;
  @override
  Widget build(BuildContext context) {
    final count = attachments is List ? (attachments as List).length : 0;
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width * 0.8,
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: context.dc.surface,
                borderRadius: BorderRadius.circular(14),
              ),
              child: SelectableText(text),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              [
                if (count > 0) '$count 个附件',
                ?time.isEmpty ? null : time,
              ].join(' · '),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

IconData _categoryIcon(String category) => switch (category) {
  '修改' => Icons.edit_outlined,
  '读取' => Icons.description_outlined,
  '搜索' => Icons.search,
  '网页搜索' => Icons.travel_explore,
  '获取网页' => Icons.language,
  '终端' => Icons.terminal,
  '子智能体' => Icons.account_tree_outlined,
  _ => Icons.build_outlined,
};

class _ActivityView extends StatelessWidget {
  const _ActivityView({
    required this.a,
    required this.active,
    this.children = const [],
  });
  final Activity a;
  final bool active;
  final List<Item> children;

  @override
  Widget build(BuildContext context) {
    final running = isRunning(a, active);
    if (a.type == 'message') return AgentMarkdown(a.text ?? '');
    if (a.type == 'thought') {
      final seconds = a.durationMs != null
          ? (a.durationMs! / 1000).round()
          : running && a.startedAt != null
          ? DateTime.now().difference(a.startedAt!).inSeconds
          : null;
      final label = running
          ? '思考中'
          : a.status == 'interrupted'
          ? '思考已中断'
          : '思考';
      return _Line(
        icon: Icons.psychology_outlined,
        running: running,
        text: seconds == null
            ? '$label · 时间未记录'
            : '$label · ${running ? '约' : '持续了约'} $seconds 秒',
      );
    }
    final category = categoryOf(a);
    final status = statusLabel(a);
    if (isSubagent(a)) {
      return _Expandable(
        icon: _categoryIcon(category),
        label: category,
        title:
            a.title ??
            ((a.input is Map ? (a.input as Map)['description'] : null)
                as String?) ??
            a.name ??
            '委派任务',
        status: status,
        running: running,
        child: children.isEmpty
            ? Text('暂无子任务记录', style: Theme.of(context).textTheme.bodySmall)
            : TimelineView(items: children),
      );
    }
    if (category == '修改' && (a.changes.isNotEmpty || inputPath(a).isNotEmpty)) {
      final files = a.changes.isNotEmpty
          ? [
              for (final c in a.changes)
                (path: '${c['path'] ?? ''}', diff: c['diff'] as String?),
            ]
          : [
              (
                path: inputPath(a),
                diff:
                    a.input is Map &&
                        (a.input as Map)['old_string'] is String &&
                        (a.input as Map)['new_string'] is String
                    ? editPatch(
                        (a.input as Map)['old_string'] as String,
                        (a.input as Map)['new_string'] as String,
                      )
                    : null,
              ),
            ];
      return Column(
        children: [
          for (final f in files)
            _Expandable(
              icon: Icons.edit_outlined,
              label: '修改',
              title: f.path.split('/').last,
              status: status,
              running: running,
              child: f.diff == null || f.diff!.isEmpty
                  ? Text(f.path, style: Theme.of(context).textTheme.bodySmall)
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          f.path,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 6),
                        DiffBlock(f.diff!),
                      ],
                    ),
            ),
        ],
      );
    }
    final terminal = category == '终端';
    final Widget detail;
    if (terminal) {
      final command = terminalCommand(a.input);
      final preview = truncateOutput(terminalOutput(a.output));
      detail = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (a.partial) const _Muted('仅展示部分内容'),
          if (command.isNotEmpty) CodeBlock('\$ $command'),
          const SizedBox(height: 6),
          preview.text.isNotEmpty
              ? CodeBlock(preview.text)
              : const _Muted('暂无命令输出'),
          if (preview.truncated) const _Muted('… 输出过长，已截断'),
        ],
      );
    } else {
      final out = a.output == null ? '' : outputText(a.output);
      detail = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (a.partial) const _Muted('仅展示部分内容'),
          if (a.input != null) CodeBlock(_clip(printable(a.input))),
          const SizedBox(height: 6),
          out.isNotEmpty ? CodeBlock(_clip(out)) : const _Muted('暂无工具输出'),
        ],
      );
    }
    return _Expandable(
      icon: _categoryIcon(category),
      label: category,
      title: toolTitle(a),
      status: status,
      running: running,
      child: detail,
    );
  }

  static String _clip(String s) =>
      s.length > 4000 ? '${s.substring(0, 4000)}\n… 内容过长，已截断' : s;
}

/// Compact row that expands to show detail.
class _Expandable extends StatefulWidget {
  const _Expandable({
    required this.icon,
    required this.label,
    required this.title,
    this.status = '',
    this.running = false,
    this.child,
  });
  final IconData icon;
  final String label, title, status;
  final bool running;
  final Widget? child;
  @override
  State<_Expandable> createState() => _ExpandableState();
}

class _ExpandableState extends State<_Expandable> {
  bool open = false;
  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    final small = Theme.of(context).textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: widget.child == null
                ? null
                : () => setState(() => open = !open),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 36),
              child: Row(
                children: [
                  if (widget.running)
                    const SizedBox.square(
                      dimension: 14,
                      child: CircularProgressIndicator(strokeWidth: 1.5),
                    )
                  else
                    Icon(widget.icon, size: 16, color: c.secondary),
                  const SizedBox(width: 8),
                  Text(widget.label, style: small),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
                  if (widget.status.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Text(widget.status, style: small),
                  ],
                  if (widget.child != null)
                    Icon(
                      open ? Icons.expand_less : Icons.chevron_right,
                      size: 18,
                      color: c.secondary,
                    ),
                ],
              ),
            ),
          ),
          if (open && widget.child != null)
            Container(
              margin: const EdgeInsets.only(left: 7, bottom: 6),
              padding: const EdgeInsets.only(left: 14, top: 4),
              decoration: BoxDecoration(
                border: Border(left: BorderSide(color: c.line)),
              ),
              child: widget.child,
            ),
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.icon, required this.text, this.running = false});
  final IconData icon;
  final String text;
  final bool running;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      children: [
        if (running)
          const SizedBox.square(
            dimension: 14,
            child: CircularProgressIndicator(strokeWidth: 1.5),
          )
        else
          Icon(icon, size: 16, color: context.dc.secondary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text, style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
    ),
  );
}

Map<String, dynamic>? _json(String text) {
  try {
    final v = jsonDecode(text);
    return v is Map && v['artifactId'] is String
        ? Map<String, dynamic>.from(v)
        : null;
  } catch (_) {
    return null;
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text, this.danger = false});
  final IconData icon;
  final String text;
  final bool danger;
  @override
  Widget build(BuildContext context) {
    final color = danger ? context.dc.removed : context.dc.secondary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: TextStyle(fontSize: 13, color: color)),
          ),
        ],
      ),
    );
  }
}

class _Muted extends StatelessWidget {
  const _Muted(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Text(text, style: Theme.of(context).textTheme.bodySmall),
  );
}

class _ForkContext extends StatelessWidget {
  const _ForkContext({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    List<Map>? messages;
    try {
      final data = jsonDecode(text) as Map;
      messages = [
        for (final m in jsonDecode(data['text'] as String) as List)
          if (m is Map && ['turn.queued', 'message.delta'].contains(m['kind']))
            m,
      ];
    } catch (_) {}
    return _Expandable(
      icon: Icons.call_split,
      label: '分叉',
      title: '从历史轮次分叉 · 继承的上下文',
      child: messages == null
          ? const _Muted('分叉上下文暂不可显示')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final m in messages) ...[
                  _Muted(m['kind'] == 'turn.queued' ? '你' : 'Agent'),
                  AgentMarkdown('${m['text'] ?? ''}'),
                ],
              ],
            ),
    );
  }
}

/// Unified diff with added/removed lines tinted; scrolls horizontally.
class DiffBlock extends StatelessWidget {
  const DiffBlock(this.diff, {super.key});
  final String diff;
  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    final lines = diff.split('\n').take(400).toList();
    return Container(
      decoration: BoxDecoration(
        color: c.code,
        borderRadius: BorderRadius.circular(8),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final l in lines)
              Container(
                color: l.startsWith('+') && !l.startsWith('+++')
                    ? c.added.withValues(alpha: 0.12)
                    : l.startsWith('-') && !l.startsWith('---')
                    ? c.removed.withValues(alpha: 0.12)
                    : null,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  l,
                  style: TextStyle(
                    fontFamily: monoFamily,
                    fontFamilyFallback: monoFallback,
                    fontSize: 12.5,
                    height: 1.45,
                    color: l.startsWith('@@') ? c.secondary : c.text,
                  ),
                ),
              ),
            if (diff.split('\n').length > 400)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Text('… 差异过长，已截断'),
              ),
          ],
        ),
      ),
    );
  }
}
