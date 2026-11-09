import 'package:dogcodes_app/l10n/strings.dart';
import 'package:flutter/material.dart';
import 'theme.dart';

/// Remaining-quota bars, ported from the desktop picker (AgentQuotaRing.tsx
/// and quotaPresentation.ts) so both clients list the same windows.
class QuotaReading {
  QuotaReading({
    required this.remaining,
    required this.exhausted,
    required this.window,
    this.resetsAt,
  });

  /// Percent left, or null when the vendor gave no usable reading.
  final double? remaining;
  final bool exhausted;
  final String? window;
  final DateTime? resetsAt;

  static Map<int, String> get _labels => {
    300: tr("5 小时"),
    10080: tr("每周"),
    0: tr("当前账期"),
  };
  static const _billing = {
    'cursor-included',
    'cursor-models',
    'cursor-other-models',
    'kiro-included',
  };

  /// [view] is one `quota_snapshots_for` entry ({providerId, quota, …}).
  static QuotaReading? from(Map<String, dynamic>? view, {DateTime? now}) {
    final quota = view?['quota'];
    if (quota is! Map) return null;
    final providerId = '${view?['providerId'] ?? ''}';
    final windows = [
      for (final w in (quota['windows'] as List? ?? const []))
        if (w is Map) Map<String, dynamic>.from(w),
    ];
    final at = now ?? DateTime.now();
    bool hasReset(Map w) {
      final r = w['resetsAtUnix'];
      return r is num && r * 1000 <= at.millisecondsSinceEpoch;
    }

    final primary = _ringWindow(windows, providerId);
    final reset = primary != null && hasReset(primary);
    final remaining = reset ? null : _remaining(primary?['usedPercent']);
    final stale =
        (quota['staleAfterUnixMs'] as num?) != null &&
        at.millisecondsSinceEpoch >= (quota['staleAfterUnixMs'] as num);
    final exhausted = providerId == 'antigravity'
        ? remaining == 0
        : quota['confidence'] == 'provider_reported' &&
              !stale &&
              windows.any(
                (w) =>
                    w['scope'] == null &&
                    !hasReset(w) &&
                    w['usedPercent'] is num &&
                    (w['usedPercent'] as num) >= 100,
              );
    final minutes = (primary?['windowMinutes'] as num?)?.toInt();
    final resets = primary?['resetsAtUnix'];
    return QuotaReading(
      remaining: remaining,
      exhausted: exhausted,
      window: primary == null
          ? null
          : _billing.contains(primary['id'])
          ? tr("每月")
          : _labels[minutes] ?? tr("{0} 分钟", [minutes]),
      resetsAt: resets is num
          ? DateTime.fromMillisecondsSinceEpoch(resets.toInt() * 1000)
          : null,
    );
  }

  static Map<String, dynamic>? _ringWindow(
    List<Map<String, dynamic>> windows,
    String providerId,
  ) {
    if (providerId == 'cursor') {
      return windows.where((w) => w['id'] == 'cursor-models').firstOrNull ??
          _primary(windows);
    }
    if (providerId != 'antigravity') return _primary(windows);
    return windows
        .where(
          (w) =>
              w['windowMinutes'] == 300 &&
              (w['scope'] == 'Gemini Models' ||
                  '${w['id']}'.startsWith('Gemini Models:')),
        )
        .firstOrNull;
  }

  /// Account five-hour bucket first, then the shortest reported window.
  static Map<String, dynamic>? _primary(List<Map<String, dynamic>> windows) {
    final account = windows.where((w) => w['scope'] == null).toList();
    final pool = account.isNotEmpty
        ? account
        : windows.every(
            (w) =>
                w['scope'] == tr("套餐内（终端读数）") ||
                (w['id'] == 'kiro-included' && w['scope'] == tr("套餐内（Kiro）")),
          )
        ? windows
        : <Map<String, dynamic>>[];
    return pool.where((w) => w['windowMinutes'] == 300).firstOrNull ??
        ([...pool]..sort(
              (a, b) => ((a['windowMinutes'] as num?) ?? 0).compareTo(
                (b['windowMinutes'] as num?) ?? 0,
              ),
            ))
            .firstOrNull;
  }

