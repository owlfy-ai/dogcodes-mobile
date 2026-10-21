import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/ui/quota_ring.dart';

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
}
