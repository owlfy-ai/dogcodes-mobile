import 'package:dogcodes_app/l10n/strings.dart';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'theme.dart';

/// Remaining-quota ring, ported from the desktop (AgentQuotaRing.tsx and
/// quotaPresentation.ts) so both clients pick the same window and colours.
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

  static String _time(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    final now = DateTime.now();
    final hm = '${two(t.hour)}:${two(t.minute)}';
    return t.year == now.year && t.month == now.month && t.day == now.day
        ? hm
        : tr("{0}月{1}日 {2}", [t.month, t.day, hm]);
  }
}

/// Compact ring + percentage. Long-press shows the window and reset time.
class QuotaRing extends StatelessWidget {
  const QuotaRing({super.key, required this.reading, this.showValue = true});
  final QuotaReading reading;
  final bool showValue;
  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final c = context.dc;
    final color = reading.color(c);
    return Tooltip(
      message: reading.description,
      triggerMode: TooltipTriggerMode.longPress,
      child: Semantics(
        label: reading.description,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CustomPaint(
              size: const Size.square(18),
              painter: _RingPainter(
                fraction: (reading.remaining ?? 0) / 100,
                color: color,
                track: c.secondary.withValues(alpha: 0.3),
              ),
            ),
            if (showValue) ...[
              const SizedBox(width: 4),
              Text(
                reading.valueText,
                style: TextStyle(
                  fontSize: 13,
                  color: reading.exhausted ? color : c.secondary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.fraction,
    required this.color,
    required this.track,
  });
  final double fraction;
  final Color color, track;
  @override
  void paint(Canvas canvas, Size size) {
    // Same proportions as the desktop SVG: r=7, stroke 2.5 in a 20 box.
    final scale = size.width / 20;
    final rect = Rect.fromCircle(
      center: size.center(Offset.zero),
      radius: 7 * scale,
    );
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5 * scale;
    canvas.drawArc(rect, 0, math.pi * 2, false, stroke..color = track);
    if (fraction > 0) {
      canvas.drawArc(
        rect,
        -math.pi / 2,
        math.pi * 2 * fraction.clamp(0, 1),
        false,
        stroke
          ..color = color
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.fraction != fraction || old.color != color || old.track != track;
}