  static double? _remaining(Object? used) {
    if (used is! num || !used.isFinite) return null;
    final r = (100 - used).clamp(0, 100).toDouble();
    // A small positive balance must not round down to exhausted.
    return r > 0 && r < 0.1 ? 0.1 : (r * 10).round() / 10;
  }

  Color color(DcColors c) => exhausted
      ? const Color(0xFFD93025)
      : remaining == null
      ? c.secondary
      : remaining! > 50
      ? const Color(0xFF34A853)
      : remaining! > 20
      ? const Color(0xFFE2B96F)
      : const Color(0xFFD93025);

  String get valueText => exhausted
      ? '!'
      : remaining == null
      ? '?'
      : remaining! > 0 && remaining! < 1
      ? '<1%'
      : '${remaining!.round()}%';

  String get description {
    final parts = [
      exhausted
          ? tr("额度已用尽")
          : remaining == null
          ? tr("额度暂无读数")
          : tr("{0}剩余额度 {1}%", [window ?? '', remaining!.round()]),
      if (resetsAt != null) tr("重置时间：{0}", [_time(resetsAt!)]),
    ];
    return parts.join('，');
  }

  static String _time(DateTime t) => _quotaClock(t);
}

String _quotaClock(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  final now = DateTime.now();
  final hm = '${two(t.hour)}:${two(t.minute)}';
  return t.year == now.year && t.month == now.month && t.day == now.day
      ? hm
      : tr("{0}月{1}日 {2}", [t.month, t.day, hm]);
}

/// One picker row: a window label and bar, a balance amount, or "?".
class QuotaMeterRow {
  const QuotaMeterRow({
    required this.text,
    this.label,
    this.remaining,
    this.amount = false,
    this.detail,
  });

  final String? label;
  final double? remaining;
  final String text;
  final bool amount;
  final String? detail;
}

/// Every window the desktop picker shows for one agent.
class QuotaMeter {
  QuotaMeter(this.rows);
  final List<QuotaMeterRow> rows;

  /// A window or a balance is on screen, so Ready is redundant even when the
  /// reading itself is unknown.
  bool get showsFigure => rows.any((row) => row.amount || row.label != null);

  String get description =>
      rows.map((row) => row.detail ?? row.text).join('\n');

  static const _billing = {
    'cursor-included',
    'cursor-models',
    'cursor-other-models',
    'kiro-included',
  };

  /// [view] is one `quota_snapshots_for` entry. Null when the PC sent no quota.
  /// [composer] is the shorter set shown under the message box, as on the
  /// desktop: OpenCode's monthly window stays in the agent picker only.
  static QuotaMeter? from(
    Map<String, dynamic>? view, {
    DateTime? now,
    bool composer = false,
  }) {
    final quota = view?['quota'];
    if (quota is! Map) return null;
    final providerId = '${view?['providerId'] ?? ''}';
    final windows = [
      for (final w in (quota['windows'] as List? ?? const []))
        if (w is Map) Map<String, dynamic>.from(w),
    ];
    var picked = _pickerWindows(windows, providerId);
    if (composer && providerId == 'opencode') {
      final short = [
        for (final w in picked)
          if (w['id'] != 'opencode-go-monthly') w,
      ];
      if (short.isNotEmpty) picked = short;
    }
    if (picked.isEmpty) {
      final amounts = [
        for (final b in (quota['balances'] as List? ?? const []))
          if (b is Map && b['amount'] is num)
            QuotaMeterRow(
              text: _balance(b['amount'] as num, '${b['currency'] ?? ''}'),
              amount: true,
            ),
      ];
      if (amounts.isNotEmpty) return QuotaMeter(amounts);
      return QuotaMeter([QuotaMeterRow(text: '?', detail: tr("额度暂无读数"))]);
    }
    final at = now ?? DateTime.now();
    return QuotaMeter([for (final w in picked) _meterRow(w, providerId, at)]);
  }

