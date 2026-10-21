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
    final live = LiveTimeline('t')..reset({'items': [], 'lastSequence': 0});
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
}
