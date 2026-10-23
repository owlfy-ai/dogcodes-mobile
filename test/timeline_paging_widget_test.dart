import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/app.dart';
import 'package:dogcodes_app/core/host_hub.dart';
import 'package:dogcodes_app/core/protocol.dart';
import 'package:dogcodes_app/features/conversation/conversation_page.dart';
import 'widget_test.dart' show FakeLink, fakeHub;

/// Three turns, one per page, newest first; the PC's paging rules in small.
class PagedLink extends FakeLink {
  PagedLink() : super('macbook-pro-host') {
    tailPaging = true;
  }
  final tails = <Map>[], fullReads = <Map>[];
  static Map<String, dynamic> item(
    String id,
    String turn,
    String kind,
    String text, [
    Map<String, dynamic> extra = const {},
  ]) => {
    'itemId': id,
    'turnId': turn,
    'kind': kind,
    'text': text,
    'occurredAt': FakeLink.now,
    ...extra,
  };
  static final turns = {
    'turn1': [
      item('u1', 'turn1', 'user_message', '最早的问题'),
      item('a1', 'turn1', 'assistant_message', '最早的回答'),
    ],
    'turn2': [
      item('u2', 'turn2', 'user_message', '中间的问题'),
      item('a2', 'turn2', 'assistant_message', '中间的回答'),
    ],
    'turn3': [
      item('u3', 'turn3', 'user_message', '最近的问题'),
      item('a3', 'turn3', 'assistant_message', '最近的回答…', {
        'truncated': true,
        'fullBytes': 300000,
      }),
    ],
  };
  @override
  Future<dynamic> call(String method, dynamic params) async {
    if (method == 'timeline_snapshot') {
      throw StateError('a tail-paging PC is never asked for everything');
    }
    if (method == 'timeline_item') {
      fullReads.add(Map.of(params as Map));
      return item('a3', 'turn3', 'assistant_message', '最近的回答（完整内容）');
    }
    if (method != 'timeline_tail') return super.call(method, params);
    tails.add(Map.of(params as Map));
    final order = turns.keys.toList();
    final before = params['beforeTurn'] as String?;
    final end = before == null
        ? order.length
        : order.indexOf(before.substring(5));
    var start = end - 1;
    final until = params['untilTurn'] as String?;
    if (until != null) {
      final target = order.indexOf(until.substring(5));
      if (target < 0) throw const ProtocolException('找不到这一轮对话，它可能已被删除');
      if (target < start) start = target;
    }
    return {
      'items': [for (final t in order.sublist(start, end)) ...turns[t]!],
      'lastSequence': 9,
      'earlierBefore': start > 0 ? 'turn:${order[start]}' : null,
    };
  }
}

Finder get timeline => find
    .descendant(
      of: find.byKey(const ValueKey('conversation-timeline')),
      matching: find.byType(Scrollable),
    )
    .first;

Future<HostHub> openTurn(
  WidgetTester tester,
  PagedLink link, {
  String? focusTurnId,
}) async {
  final hub = fakeHub(link);
  await tester.pumpWidget(DogCodesApp(hub: hub));
  await tester.pumpAndSettle();
  unawaited(
    tester
        .state<NavigatorState>(find.byType(Navigator).first)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => ConversationPage(
              hostId: hub.hosts.single.id,
              taskId: 't2',
              focusTurnId: focusTurnId,
            ),
          ),
        ),
  );
  await tester.pumpAndSettle();
  return hub;
}

void main() {
  testWidgets('a long conversation opens on its newest turn and pages back '
      'without rebuilding rows already shown', (tester) async {
    final link = PagedLink();
    final hub = await openTurn(tester, link);
    await tester.scrollUntilVisible(
      find.text('最近的问题'),
      -300,
      scrollable: timeline,
    );
    expect(find.text('中间的问题'), findsNothing);
    expect(link.tails.first.containsKey('beforeTurn'), isFalse);

    final shown = tester.element(find.text('最近的问题'));
    await tester.scrollUntilVisible(
      find.text('加载更早的消息'),
      -300,
      scrollable: timeline,
    );
    await tester.tap(find.text('加载更早的消息'));
    await tester.pumpAndSettle();
    expect(link.tails.last['beforeTurn'], 'turn:turn3');
    expect(find.text('中间的问题'), findsOneWidget);
    // The same element, moved to its new index: its state survives.
    expect(identical(tester.element(find.text('最近的问题')), shown), isTrue);
    await tester.pumpWidget(const SizedBox());
    hub.dispose();
  });

  testWidgets('a search jump reads back to its turn in one request', (
    tester,
  ) async {
    final link = PagedLink();
    final hub = await openTurn(tester, link, focusTurnId: 'turn1');
    expect(link.tails.last['untilTurn'], 'turn:turn1');
    expect(link.tails.length, 2);
    expect(find.text('最早的问题'), findsOneWidget);
    expect(find.textContaining('正在定位到该轮'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    hub.dispose();
  });

  testWidgets('a search jump to a deleted turn says so', (tester) async {
    final link = PagedLink();
    final hub = await openTurn(tester, link, focusTurnId: 'gone');
    expect(find.textContaining('找不到这一轮对话'), findsOneWidget);
    expect(find.text('最近的问题'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    hub.dispose();
  });

  testWidgets('a trimmed item is read in full on request', (tester) async {
    final link = PagedLink();
    final hub = await openTurn(tester, link);
    await tester.tap(find.textContaining('内容较长已截断'));
    await tester.pumpAndSettle();
    expect(link.fullReads.single, {'taskId': 't2', 'itemId': 'a3'});
    expect(find.text('最近的回答（完整内容）'), findsOneWidget);
    expect(find.textContaining('内容较长已截断'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    hub.dispose();
  });
}
