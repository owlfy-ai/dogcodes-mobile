import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/features/computers/remote_input.dart';

Map<String, dynamic> key(String direction) => {
  'kind': 'key',
  'key': 'ctrl',
  'direction': direction,
};
Map<String, dynamic> button(String direction) => {
  'kind': 'button',
  'button': 'left',
  'direction': direction,
};
void main() {
  test('a frozen click cannot release an unrelated local button', () async {
    final batches = <List<Map<String, dynamic>>>[];
    final queue = RemoteInputQueue((events) async {
      batches.add(events);
    });
    queue.setViewReady(false);
    queue.add(button('press'));
    queue.add(button('release'));
    queue.add(key('release'));
    await queue.idle;
    expect(batches, isEmpty);
    queue.dispose();
  });

  test(
    'dropping unsent picture intent settles idle without lifting the transport barrier',
    () async {
      final batches = <List<Map<String, dynamic>>>[];
      final queue = RemoteInputQueue((events) async {
        batches.add(events);
      });
      await queue.pause();
      queue.add({'kind': 'text', 'text': 'stale'});
      final idle = queue.idle;
      queue.setViewReady(false);
      await idle.timeout(const Duration(seconds: 1));
      expect(batches, isEmpty);
      queue.setViewReady(true);
      queue.add({'kind': 'text', 'text': 'fresh'});
      await Future<void>.delayed(Duration.zero);
      expect(batches, isEmpty);
      queue.resume();
      await queue.idle;
      expect(batches.single.single['text'], 'fresh');
      queue.dispose();
    },
  );

  test(
    'freezing drops unsent intent and releases in-flight remote holds in sequence',
    () async {
      final batches = <List<Map<String, dynamic>>>[];
      final first = Completer<void>();
      final queue = RemoteInputQueue((events) async {
        batches.add(events);
        if (batches.length == 1) await first.future;
      });
      queue.add(button('press'));
      queue.add({'kind': 'text', 'text': 'old picture task'});
      queue.add({'kind': 'move', 'x': 123, 'y': 456});
      queue.add(key('press'));
      queue.setViewReady(false);
      queue.add({'kind': 'text', 'text': 'while frozen'});
      queue.add(button('press'));
      first.complete();
      await queue.idle;
      expect(batches.length, 2);
      expect(batches[1], [button('release')]);
      queue.setViewReady(true);
      await queue.idle;
      expect(batches.length, 2, reason: 'thaw never replays dropped intent');
      queue.add({'kind': 'text', 'text': 'fresh picture'});
      await queue.idle;
      expect(batches.last, [
        {'kind': 'text', 'text': 'fresh picture'},
      ]);
      queue.dispose();
    },
  );
  test(
    'a held modifier is released once and no new presses pass a frozen view',
    () async {
      final batches = <List<Map<String, dynamic>>>[];
      final queue = RemoteInputQueue((events) async {
        batches.add(events);
      });
      queue.add(key('press'));
      await queue.idle;
      queue.setViewReady(false);
      await queue.idle;
      queue.setViewReady(false);
      queue.add(key('press'));
      await queue.idle;
      expect(batches, [
        [key('press')],
        [key('release')],
      ]);
      queue.dispose();
    },
  );
  test(
    'view readiness does not override a pending transport ownership barrier',
    () async {
      final batches = <List<Map<String, dynamic>>>[];
      final queue = RemoteInputQueue((events) async {
        batches.add(events);
      });
      await queue.pause();
      queue.add(key('press'));
      queue.setViewReady(false);
      queue.setViewReady(true);
      await Future<void>.delayed(Duration.zero);
      expect(batches, isEmpty);
      queue.add({'kind': 'text', 'text': 'new'});
      queue.resume();
      await queue.idle;
      expect(batches, [
        [
          {'kind': 'text', 'text': 'new'},
        ],
      ]);
      queue.dispose();
    },
  );
  test(
    'an unknown in-flight result never sends cleanup or replays after thaw',
    () async {
      final pending = Completer<void>();
      final batches = <List<Map<String, dynamic>>>[];
      final errors = <Object>[];
      final queue = RemoteInputQueue((events) async {
        batches.add(events);
        await pending.future;
      }, onError: errors.add);
      queue.add(button('press'));
      queue.setViewReady(false);
      pending.completeError(StateError('unknown'));
      await queue.idle;
      queue.setViewReady(true);
      queue.add(button('press'));
      await queue.idle;
      expect(batches.length, 1);
      expect(errors.length, 1);
      queue.dispose();
    },
  );
}
