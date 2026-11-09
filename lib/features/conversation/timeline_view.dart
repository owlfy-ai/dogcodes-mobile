import 'package:dogcodes_app/l10n/strings.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import '../../core/host_hub.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'timeline_model.dart';
import 'turn_files.dart';
import 'turn_actions.dart';
import 'attachment_preview.dart';
import 'conversation_page.dart';

/// Renders a task timeline the way the desktop does: open Agent answers,
/// compact tool rows, and finished turns folded behind their answer.
class TimelineView extends StatelessWidget {
  const TimelineView({
    super.key,
    required this.items,
    this.activeTurnId,
    this.focusTurnId,
    this.focusKey,
    this.session,
  });
  final List<Item> items;
  final String? activeTurnId;
  final String? focusTurnId;
  final GlobalKey? focusKey;
  final SessionRef? session;
  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: timelineEntries(
        context,
        items: items,
        activeTurnId: activeTurnId,
        focusTurnId: focusTurnId,
        focusKey: focusKey,
        session: session,
      ).widgets,
    );
  }
}

/// One widget per timeline entry, keyed by the entry's identity so expanded
/// state survives streamed updates. A lazy list builds only the visible ones;
/// `focusIndex` is the entry of [focusTurnId], for scrolling to it.
({List<Widget> widgets, int? focusIndex}) timelineEntries(
  BuildContext context, {
  required List<Item> items,
  String? activeTurnId,
  String? focusTurnId,
  GlobalKey? focusKey,
  SessionRef? session,
}) {
  final entries = buildEntries(
    items,
    activeTurnId: activeTurnId,
    agentName: (p) => agentLabel(p),
  );
  final seen = <String>{};
  int? focusIndex;
  final widgets = <Widget>[];
  for (final e in entries) {
    final target =
        focusIndex == null &&
        focusTurnId != null &&
        e is ItemEntry &&
        e.item['turnId'] == focusTurnId;
    if (target) focusIndex = widgets.length;
    var key = _entryKey(e);
    if (!seen.add(key)) key = '$key#${widgets.length}';
    widgets.add(
      KeyedSubtree(
        key: ValueKey(key),
        child: Container(
          key: target ? focusKey : null,
          decoration: target
              ? BoxDecoration(
                  border: Border(
                    left: BorderSide(color: context.dc.accent, width: 2),
                  ),
                )
              : null,
          child: EntryView(
            entry: e,
            activeTurnId: activeTurnId,
            session: session,
          ),
        ),
      ),
    );
  }
  return (widgets: widgets, focusIndex: focusIndex);
}

String _entryKey(Entry e) => switch (e) {
  ItemEntry(:final item) => 'item:${item['itemId']}',
  LookupEntry(:final items) => 'lookup:${items.first['itemId']}',
  ProcessEntry(:final entries) =>
    'process:${entries.isEmpty ? '' : _entryKey(entries.first)}',
  TurnActionsEntry(:final turnId) => 'actions:$turnId',
};

class EntryView extends StatelessWidget {
  const EntryView({
    super.key,
    required this.entry,
    this.activeTurnId,
    this.session,
  });
  final Entry entry;
  final String? activeTurnId;
  final SessionRef? session;
  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    return switch (entry) {
      TurnActionsEntry e => TurnActions(entry: e, session: session),
      ItemEntry e => _ItemView(
        entry: e,
        activeTurnId: activeTurnId,
        session: session,
      ),
      LookupEntry e => _Expandable(
        icon: Icons.manage_search,
        label: tr("查阅"),
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
        label: tr("过程"),
        title: [
          tr("{0} 个步骤", [e.steps]),
          if (e.startedAt != null && e.completedAt != null)
            tr("用时 {0}", [
              durationLabel(e.completedAt!.difference(e.startedAt!)),
            ]),
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
}

/// The PC shortened this item to keep the page under the transfer limit.
class _FullItemButton extends StatefulWidget {
  const _FullItemButton({required this.item});
  final Item item;
  @override
  State<_FullItemButton> createState() => _FullItemButtonState();
}

class _FullItemButtonState extends State<_FullItemButton> {
  bool busy = false;
  String? error;
  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final load = TurnScope.of(context)?.loadFullItem;
    final id = widget.item['itemId'];
    final bytes = widget.item['fullBytes'];
    final size = bytes is num ? '（${(bytes / 1024).ceil()} KB）' : '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextButton.icon(
          icon: busy
              ? const SizedBox.square(
                  dimension: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.unfold_more, size: 18),
          label: Text(tr("内容较长已截断，显示完整内容{0}", [size])),
          onPressed: busy || load == null || id is! String
              ? null
              : () async {
                  setState(() {
                    busy = true;
                    error = null;
                  });
                  try {
                    await load(id);
                  } catch (e) {
                    if (mounted) setState(() => error = '$e');
                  } finally {
                    if (mounted) setState(() => busy = false);
                  }
                },
        ),
        if (error != null) InlineNotice(error!, danger: true),
      ],
    );
  }
}