  static List<Map<String, dynamic>> _pickerWindows(
    List<Map<String, dynamic>> windows,
    String providerId,
  ) {
    if (providerId == 'cursor') {
      return [
        for (final id in ['cursor-models', 'cursor-other-models'])
          ...windows.where((w) => w['id'] == id),
      ];
    }
    if (providerId == 'antigravity') {
      return _byLength(
        windows
            .where(
              (w) =>
                  w['scope'] == 'Gemini Models' ||
                  '${w['id'] ?? ''}'.startsWith('Gemini Models:'),
            )
            .toList(),
      );
    }
    if (providerId == 'opencode') {
      final go = windows
          .where((w) => '${w['id'] ?? ''}'.startsWith('opencode-go-'))
          .toList();
      return _byLength(go.isNotEmpty ? go : windows);
    }
    final account = windows.where((w) => w['scope'] == null).toList();
    final included = windows.every(
      (w) =>
          w['scope'] == '套餐内（终端读数）' ||
          (w['id'] == 'kiro-included' && w['scope'] == '套餐内（Kiro）'),
    );
    final pool = account.isNotEmpty
        ? account
        : included
        ? windows
        : <Map<String, dynamic>>[];
    return _byLength(pool);
  }

  static int _rank(Map<String, dynamic> w) {
    final minutes = (w['windowMinutes'] as num?)?.toInt() ?? 0;
    return minutes == 0 ? 1 << 30 : minutes;
  }

  static List<Map<String, dynamic>> _byLength(
    List<Map<String, dynamic>> windows,
  ) {
    final copy = [...windows];
    copy.sort((a, b) => _rank(a).compareTo(_rank(b)));
    return copy;
  }

  static QuotaMeterRow _meterRow(
    Map<String, dynamic> window,
    String providerId,
    DateTime at,
  ) {
    final resets = window['resetsAtUnix'];
    final resetAt = resets is num
        ? DateTime.fromMillisecondsSinceEpoch(resets.toInt() * 1000)
        : null;
    final pending = resetAt != null && !resetAt.isAfter(at);
    final remaining = pending
        ? null
        : QuotaReading._remaining(window['usedPercent']);
    final label = _label(window, providerId);
    final text = remaining == null
        ? '?'
        : remaining == 0
        ? tr("用尽")
        : _percentText(remaining);
    final head = remaining == null
        ? tr("额度暂无读数")
        : remaining == 0
        ? tr("额度已用尽")
        : tr("{0}剩余额度 {1}%", [label, remaining.round()]);
    final detail = resetAt == null
        ? '$label $head'.trim()
        : '$label $head，${tr("重置时间：{0}", [_quotaClock(resetAt)])}'.trim();
    return QuotaMeterRow(
      label: label,
      remaining: remaining,
      text: text,
      detail: detail,
    );
  }

  static String _label(Map<String, dynamic> window, String providerId) {
    final id = '${window['id'] ?? ''}';
    if (providerId == 'cursor' && id == 'cursor-models') return 'Cursor';
    if (providerId == 'cursor' && id == 'cursor-other-models') return tr("其他");
    final minutes = (window['windowMinutes'] as num?)?.toInt();
    if (id == 'opencode-go-monthly' || _billing.contains(id)) return tr("每月");
    return switch (minutes) {
      300 => tr("5 小时"),
      10080 => tr("每周"),
      0 => tr("当前账期"),
      _ => tr("{0} 分钟", [minutes]),
    };
  }

  static String _percentText(double remaining) {
    if (remaining > 0 && remaining < 1) return '<1%';
    final rounded = (remaining * 10).round() / 10;
    if (rounded == rounded.roundToDouble()) return '${rounded.round()}%';
    return '$rounded%';
  }

  static String _balance(num amount, String currency) {
    if (amount > 0 && amount < 0.000001) return '$currency <0.000001';
    final abs = amount.abs();
    final digits = abs != 0 && abs < 0.01 ? 6 : 2;
    return '$currency ${amount.toStringAsFixed(digits)}'.trim();
  }
}

Color _quotaColor(double remaining) => remaining > 50
    ? const Color(0xFF34A853)
    : remaining > 20
    ? const Color(0xFFE2B96F)
    : const Color(0xFFD93025);

