import 'package:flutter/material.dart';
import 'theme.dart';

/// Large title for root tabs (会话 / 工作区 / 待处理 / 电脑).
class RootHeader extends StatelessWidget {
  const RootHeader({super.key, required this.title, this.actions = const []});
  final String title;
  final List<Widget> actions;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(DcSpace.page, 12, 14, 8),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: Theme.of(context).textTheme.headlineSmall,
            semanticsLabel: title,
          ),
        ),
        ...actions,
      ],
    ),
  );
}

/// Pushed detail pages use a back button with a title and optional subtitle.
class DetailBar extends StatelessWidget implements PreferredSizeWidget {
  const DetailBar({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const [],
  });
  final String title;
  final String? subtitle;
  final List<Widget> actions;
  @override
  Size get preferredSize => const Size.fromHeight(60);
  @override
  Widget build(BuildContext context) => AppBar(
    toolbarHeight: 60,
    leading: Navigator.of(context).canPop()
        ? IconButton(
            icon: const Icon(Icons.arrow_back_ios_new, size: 20),
            tooltip: '返回',
            onPressed: () => Navigator.of(context).maybePop(),
          )
        : null,
    title: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, overflow: TextOverflow.ellipsis),
        if (subtitle != null)
          Text(
            subtitle!,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
      ],
    ),
    actions: [...actions, const SizedBox(width: 4)],
  );
}

enum Tone { accent, warning, muted, danger }

/// Status always pairs a colored dot with text; color never carries it alone.
class StatusLabel extends StatelessWidget {
  const StatusLabel(this.text, {super.key, this.tone = Tone.muted});
  final String text;
  final Tone tone;
  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    final color = switch (tone) {
      Tone.accent => c.accent,
      Tone.warning => c.warning,
      Tone.danger => c.removed,
      Tone.muted => c.secondary,
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(text, style: TextStyle(fontSize: 13, color: c.secondary)),
      ],
    );
  }
}

/// Neutral grouping surface; only used where grouping is functional.
class Panel extends StatelessWidget {
  const Panel({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    this.outlined = false,
  });
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final bool outlined;
  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    final radius = BorderRadius.circular(DcSpace.control);
    return Material(
      color: outlined ? c.canvas : c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: outlined ? BorderSide(color: c.line) : BorderSide.none,
      ),
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: DcSpace.touch),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing, this.top = 20});
  final String text;
  final Widget? trailing;
  final double top;
  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(DcSpace.page, top, DcSpace.page, 8),
    child: Row(
      children: [
        Expanded(
          child: Text(text, style: Theme.of(context).textTheme.titleMedium),
        ),
        ?trailing,
      ],
    ),
  );
}

/// Agent logo as the desktop draws it (styles.css `.agent-icon`): a rounded
/// tile with a 1px border and the artwork filling it. Light theme uses one
/// neutral tile; dark theme uses each Agent's own tile colours.
class AgentGlyph extends StatelessWidget {
  const AgentGlyph({super.key, this.providerId, this.size = 40});
  final String? providerId;
  final double size;

  static const _logos = {
    'antigravity',
    'claude-code',
    'codebuddy',
    'codex',
    'cursor',
    'deepseek-harness',
    'grok',
    'kimi',
    'kiro',
    'opencode',
    'pi',
    'zcode',
  };

  /// Single-colour artwork: light on dark tiles, dark on light tiles.
  static const _monochrome = {'codex', 'cursor', 'grok', 'zcode', 'pi'};

  /// Dark-theme tiles (background, border) from the desktop stylesheet.
  static const _darkTiles = {
    'claude-code': (Color(0xFF35241D), Color(0xFF794932)),
    'codex': (Color(0xFF26302A), Color(0xFF536056)),
    'kimi': (Color(0xFF202A41), Color(0xFF3D527E)),
    'grok': (Color(0xFF171717), Color(0xFF555550)),
    'zcode': (Color(0xFF2C203E), Color(0xFF62438D)),
    'cursor': (Color(0xFF171717), Color(0xFF555550)),
    'antigravity': (Color(0xFF10151E), Color(0xFF3C70B4)),
    'fake': (Color(0xFF26331B), Color(0xFF4B6332)),
    'fake-peer': (Color(0xFF26331B), Color(0xFF4B6332)),
  };