class _ItemView extends StatelessWidget {
  const _ItemView({required this.entry, this.activeTurnId, this.session});
  final ItemEntry entry;
  final String? activeTurnId;
  final SessionRef? session;

  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final item = entry.item;
    final active = activeTurnId != null && item['turnId'] == activeTurnId;
    final content = _body(context, item, active);
    final body = item['truncated'] == true
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              content,
              _FullItemButton(item: item),
            ],
          )
        : content;
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
        return ForkOrigin(text: text, session: session);
      case 'tool.started' || 'tool.completed' || 'tool.failed' || 'tool':
        return _Expandable(
          icon: Icons.build_outlined,
          label: tr("工具"),
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
              label: tr("记录"),
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
    watchAppLanguage(context);
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
    watchAppLanguage(context);
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
                if (count > 0) tr("{0} 个附件", [count]),
                ?time.isEmpty ? null : time,
              ].join(' · '),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          if (attachments is List && (attachments as List).isNotEmpty)
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final a in attachments as List)
                  if (a is Map) AttachmentButton(attachment: a),
              ],
            ),
        ],
      ),
    );
  }
}

IconData _categoryIcon(String category) => switch (category) {
  '修改' || 'Edit' => Icons.edit_outlined,
  '读取' || 'Read' => Icons.description_outlined,
  '搜索' || 'Search' => Icons.search,
  '网页搜索' || 'Web search' => Icons.travel_explore,
  '获取网页' || 'Fetch webpage' => Icons.language,
  '终端' || 'Terminal' => Icons.terminal,
  '子智能体' || 'Subagent' => Icons.account_tree_outlined,
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
    watchAppLanguage(context);
    final running = isRunning(a, active);
    if (a.type == 'message') return AgentMarkdown(a.text ?? '');
    if (a.type == 'thought') {
      final seconds = a.durationMs != null
          ? (a.durationMs! / 1000).round()
          : running && a.startedAt != null
          ? DateTime.now().difference(a.startedAt!).inSeconds
          : null;
      final label = running
          ? tr("思考中")
          : a.status == 'interrupted'
          ? tr("思考已中断")
          : tr("思考");
      return _Line(
        icon: Icons.psychology_outlined,
        running: running,
        text: seconds == null
            ? tr("{0} · 时间未记录", [label])
            : tr("{0} · {1} {2} 秒", [
                label,
                running ? tr("约") : tr("持续了约"),
                seconds,
              ]),
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
            tr("委派任务"),
        status: status,
        running: running,
        // Only its result: the subagent's own steps stay on the PC.
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (subagentResult(a) case final result?)
              AgentMarkdown(result)
            else
              _Muted(tr("暂无子任务结论")),
            _Muted(
              children.isEmpty
                  ? tr("执行过程请在电脑上查看")
                  : tr("共 {0} 步，执行过程请在电脑上查看", [children.length]),
            ),
          ],
        ),
      );
    }
    if (category == tr("修改") &&
        (a.changes.isNotEmpty || inputPath(a).isNotEmpty)) {
      final files = a.changes.isNotEmpty
          ? [for (final c in a.changes) '${c['path'] ?? ''}']
          : [inputPath(a)];
      return Column(
        children: [
          for (final f in files)
            _Expandable(
              icon: Icons.edit_outlined,
              label: tr("修改"),
              title: f.split('/').last,
              status: status,
              running: running,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(f, style: Theme.of(context).textTheme.bodySmall),
                  _Muted(tr("改动内容见本轮文件变更，或在电脑上查看")),
                ],
              ),
            ),
        ],
      );
    }
    // What was run and, for a failed step, why it stopped; outputs stay on
    // the PC (it no longer sends them to the phone).
    final command = category == tr("终端") ? terminalCommand(a.input) : '';
    final failure = failurePreview(a);
    final detail = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (command.isNotEmpty)
          CodeBlock('\$ $command')
        else if (a.input != null)
          CodeBlock(_clip(printable(a.input))),
        if (failure != null) ...[const SizedBox(height: 6), CodeBlock(failure)],
        _Muted(tr("完整输出请在电脑上查看")),
      ],
    );
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
      s.length > 4000 ? tr("{0}\n… 内容过长，已截断", [s.substring(0, 4000)]) : s;
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
    watchAppLanguage(context);
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
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    return Padding(
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
    watchAppLanguage(context);
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
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text(text, style: Theme.of(context).textTheme.bodySmall),
    );
  }
}

