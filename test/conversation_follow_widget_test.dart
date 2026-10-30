import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'timeline_paging_widget_test.dart' show PagedLink, openTurn, timeline;

/// One turn long enough to scroll.
class LongLink extends PagedLink {
  @override
  Future<dynamic> call(String method, dynamic params) async {
    if (method != 'timeline_tail') return super.call(method, params);
    return {
      'items': [
        PagedLink.item('u', 'turn3', 'user_message', '问题'),
        for (var i = 0; i < 30; i++)
          PagedLink.item('a$i', 'turn3', 'assistant_message', '回答第 $i 段'),
      ],
      'lastSequence': 9,
      'earlierBefore': null,
    };
  }
}

void main() {
  testWidgets('the newest output stays in view when the layout changes, '
      'until the user scrolls away', (tester) async {
    final hub = await openTurn(tester, LongLink());
    ScrollPosition position() =>
        tester.state<ScrollableState>(timeline).position;
    expect(position().maxScrollExtent, greaterThan(0));
    expect(position().pixels, position().maxScrollExtent);

    // A taller composer shrinks the timeline without a timeline event.
    await tester.enterText(find.byType(TextField), 'a\nb\nc\nd\ne');
    await tester.pumpAndSettle();
    expect(position().pixels, position().maxScrollExtent);

    // Even a short drag up stops following; a later layout change and the
    // finger still being down both leave the view where the user put it.
    final gesture = await tester.startGesture(tester.getCenter(timeline));
    await gesture.moveBy(const Offset(0, 30));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 10));
    await tester.pump();
    final held = position().pixels;
    expect(held, lessThan(position().maxScrollExtent));
    await tester.enterText(find.byType(TextField), 'a\nb\nc\nd\ne\nf\ng');
    await tester.pump();
    expect(position().pixels, held);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(position().pixels, lessThan(position().maxScrollExtent));

    // Back at the very bottom, it follows again.
    await tester.drag(timeline, const Offset(0, -2000));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'a');
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'a\nb\nc\nd\ne');
    await tester.pumpAndSettle();
    expect(position().pixels, position().maxScrollExtent);

    // Once the user scrolls up, later layout changes leave them there.
    await tester.drag(timeline, const Offset(0, 300));
    await tester.pumpAndSettle();
    final away = position().pixels;
    expect(away, lessThan(position().maxScrollExtent - 80));
    await tester.enterText(find.byType(TextField), 'a');
    await tester.pumpAndSettle();
    expect(position().pixels, away);

    await tester.pumpWidget(const SizedBox());
    hub.dispose();
  });
}
