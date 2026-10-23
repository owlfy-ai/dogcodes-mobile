import 'dart:convert';
import 'package:dogcodes_app/core/live_timeline.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> delta(int seq, String text, {String item = 'm1'}) => {
  'sequence': seq,
  'eventType': 'message.delta',
  'occurredAt': '2026-10-20T00:00:00Z',
  'source': {'kind': 'driver', 'providerId': 'codex'},
  'payload': {'taskId': 't', 'turnId': 'u', 'itemId': item, 'text': text},
};

Map<String, dynamic> activity(int seq, Map<String, dynamic> data) => {
  'sequence': seq,
  'eventType': 'activity.updated',
  'occurredAt': '2026-10-20T00:00:00Z',
  'source': {'kind': 'hub'},
  'payload': {'taskId': 't', 'turnId': 'u', 'itemId': 'a1', 'data': data},
};

void main() {
  test('buffer overflow rejects snapshots that can no longer be repaired', () {
    final live = LiveTimeline('t')
      ..reset({'items': [], 'lastSequence': 0})
      ..beginRead();
    for (var i = 1; i <= 4002; i++) {
      live.apply(delta(i, 'x'));
    }
    expect(live.items.single['text'], 'x' * 4002);
    expect(live.needsSnapshot, isTrue);
    expect(live.reset({'items': [], 'lastSequence': 1}), isFalse);
    expect(live.items.single['text'], 'x' * 4002);
    expect(
      live.reset({
        'items': [
          {
            'itemId': 'message:t:u:m1',
            'kind': 'assistant_message',
            'text': 'x' * 4001,
          },
        ],
        'lastSequence': 4001,
      }),
      isTrue,
    );
    expect(live.items.single['text'], 'x' * 4002);
    expect(live.needsSnapshot, isFalse);
    expect(live.apply(delta(4002, 'duplicate')), isFalse);
  });
  test('deltas append to one message; duplicates and other tasks ignored', () {
    final live = LiveTimeline('t')..reset({'items': [], 'lastSequence': 3});
    expect(live.apply(delta(3, 'old')), isFalse);
    expect(live.apply(delta(4, '你好')), isTrue);
    expect(live.apply(delta(5, '，世界')), isTrue);
    expect(live.apply(delta(5, '，世界')), isFalse);
    final other = delta(6, 'x')..['payload']['taskId'] = 'other';
    expect(live.apply(other), isFalse);
    expect(live.items, hasLength(1));
    expect(live.items.single['itemId'], 'message:t:u:m1');
    expect(live.items.single['kind'], 'assistant_message');
    expect(live.items.single['text'], '你好，世界');
    expect(live.items.single['providerId'], 'codex');
  });

  test('activity patches follow the PC projection rules', () {
    final live = LiveTimeline('t')..reset({'items': [], 'lastSequence': 0});
    live.apply(
      activity(1, {
        'type': 'tool',
        'name': 'Bash',
        'status': 'running',
        'startedAt': 'a',
      }),
    );
    live.apply(
      activity(2, {'textDelta': 'ok', 'status': 'completed', 'startedAt': 'b'}),
    );
    live.apply(
      activity(3, {'textDelta': '!', 'status': 'running', 'input': null}),
    );
    final data = jsonDecode(live.items.single['text'] as String);
    expect(data, {
      'type': 'tool',
      'name': 'Bash',
      'status': 'completed',
      'startedAt': 'a',
      'text': 'ok!',
    });
    expect(live.items.single['kind'], 'activity');
  });

  test('an idle loaded timeline merges without buffering', () {
    final live = LiveTimeline('t')..reset({'items': [], 'lastSequence': 0});
    for (var i = 1; i <= 5000; i++) {
      live.apply(delta(i, 'x'));
    }
    expect(live.items.single['text'], 'x' * 5000);
    expect(live.needsSnapshot, isFalse);
    // A read started now is repaired by what streams during it.
    live.beginRead();
    live.apply(delta(5001, 'y'));
    expect(
      live.reset({
        'items': [
          {
            'itemId': 'message:t:u:m1',
            'kind': 'assistant_message',
            'text': 'x' * 5000,
          },
        ],
        'lastSequence': 5000,
      }),
      isTrue,
    );
    live.endRead();
    expect(live.items.single['text'], '${'x' * 5000}y');
  });

  test('events during a snapshot read are kept; stale snapshots ignored', () {
    final live = LiveTimeline('t');
    // Streamed before the first snapshot returns.
    live.apply(delta(8, 'A'));
    live.apply(delta(9, 'B'));
    live.reset({
      'items': [
        {'itemId': 'message:t:u:m1', 'kind': 'assistant_message', 'text': 'A'},
      ],
      'lastSequence': 8,
    });
    expect(live.items.single['text'], 'AB');
    expect(live.cursor, 9);
    // An older read finishing late must not roll the timeline back.
    expect(live.reset({'items': [], 'lastSequence': 5}), isFalse);
    expect(live.items.single['text'], 'AB');
    live.apply(delta(10, 'C', item: 'm2'));
    expect(live.items.map((i) => i['text']), ['AB', 'C']);
  });

  test('tail pages keep loaded history when the tail is re-read', () {
    Map<String, dynamic> item(String id, String turn) => {
      'itemId': id,
      'turnId': turn,
      'kind': 'assistant_message',
      'text': id,
    };
    final live = LiveTimeline('t');
    live.reset({
      'items': [item('b', 'u2'), item('c', 'u3')],
      'lastSequence': 5,
      'earlierBefore': 'b',
    });
    expect(live.earlierBefore, 'b');

    live.prependEarlier({
      'items': [item('a', 'u1')],
      'earlierBefore': null,
    });
    expect(live.items.map((i) => i['itemId']), ['a', 'b', 'c']);
    expect(live.earlierBefore, isNull);

    // The new tail drops u2 out of its window; the loaded pages keep it.
    live.reset({
      'items': [item('c', 'u3'), item('d', 'u4')],
      'lastSequence': 9,
      'earlierBefore': 'c',
    });
    expect(live.items.map((i) => i['itemId']), ['a', 'b', 'c', 'd']);
    expect(live.earlierBefore, isNull);

    // A whole timeline from an older PC replaces everything.
    live.reset({
      'items': [item('z', 'u9')],
      'lastSequence': 10,
    });
    expect(live.items.map((i) => i['itemId']), ['z']);
    expect(live.earlierBefore, isNull);
  });

  test('without loaded pages a tail re-read only shows the new tail', () {
    final live = LiveTimeline('t')
      ..reset({
        'items': [
          {'itemId': 'a', 'turnId': 'u1'},
        ],
        'lastSequence': 1,
        'earlierBefore': null,
      })
      ..reset({
        'items': [
          {'itemId': 'b', 'turnId': 'u2'},
        ],
        'lastSequence': 2,
        'earlierBefore': 'b',
      });
    expect(live.items.map((i) => i['itemId']), ['b']);
    expect(live.earlierBefore, 'b');
  });

  Map<String, dynamic> msg(String id, String turn, [String text = '']) => {
    'itemId': id,
    'turnId': turn,
    'kind': 'assistant_message',
    'text': text,
  };

  test('a tail with no overlap restarts paging instead of leaving a gap', () {
    final live = LiveTimeline('t')
      ..reset({
        'items': [msg('b', 'u2')],
        'lastSequence': 1,
        'earlierBefore': 'turn:u2',
      })
      ..prependEarlier({
        'items': [msg('a', 'u1')],
        'earlierBefore': null,
      });
    expect(live.earlierBefore, isNull);
    // Back online after many turns: the new tail starts well after u2.
    live.reset({
      'items': [msg('z', 'u9')],
      'lastSequence': 50,
      'earlierBefore': 'turn:u9',
    });
    expect(live.items.map((i) => i['itemId']), ['z']);
    expect(live.earlierBefore, 'turn:u9');
  });

  test('a re-read tail replaces its turns whole, late items included', () {
    final live = LiveTimeline('t')
      ..reset({
        'items': [msg('b', 'u2'), msg('c', 'u3')],
        'lastSequence': 1,
        'earlierBefore': 'turn:u2',
      })
      ..prependEarlier({
        'items': [msg('a', 'u1')],
        'earlierBefore': null,
      });
    live.reset({
      'items': [msg('c', 'u3'), msg('d', 'u4'), msg('c-review', 'u3')],
      'lastSequence': 9,
      'earlierBefore': 'turn:u3',
    });
    expect(live.items.map((i) => i['itemId']), [
      'a',
      'b',
      'c',
      'd',
      'c-review',
    ]);
  });

  test('deltas already merged into kept items are not replayed', () {
    final live = LiveTimeline('t')
      ..reset({
        'items': [msg('message:t:u:m1', 'u', 'old'), msg('c', 'u2')],
        'lastSequence': 1,
        'earlierBefore': 'turn:u',
      })
      ..prependEarlier({'items': <dynamic>[], 'earlierBefore': null});
    live.beginRead();
    // Late output for turn u (outside the next tail) streams during the read.
    live.apply(delta(2, '+1'));
    expect(live.items.first['text'], 'old+1');
    live.reset({
      'items': [msg('c', 'u2'), msg('n', 'u5', 'new')],
      'lastSequence': 1,
      'earlierBefore': 'turn:u2',
    });
    live.endRead();
    expect(live.items.map((i) => i['itemId']), ['message:t:u:m1', 'c', 'n']);
    final kept = live.items.firstWhere((i) => i['itemId'] == 'message:t:u:m1');
    expect(kept['text'], 'old+1');
  });

  test('a trimmed item can be replaced by its full version', () {
    final live = LiveTimeline('t')
      ..reset({
        'items': [
          {...msg('x', 'u', 'short…'), 'truncated': true},
        ],
        'lastSequence': 1,
      });
    expect(live.replaceItem(msg('x', 'u', 'the full text')), isTrue);
    expect(live.items.single['text'], 'the full text');
    expect(live.replaceItem(msg('gone', 'u')), isFalse);
  });
}