/// Opens a forked session: where it came from, what it inherited, and that
/// it can carry on from here.
class ForkOrigin extends StatefulWidget {
  const ForkOrigin({super.key, required this.text, this.session});
  final String text;
  final SessionRef? session;
  @override
  State<ForkOrigin> createState() => _ForkOriginState();
}

class _ForkOriginState extends State<ForkOrigin> {
  bool open = false;

  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final c = context.dc;
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    Map? data;
    List<Map>? messages;
    try {
      data = jsonDecode(widget.text) as Map;
      messages = [
        for (final m in jsonDecode(data['text'] as String) as List)
          if (m is Map && ['turn.queued', 'message.delta'].contains(m['kind']))
            m,
      ];
    } catch (_) {}
    if (data == null || messages == null) {
      return _Muted(tr("分叉上下文暂不可显示"));
    }
    final session = widget.session;
    final sourceId = data['sourceTaskId'] as String?;
    String? sourceTitle;
    for (final t in session?.host.tasks ?? const <Map<String, dynamic>>[]) {
      if (t['taskId'] == sourceId) sourceTitle = t['title'] as String?;
    }
    final note = data['environment'] == 'worktree'
        ? data['restoredTurnSnapshot'] == true
              ? tr("已恢复所选轮次结束时的文件，未提交的成果可在“变更”中查看。")
              : data['contextOnly'] == true
              ? tr("此项目不是 Git 仓库，分叉只继承对话上下文，并沿用同一项目目录。")
              : tr("此会话由旧版分叉创建，未恢复历史轮次的文件。")
        : tr("沿用同一项目目录；分叉不会还原文件。");
    final turns = messages.where((m) => m['kind'] == 'turn.queued').length;
    // Nothing has happened in the fork yet.
    final alone =
        session != null &&
        session.task['lastTurnExecutor'] == null &&
        !session.running;
    final openSource =
        session != null && sourceId != null && sourceTitle != null
        ? () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) =>
                  ConversationPage(hostId: session.host.id, taskId: sourceId),
            ),
          )
        : null;
    return Container(
      margin: const EdgeInsets.only(top: 4, bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.line),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: c.accent.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(Icons.call_split, size: 18, color: c.accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (sourceTitle == null)
                      Text(
                        tr("分叉自较早的会话"),
                        style: theme.textTheme.titleSmall,
                      )
                    else
                      InkWell(
                        key: const ValueKey('fork-source'),
                        onTap: openSource,
                        borderRadius: BorderRadius.circular(4),
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(text: '${tr("分叉自")} '),
                              TextSpan(
                                text: sourceTitle,
                                style: TextStyle(
                                  decoration: TextDecoration.underline,
                                  decorationColor: c.secondary,
                                ),
                              ),
                            ],
                          ),
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                    const SizedBox(height: 3),
                    Text(note, style: small),
                  ],
                ),
              ),
            ],
          ),
          if (messages.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 44, top: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('fork-context-toggle'),
                  style: TextButton.styleFrom(
                    foregroundColor: c.secondary,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () => setState(() => open = !open),
                  icon: Icon(
                    open ? Icons.expand_more : Icons.chevron_right,
                    size: 18,
                  ),
                  label: Text(
                    open
                        ? tr("收起继承的上下文")
                        : tr("查看继承的上下文（{0} 轮）", [turns]),
                  ),
                ),
              ),
            ),
          if (open)
            Container(
              margin: const EdgeInsets.only(left: 44, top: 4),
              padding: const EdgeInsets.only(left: 12),
              decoration: BoxDecoration(
                border: Border(left: BorderSide(color: c.line, width: 2)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final m in messages) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        m['kind'] == 'turn.queued' ? tr("你") : 'Agent',
                        style: small?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: m['kind'] == 'turn.queued' ? c.accent : null,
                        ),
                      ),
                    ),
                    AgentMarkdown('${m['text'] ?? ''}'),
                  ],
                ],
              ),
            ),
          if (alone)
            Padding(
              padding: const EdgeInsets.only(left: 44, top: 10),
              child: Text(
                tr("Agent 已获得以上上下文，在下方发送消息即可从这里继续。"),
                style: small,
              ),
            ),
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
    watchAppLanguage(context);
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
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Text(tr("… 差异过长，已截断")),
              ),
          ],
        ),
      ),
    );
  }
}