  /// Brand tiles kept in both themes (white artwork).
  static const _brandTiles = {'kiro': (Color(0xFF8A47F9), Color(0xFF7A3BE6))};

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    var id = (providerId ?? '').toLowerCase();
    if (id == 'claude') id = 'claude-code';
    final (background, border) =
        _brandTiles[id] ??
        (dark
            ? _darkTiles[id] ??
                  (const Color(0xFF30302E), const Color(0xFF4A4945))
            : (const Color(0xFFF7F7F5), const Color(0xFFCFCFCB)));
    final foreground = dark ? const Color(0xFFD0D0CB) : const Color(0xFF4B4B47);
    // Claude Code's mark sits 2px in on a 26px tile; the rest fill the tile.
    final inset = id == 'claude-code' ? size * 2 / 26 : 0.0;
    Widget child;
    if (_logos.contains(id)) {
      final mono = _monochrome.contains(id);
      child = Padding(
        padding: EdgeInsets.all(inset),
        child: Image.asset(
          'assets/agents/$id.png',
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
          color: mono ? (dark ? const Color(0xFFF2F2ED) : Colors.black) : null,
          colorBlendMode: mono ? BlendMode.srcIn : null,
          semanticLabel: providerId,
        ),
      );
    } else {
      child = Center(
        child: Text(
          id.startsWith('fake')
              ? 'F'
              : (id.isEmpty ? '?' : id[0].toUpperCase()),
          style: TextStyle(
            fontSize: size * 0.5,
            fontWeight: FontWeight.w800,
            height: 1,
            color: id.startsWith('fake') ? context.dc.accent : foreground,
          ),
        ),
      );
    }
    final radius = BorderRadius.circular(size * 6 / 26);
    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: background,
        borderRadius: radius,
        border: Border.all(color: border),
      ),
      child: child,
    );
  }
}

class Tag extends StatelessWidget {
  const Tag(this.text, {super.key, this.tone = Tone.muted});
  final String text;
  final Tone tone;
  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    final color = tone == Tone.warning ? c.warning : c.secondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(text, style: TextStyle(fontSize: 12, color: color)),
    );
  }
}

/// Code never shrinks to fit; it scrolls horizontally.
class CodeBlock extends StatelessWidget {
  const CodeBlock(this.text, {super.key, this.maxLines});
  final String text;
  final int? maxLines;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    decoration: BoxDecoration(
      color: context.dc.code,
      borderRadius: BorderRadius.circular(8),
    ),
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.all(12),
      child: SelectableText(
        text,
        maxLines: maxLines,
        style: const TextStyle(
          fontFamily: monoFamily,
          fontFamilyFallback: monoFallback,
          fontSize: 13,
          height: 1.5,
        ),
      ),
    ),
  );
}

class EmptyNote extends StatelessWidget {
  const EmptyNote({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.action,
    this.footnote,
  });
  final IconData icon;
  final String title;
  final String body;
  final Widget? action;
  final String? footnote;
  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: context.dc.secondary),
            const SizedBox(height: 20),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              body,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: context.dc.secondary),
            ),
            if (action != null)
              Padding(padding: const EdgeInsets.only(top: 24), child: action),
            if (footnote != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(
                  footnote!,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

/// One-line inline error or notice under a header.
class InlineNotice extends StatelessWidget {
  const InlineNotice(this.text, {super.key, this.danger = false});
  final String text;
  final bool danger;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: DcSpace.page, vertical: 6),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 13,
        color: danger ? context.dc.removed : context.dc.secondary,
      ),
    ),
  );
}

String shortTime(DateTime? value, {DateTime? now}) {
  if (value == null) return '';
  final local = value.toLocal();
  final today = now ?? DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  final hm = '${two(local.hour)}:${two(local.minute)}';
  final day = DateTime(local.year, local.month, local.day);
  final diff = DateTime(today.year, today.month, today.day).difference(day);
  if (diff.inDays == 0) return hm;
  if (diff.inDays == 1) return '昨天 $hm';
  if (local.year == today.year) return '${local.month}月${local.day}日';
  return '${local.year}/${local.month}/${local.day}';
}

String dayGroup(DateTime? value, {DateTime? now}) {
  if (value == null) return '更早';
  final local = value.toLocal();
  final today = now ?? DateTime.now();
  final diff = DateTime(
    today.year,
    today.month,
    today.day,
  ).difference(DateTime(local.year, local.month, local.day)).inDays;
  if (diff <= 0) return '今天';
  if (diff == 1) return '昨天';
  if (diff < 7) return '近 7 天';
  return '更早';
}
