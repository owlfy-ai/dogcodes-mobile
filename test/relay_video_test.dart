import 'dart:async';
import 'dart:typed_data';

import 'package:dogcodes_app/features/computers/relay_video.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> frame(int seq, {bool key = false}) => {
  'type': 'video',
  'seq': seq,
  'key': key,
  'payload': Uint8List(100),
};

void main() {
  test(
    'frames decode in order; acks are cumulative, coalesced, one in flight',
    () {
      fakeAsync((async) {
        final decoded = <int>[];
        final acks = <(int?, bool)>[];
        final gates = <Completer<void>>[];
        final r = RelayVideoReceiver(
          decode: (data, key) async => decoded.add(data.length),
          control: ({int? ack, bool keyframe = false}) {
            acks.add((ack, keyframe));
            final gate = Completer<void>();
            gates.add(gate);
            return gate.future;
          },
          now: () => async.getClock(DateTime(2026)).now(),
        );
        r.onFrame(frame(1, key: true));
        async.flushMicrotasks();
        expect(acks, [(1, false)]);
        for (var i = 2; i <= 5; i++) {
          r.onFrame(frame(i));
        }
        async.flushMicrotasks();
        // Previous ack still unanswered: nothing more goes out.
        expect(acks.length, 1);
        gates.last.complete();
        async.elapse(const Duration(milliseconds: 100));
        expect(acks.last, (5, false));
        expect(acks.length, 2);
        expect(r.decoded, 5);
        expect(r.live, isTrue);
      });
    },
  );

  test('a decode error skips deltas until a requested keyframe', () {
    fakeAsync((async) {
      final acks = <(int?, bool)>[];
      var fail = false;
      final r = RelayVideoReceiver(
        decode: (data, key) async {
          if (fail) throw StateError('broken');
        },
        control: ({int? ack, bool keyframe = false}) async =>
            acks.add((ack, keyframe)),
        now: () => async.getClock(DateTime(2026)).now(),
      );
      r.onFrame(frame(1, key: true));
      async.elapse(const Duration(milliseconds: 150));
      fail = true;
      r.onFrame(frame(2));
      async.elapse(const Duration(milliseconds: 150));
      expect(r.live, isFalse);
      expect(acks.last, (2, true));
      fail = false;
      r.onFrame(frame(3));
      r.onFrame(frame(4));
      async.elapse(const Duration(milliseconds: 150));
      expect(r.skipped, 2);
      // Skipped frames are still acknowledged so the PC's window moves.
      expect(acks.last.$1, 4);
      r.onFrame(frame(5, key: true));
      async.elapse(const Duration(milliseconds: 150));
      expect(r.live, isTrue);
      expect(r.decoded, 2);
    });
  });

  test('a backlog drops to the newest keyframe, or asks for one', () {
    fakeAsync((async) {
      final acks = <(int?, bool)>[];
      final hold = Completer<void>();
      var calls = 0;
      final r = RelayVideoReceiver(
        decode: (data, key) async {
          if (calls++ == 0) await hold.future;
        },
        control: ({int? ack, bool keyframe = false}) async =>
            acks.add((ack, keyframe)),
        maxBacklog: 3,
        now: () => async.getClock(DateTime(2026)).now(),
      );
      r.onFrame(frame(1, key: true)); // stuck in the decoder
      async.flushMicrotasks();
      for (var i = 2; i <= 6; i++) {
        r.onFrame(frame(i));
      }
      expect(r.skipped, greaterThan(0));
      async.elapse(const Duration(milliseconds: 600));
      expect(acks.any((a) => a.$2), isTrue);
      hold.complete();
      async.elapse(const Duration(milliseconds: 200));
      // After the stuck keyframe, remaining deltas decode; nothing is lost
      // from the ack sequence.
      expect(acks.last.$1, 6);
      r.dispose();
    });
  });
}
