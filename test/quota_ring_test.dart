import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/ui/quota_ring.dart';
import 'package:dogcodes_app/ui/theme.dart';

Map<String, dynamic> view(
  String provider,
  List<Map<String, dynamic>> windows,
) => {
  'providerId': provider,
  'quota': {
    'windows': windows,
    'confidence': 'provider_reported',
    'staleAfterUnixMs': DateTime.now().millisecondsSinceEpoch + 60000,
  },
};

void main() {
  test('five-hour account window wins and shows remaining', () {
    final r = QuotaReading.from(
      view('codex', [
        {'id': 'weekly', 'windowMinutes': 10080, 'usedPercent': 10},
        {'id': 'primary', 'windowMinutes': 300, 'usedPercent': 76},
      ]),
    )!;
    expect(r.remaining, 24);
    expect(r.valueText, '24%');
    expect(r.window, '5 小时');
    expect(r.exhausted, isFalse);
  });

  test(
    'any account window at 100% is exhausted; tiny balance stays positive',
    () {
      final r = QuotaReading.from(
        view('claude-code', [
          {'id': 'primary', 'windowMinutes': 300, 'usedPercent': 99.95},
          {'id': 'weekly', 'windowMinutes': 10080, 'usedPercent': 100},
        ]),
      )!;
      expect(r.exhausted, isTrue);
      expect(r.valueText, '!');
      final small = QuotaReading.from(
        view('codex', [
          {'id': 'p', 'windowMinutes': 300, 'usedPercent': 99.95},
        ]),
      )!;
      expect(small.remaining, 0.1);
      expect(small.valueText, '<1%');
    },
  );

  test('no reading: unknown ring; no quota: no ring', () {
    expect(QuotaReading.from(view('kimi', []))!.valueText, '?');
    expect(QuotaReading.from({'providerId': 'pi', 'quota': null}), isNull);
  });

  test('bars list every desktop window, and a balance counts as shown', () {
    final codex = QuotaMeter.from(
      view('codex', [
        {'id': 'weekly', 'windowMinutes': 10080, 'usedPercent': 100},
        {'id': 'primary', 'windowMinutes': 300, 'usedPercent': 0},
      ]),
    )!;
    expect(codex.rows.map((r) => r.label).toList(), ['5 小时', '每周']);
    expect(codex.rows.map((r) => r.text).toList(), ['100%', '用尽']);
    expect(codex.showsFigure, isTrue);

    final cursor = QuotaMeter.from(
      view('cursor', [
        {'id': 'cursor-other-models', 'windowMinutes': 0, 'usedPercent': 41.8},
        {'id': 'cursor-models', 'windowMinutes': 0, 'usedPercent': 40},
      ]),
    )!;
    expect(cursor.rows.map((r) => '${r.label} ${r.text}').toList(), [
      'Cursor 60%',
      '其他 58.2%',
    ]);

    final antigravity = QuotaMeter.from(
      view('antigravity', [
        {
          'id': 'Gemini Models:5h',
          'scope': 'Gemini Models',
          'windowMinutes': 300,
          'usedPercent': 0,
        },
        {
          'id': 'Claude and GPT models:5h',
          'scope': 'Claude and GPT models',
          'windowMinutes': 300,
          'usedPercent': 50,
        },
        {
          'id': 'Gemini Models:7d',
          'scope': 'Gemini Models',
          'windowMinutes': 10080,
          'usedPercent': 40,
        },
      ]),
    )!;
    expect(antigravity.rows.map((r) => '${r.label} ${r.text}').toList(), [
      '5 小时 100%',
      '每周 60%',
    ]);

    final unknown = QuotaMeter.from(view('codebuddy', []))!;
    expect(unknown.rows.single.text, '?');
    expect(unknown.showsFigure, isFalse);
    final grok = QuotaMeter.from(
      view('grok', [
        {'id': 'weekly', 'windowMinutes': 10080},
      ]),
    )!;
    expect(grok.rows.single.label, '每周');
    expect(grok.rows.single.text, '?');
    expect(grok.showsFigure, isTrue);
    final balance = QuotaMeter.from({
      'providerId': 'pi',
      'quota': {
        'windows': [],
        'balances': [
          {'amount': 301.82, 'currency': 'CNY'},
          {'amount': 0, 'currency': 'USD'},
        ],
      },
    })!;
    expect(balance.rows.map((r) => r.text).toList(), [
      'CNY 301.82',
      'USD 0.00',
    ]);
    expect(balance.showsFigure, isTrue);
    expect(QuotaMeter.from({'providerId': 'pi', 'quota': null}), isNull);
  });

  testWidgets('quota bars show the window label and remaining percent', (
    tester,
  ) async {
    final meter = QuotaMeter.from(
      view('codex', [
        {'id': 'primary', 'windowMinutes': 300, 'usedPercent': 4},
      ]),
    )!;
    await tester.pumpWidget(
      MaterialApp(
        theme: dcTheme(Brightness.light),
        home: Scaffold(body: QuotaBars(meter: meter)),
      ),
    );
    expect(find.text('5 小时'), findsOneWidget);
    expect(find.text('96%'), findsOneWidget);
  });

  test(
    'the composer shows OpenCode Go 5-hour and weekly, the picker all three',
    () {
      final go = view('opencode', [
        {'id': 'opencode-go-rolling', 'windowMinutes': 300, 'usedPercent': 0},
        {'id': 'opencode-go-weekly', 'windowMinutes': 10080, 'usedPercent': 0},
        {'id': 'opencode-go-monthly', 'windowMinutes': 43200, 'usedPercent': 0},
      ]);
      expect(QuotaMeter.from(go)!.rows.map((r) => r.label), [
        '5 小时',
        '每周',
        '每月',
      ]);
      expect(QuotaMeter.from(go, composer: true)!.rows.map((r) => r.label), [
        '5 小时',
        '每周',
      ]);
    },
  );
}