/// Label, thin bar and remaining text. Long-press shows the reset time.
/// [compact] hugs the window name, for the composer chip.
class QuotaBars extends StatelessWidget {
  const QuotaBars({super.key, required this.meter, this.compact = false});
  final QuotaMeter meter;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final c = context.dc;
    final lone =
        meter.rows.length == 1 &&
        meter.rows.single.label == null &&
        !meter.rows.single.amount;
    return Tooltip(
      message: meter.description,
      triggerMode: TooltipTriggerMode.longPress,
      child: Semantics(
        label: meter.description,
        child: compact && meter.rows.any((row) => row.label != null)
            ? _CompactQuota(rows: meter.rows)
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (final row in meter.rows) ...[
                    if (row != meter.rows.first) const SizedBox(height: 7),
                    if (lone)
                      Text(
                        row.text,
                        style: TextStyle(
                          fontSize: 12,
                          color: c.secondary,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      )
                    else if (row.amount)
                      Text(
                        row.text,
                        style: TextStyle(
                          fontSize: 12,
                          color: c.secondary,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      )
                    else
                      _QuotaBar(row: row),
                  ],
                ],
              ),
      ),
    );
  }
}

/// Window names, bars and amounts each sit in their own column: names and
/// amounts only as wide as their longest entry, amounts right-aligned so the
/// digits line up close to the bars.
class _CompactQuota extends StatelessWidget {
  const _CompactQuota({required this.rows});
  final List<QuotaMeterRow> rows;

  static const _row = 14.0, _gap = 2.0;

  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    Widget column(
      CrossAxisAlignment align,
      Widget Function(QuotaMeterRow row) cell,
    ) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: align,
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const SizedBox(height: _gap),
          SizedBox(
            height: _row,
            child: Align(
              alignment: align == CrossAxisAlignment.end
                  ? Alignment.centerRight
                  : Alignment.centerLeft,
              child: cell(rows[i]),
            ),
          ),
        ],
      ],
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        column(
          CrossAxisAlignment.end,
          (row) => Text(
            row.label ?? '',
            style: TextStyle(fontSize: 12, height: 1, color: c.secondary),
          ),
        ),
        const SizedBox(width: 6),
        column(
          CrossAxisAlignment.start,
          (row) => _QuotaTrack(row: row, height: _row, amount: false),
        ),
        const SizedBox(width: 6),
        column(CrossAxisAlignment.end, (row) => _QuotaAmount(row: row)),
      ],
    );
  }
}

class _QuotaBar extends StatelessWidget {
  const _QuotaBar({required this.row});
  final QuotaMeterRow row;

  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 68,
          child: Text(
            row.label ?? '',
            textAlign: TextAlign.right,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, height: 1.3, color: c.secondary),
          ),
        ),
        const SizedBox(width: 8),
        _QuotaTrack(row: row),
      ],
    );
  }
}

class _QuotaTrack extends StatelessWidget {
  const _QuotaTrack({required this.row, this.height = 16, this.amount = true});
  final QuotaMeterRow row;
  final double height;

  /// Whether the amount follows the bar in a fixed-width slot; compact rows
  /// put amounts in a column of their own.
  final bool amount;

  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    final remaining = row.remaining;
    final color = remaining == null ? c.secondary : _quotaColor(remaining);
    final fraction = ((remaining ?? 0) / 100).clamp(0.0, 1.0);
    return SizedBox(
      height: height,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 64,
            height: 5,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(color: c.secondary.withValues(alpha: 0.28)),
                  FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: fraction,
                    child: ColoredBox(
                      color: remaining == null ? Colors.transparent : color,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (amount) ...[
            const SizedBox(width: 8),
            SizedBox(width: 48, child: _QuotaAmount(row: row)),
          ],
        ],
      ),
    );
  }
}

class _QuotaAmount extends StatelessWidget {
  const _QuotaAmount({required this.row});
  final QuotaMeterRow row;

  @override
  Widget build(BuildContext context) {
    final remaining = row.remaining;
    return Text(
      row.text,
      textAlign: TextAlign.right,
      maxLines: 1,
      style: TextStyle(
        fontSize: 13,
        height: 1.3,
        color: remaining == null
            ? context.dc.secondary
            : _quotaColor(remaining),
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}
