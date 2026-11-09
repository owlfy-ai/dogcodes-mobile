import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'timeline_paging_widget_test.dart' show PagedLink, openTurn;

void main() {
  testWidgets('composer: agent chip on the centre line, buttons inset '
      'evenly from the edges', (tester) async {
    final hub = await openTurn(tester, PagedLink());
    final attach = tester.getRect(find.byTooltip('添加附件'));
    final send = tester.getRect(find.byTooltip('发送'));
    final card = tester.getRect(
      find
          .ancestor(
            of: find.byType(TextField),
            // The bordered card itself, inside the composer's outer margin.
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    final chip = tester.getRect(
      find
          .ancestor(
            of: find.text('Claude Code'),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(attach.left - card.left, moreOrLessEquals(card.right - send.right));
    expect(
      card.bottom - attach.bottom,
      moreOrLessEquals(card.bottom - send.bottom),
    );
    expect(
      attach.left - card.left,
      moreOrLessEquals(card.bottom - attach.bottom),
    );
    expect(chip.center.dx, moreOrLessEquals(card.center.dx, epsilon: 0.5));
    expect(chip.center.dy, moreOrLessEquals(send.center.dy, epsilon: 0.5));
    expect(chip.height, send.height);
    await tester.pumpWidget(const SizedBox());
    hub.dispose();
  });
}
