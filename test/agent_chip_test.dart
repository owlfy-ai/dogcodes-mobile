import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/features/conversation/agent_picker.dart';
import 'package:dogcodes_app/ui/quota_ring.dart';
import 'package:dogcodes_app/ui/theme.dart';
import 'quota_ring_test.dart' show view;

void main() {
  testWidgets('the agent pill fits one to three quota rows, centred, with '
      'amounts close to their bars', (tester) async {
    final windows = [
      {'id': 'primary', 'windowMinutes': 300, 'usedPercent': 18},
      {'id': 'weekly', 'windowMinutes': 10080, 'usedPercent': 6},
      {'id': 'monthly', 'windowMinutes': 43200, 'usedPercent': 0},
    ];
    for (var rows = 1; rows <= 3; rows++) {
      await tester.pumpWidget(
        MaterialApp(
          theme: dcTheme(Brightness.light),
          home: Scaffold(
            body: Center(
              child: AgentChips(
                choice: null,
                onTap: () {},
                quota: QuotaMeter.from(
                  view('opencode', windows.sublist(0, rows)),
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull, reason: '$rows rows');
      final pill = tester.getRect(find.byType(Material).last);
      final bars = tester.getRect(find.byType(QuotaBars));
      expect(pill.height, greaterThanOrEqualTo(44));
      expect(pill.height, greaterThanOrEqualTo(bars.height + 12));
      expect(bars.center.dy, moreOrLessEquals(pill.center.dy, epsilon: 0.5));
      // Amounts are right-aligned in their own column; the widest one sits
      // just after the bars rather than in a wide fixed slot.
      final track = tester.getRect(
        find.byWidgetPredicate((w) => w is SizedBox && w.width == 64).first,
      );
      final widest = tester
          .widgetList<Text>(find.byType(Text))
          .where((t) => t.data?.endsWith('%') ?? false)
          .map((t) => tester.getRect(find.byWidget(t)).left)
          .reduce((a, b) => a < b ? a : b);
      expect(widest - track.right, moreOrLessEquals(6, epsilon: 0.5));
    }
  });
}
