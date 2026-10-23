import 'dart:async';
import 'dart:ui';

import 'package:dogcodes_app/features/computers/frame_rate.dart';
import 'package:dogcodes_app/features/computers/remote_gestures.dart';
import 'package:dogcodes_app/features/computers/remote_input.dart';
import 'package:dogcodes_app/features/computers/remote_view.dart';
import 'package:dogcodes_app/features/computers/video_stats.dart';
import 'package:flutter_test/flutter_test.dart';

Duration ms(int v) => Duration(milliseconds: v);

void expectOffset(Offset actual, Offset expected) {
  expect(actual.dx, closeTo(expected.dx, 1e-6));
  expect(actual.dy, closeTo(expected.dy, 1e-6));
}

void main() {
  group('RemoteViewport', () {
    // A 16:10 Mac frame (any pixel size) in a portrait phone view.
    RemoteViewport portrait() =>
        RemoteViewport()..layout(const Size(400, 800), const Size(1600, 1000));

    test('fits and centres the frame, mapping corners to 0..1', () {
      final v = portrait();
      expect(v.rect, const Rect.fromLTWH(0, 275, 400, 250));
      expectOffset(v.toRemote(const Offset(0, 275)), Offset.zero);
      expectOffset(v.toRemote(const Offset(400, 525)), const Offset(1, 1));
      expectOffset(v.toRemote(const Offset(200, 400)), const Offset(0.5, 0.5));
      // Letterbox taps clamp onto the nearest screen edge.
      expectOffset(v.toRemote(const Offset(100, 10)), const Offset(0.25, 0));
      expect(v.contains(const Offset(100, 10)), isFalse);
    });

    test('Retina frame size does not change where a tap lands', () {
      final thumb = portrait();
      final retina = RemoteViewport()
        ..layout(const Size(400, 800), const Size(3456, 2160));
      const tap = Offset(123, 333);
      expectOffset(retina.toRemote(tap), thumb.toRemote(tap));
      expect(moveEvent(const Offset(1, 0.5)), {
        'kind': 'move',
        'x': 65535,
        'y': 32768,
      });
    });

    test('pinch zoom keeps the focal point fixed and clamps', () {
      final v = portrait();
      const focal = Offset(300, 400);
      final before = v.toRemote(focal);
      v.zoomAt(focal, 4);
      expect(v.zoom, 4);
      expectOffset(v.toRemote(focal), before);
      expectOffset(v.toLocal(before), focal);
      v.zoomAt(focal, 100);
      expect(v.zoom, RemoteViewport.maxZoom);
      v.zoomAt(focal, 0.0001);
      expect(v.zoom, 1);
      expect(v.rect, const Rect.fromLTWH(0, 275, 400, 250));
    });

    test('pan never leaves a gap and centres a short axis', () {
      final v = portrait()..zoomAt(const Offset(200, 400), 2);
      // 800×500: wider than the view, still shorter than it.
      v.panBy(const Offset(1000, 1000));
      expect(v.rect.left, 0);
      expect(v.rect.top, 150);
      v.panBy(const Offset(-5000, 0));
      expect(v.rect.right, 400);
      v.fit();
      expect(v.rect, const Rect.fromLTWH(0, 275, 400, 250));
    });

    test('rotation keeps the centred remote point and re-fits', () {
      final v = portrait()..zoomAt(const Offset(300, 400), 2);
      final centre = v.toRemote(const Offset(200, 400));
      v.layout(const Size(800, 400), const Size(1600, 1000));
      expect(v.fitScale, 0.4);
      expectOffset(v.toRemote(const Offset(400, 200)), centre);
    });

    test('ensureVisible follows a point off screen', () {
      final v = portrait()..zoomAt(const Offset(0, 400), 4);
      const far = Offset(0.95, 0.5);
      expect(v.toLocal(far).dx, greaterThan(400));
      expect(v.ensureVisible(far), isTrue);
      final p = v.toLocal(far);
      expect(p.dx, lessThanOrEqualTo(400 - 32 + 1e-6));
      expect(v.ensureVisible(far), isFalse);
    });

    test('requested width follows zoom, capped by the display', () {
      final v = portrait();
      expect(v.wantedWidth(devicePixelRatio: 3, nativeWidth: 3456), 1200);
      v.zoomAt(const Offset(200, 400), 4);
      expect(v.wantedWidth(devicePixelRatio: 3, nativeWidth: 3456), 2560);
      expect(v.wantedWidth(devicePixelRatio: 3, nativeWidth: 1920), 1920);
    });
  });

  group('RemoteGestureRecognizer', () {
    late List<RemoteGesture> out;
    late RemoteGestureRecognizer g;
    setUp(() {
      out = [];
      g = RemoteGestureRecognizer(out.add);
    });

    test('tap is a left click where the finger went down', () {
      g.down(1, const Offset(10, 10), ms(0));
      g.move(1, const Offset(14, 12), ms(40));
      g.up(1, ms(80));
      expect(out.single, isA<RemoteClick>());
      final click = out.single as RemoteClick;
      expect((click.at, click.button), (const Offset(10, 10), 'left'));
      expect(g.active, isFalse);
    });

    test('double tap reuses the first position', () {
      g.down(1, const Offset(10, 10), ms(0));
      g.up(1, ms(60));
      g.down(2, const Offset(25, 20), ms(200));
      g.up(2, ms(260));
      expect(out.map((e) => (e as RemoteClick).at), [
        const Offset(10, 10),
        const Offset(10, 10),
      ]);
      g.down(3, const Offset(25, 20), ms(1000));
      g.up(3, ms(1060));
      expect((out.last as RemoteClick).at, const Offset(25, 20));
    });

    test('long press is a right click on release, ignoring later moves', () {
      g.down(1, const Offset(50, 60), ms(0));
      expect(g.longPressDue, ms(500));
      g.tick(ms(499));
      expect(out, isEmpty);
      g.tick(ms(500));
      expect(out.single, isA<RemoteHold>());
      g.move(1, const Offset(200, 200), ms(600));
      g.up(1, ms(700));
      expect(out.last, isA<RemoteClick>());
      expect((out.last as RemoteClick).button, 'right');
      expect((out.last as RemoteClick).at, const Offset(50, 60));
      expect(out.length, 2);
    });

    test('press, move, release is a left-button drag from the start', () {
      g.down(1, const Offset(10, 10), ms(0));
      g.move(1, const Offset(30, 10), ms(20));
      g.move(1, const Offset(60, 40), ms(40));
      g.down(2, const Offset(200, 200), ms(50)); // stray finger
      g.move(2, const Offset(260, 260), ms(55));
      g.up(2, ms(60));
      g.move(1, const Offset(70, 50), ms(70));
      g.up(1, ms(90));
      expect(out.map((e) => e.toString()), [
        'dragStart(Offset(10.0, 10.0))',
        'drag(Offset(30.0, 10.0))',
        'drag(Offset(60.0, 40.0))',
        'drag(Offset(70.0, 50.0))',
        'dragEnd(Offset(70.0, 50.0))',
      ]);
      expect(g.longPressDue, isNull);
    });

    test('pan mode moves the view instead of dragging', () {
      g.panMode = true;
      g.down(1, const Offset(10, 10), ms(0));
      g.move(1, const Offset(30, 10), ms(20));
      g.move(1, const Offset(35, 15), ms(40));
      g.up(1, ms(60));
      expect(out.map((e) => e.toString()), [
        'pan(Offset(20.0, 0.0))',
        'pan(Offset(5.0, 5.0))',
      ]);
    });

    test('two fingers moving together scroll the remote', () {
      g.down(1, const Offset(100, 100), ms(0));
      g.down(2, const Offset(200, 100), ms(10));
      g.move(1, const Offset(100, 80), ms(30));
      g.move(2, const Offset(200, 80), ms(31));
      g.move(1, const Offset(100, 60), ms(50));
      g.up(1, ms(70));
      g.up(2, ms(80));
      final scrolls = out.whereType<RemoteScroll>().toList();
      expect(scrolls, isNotEmpty);
      expect(out.whereType<RemoteZoom>(), isEmpty);
      final total = scrolls.fold(Offset.zero, (a, s) => a + s.delta);
      expectOffset(total, const Offset(0, -30));
      expect(out.whereType<RemoteClick>(), isEmpty);
    });

    test('pinch zooms about the focal point', () {
      g.down(1, const Offset(100, 100), ms(0));
      g.down(2, const Offset(200, 100), ms(10));
      g.move(1, const Offset(50, 100), ms(30));
      g.move(2, const Offset(250, 100), ms(40));
      g.up(1, ms(70));
      g.up(2, ms(80));
      final zooms = out.whereType<RemoteZoom>().toList();
      final factor = zooms.fold(1.0, (a, z) => a * z.factor);
      expect(factor, closeTo(2, 1e-9));
      expect(out.whereType<RemoteScroll>(), isEmpty);
      expect(out.whereType<RemoteDragStart>(), isEmpty);
    });

    test('two-finger tap is a right click; slow two-finger hold is not', () {
      g.down(1, const Offset(100, 100), ms(0));
      g.down(2, const Offset(140, 100), ms(20));
      g.up(1, ms(120));
      g.up(2, ms(130));
      expect(out.single.toString(), 'click(right, Offset(120.0, 100.0))');
      out.clear();
      g.down(1, const Offset(100, 100), ms(1000));
      g.down(2, const Offset(140, 100), ms(1020));
      g.up(1, ms(1600));
      g.up(2, ms(1610));
      expect(out, isEmpty);
    });

    test('cancel ends a drag without a click', () {
      g.down(1, const Offset(10, 10), ms(0));
      g.move(1, const Offset(40, 10), ms(20));
      g.cancel(1);
      expect(out.last, isA<RemoteDragEnd>());
      out.clear();
      g.down(1, const Offset(10, 10), ms(100));
      g.cancel(1);
      expect(out, isEmpty);
      expect(g.active, isFalse);
    });
  });

  group('RemoteInputQueue', () {
    test('one request in flight, moves coalesce, order is kept', () async {
      final sent = <List<Map<String, dynamic>>>[];
      final gates = <Completer<void>>[];
      final q = RemoteInputQueue((events) {
        sent.add(events);
        final gate = Completer<void>();
        gates.add(gate);
        return gate.future;
      });
      q.add({'kind': 'move', 'x': 1, 'y': 1});
      q.add({'kind': 'button', 'button': 'left', 'direction': 'press'});
      await Future<void>.delayed(Duration.zero);
      expect(sent.length, 1);
      expect(sent.single.length, 1); // the first event left immediately
      for (var i = 2; i < 10; i++) {
        q.add({'kind': 'move', 'x': i, 'y': i});
      }
      q.add({'kind': 'button', 'button': 'left', 'direction': 'release'});
      gates.last.complete();
      await Future<void>.delayed(Duration.zero);
      expect(sent.length, 2);
      expect(sent[1].map((e) => e['kind']), ['button', 'move', 'button']);
      expect(sent[1][1]['x'], 9);
      gates.last.complete();
      await q.idle;
      expect(q.sentRequests, 2);
      expect(q.sentEvents, 4);
    });

    test('scrolls add up and clamp; failure drops the rest', () async {
      final sent = <List<Map<String, dynamic>>>[];
      final gate = Completer<void>();
      Object? failure;
      final q = RemoteInputQueue((events) async {
        sent.add(events);
        if (sent.length == 1) return gate.future;
        throw StateError('lease ended');
      }, onError: (e) => failure = e);
      q.add({'kind': 'text', 'text': 'a'});
      for (var i = 0; i < 30; i++) {
        q.add({'kind': 'scroll', 'x': 0, 'y': 5});
      }
      gate.complete();
      await q.idle;
      expect(sent[1], [
        {'kind': 'scroll', 'x': 0, 'y': 100},
      ]);
      expect(failure, isA<StateError>());
      q.add({'kind': 'text', 'text': 'b'});
      await q.idle;
      expect(sent.length, 2);
    });

    test(
      'migration barrier drains only the current batch, preserves later input and resumes on the new route',
      () async {
        final gate = Completer<void>();
        final sent = <String>[];
        var route = 'old';
        final q = RemoteInputQueue((events) async {
          sent.add('$route:${events.first['kind']}');
          if (sent.length == 1) await gate.future;
        });
        q.add({'kind': 'button', 'direction': 'press'});
        final barrier = q.pause();
        var drained = false;
        barrier.then((_) => drained = true);
        q.add({'kind': 'move', 'x': 10, 'y': 10});
        q.add({'kind': 'move', 'x': 20, 'y': 20});
        q.add({'kind': 'button', 'direction': 'release'});
        var idle = false;
        q.idle.then((_) => idle = true);
        await Future<void>.delayed(Duration.zero);
        expect(drained, false);
        expect(sent, ['old:button']);
        gate.complete();
        expect(await barrier, true);
        expect(idle, false);
        route = 'new';
        q.resume();
        await q.idle;
        expect(sent, ['old:button', 'new:move']);
        expect(q.sentEvents, 3);
        expect(idle, true);
      },
    );
    test(
      'an uncertain or disposed input cannot cross the migration barrier',
      () async {
        for (final close in [false, true]) {
          final gate = Completer<void>();
          var sent = 0;
          final q = RemoteInputQueue((events) async {
            sent++;
            await gate.future;
          });
          q.add({'kind': 'button'});
          final barrier = q.pause();
          q.add({'kind': 'button'});
          if (close) {
            q.dispose();
            expect(await barrier, false);
            gate.complete();
          } else {
            gate.completeError(StateError('reply lost'));
            expect(await barrier, false);
          }
          q.resume();
          await q.idle;
          expect(sent, 1);
        }
      },
    );
    test(
      'canceling a pending migration invalidates its old input barrier',
      () async {
        final gate = Completer<void>();
        var sent = 0;
        final q = RemoteInputQueue((events) async {
          sent++;
          if (sent == 1) await gate.future;
        });
        q.add({'kind': 'move', 'x': 1, 'y': 1});
        final canceled = q.pause();
        q.add({'kind': 'button'});
        q.resume();
        expect(await canceled, false);
        final next = q.pause();
        gate.complete();
        expect(await next, true);
        expect(sent, 1);
        q.resume();
        await q.idle;
        expect(sent, 2);
      },
    );
    test('batches are bounded', () async {
      final sent = <int>[];
      final gate = Completer<void>();
      final q = RemoteInputQueue((events) {
        sent.add(events.length);
        return sent.length == 1 ? gate.future : Future.value();
      }, maxBatch: 3);
      for (var i = 0; i < 8; i++) {
        q.add({'kind': 'text', 'text': '$i'});
      }
      gate.complete();
      await q.idle;
      expect(sent, [1, 3, 3, 1]);
    });
  });

  group('FrameRateControl', () {
    test('clean replies double the rate at startup up to the cap', () {
      final c = FrameRateControl(maxFps: 20, initFps: 5);
      for (var i = 0; i < 8; i++) {
        c.onFrame(60);
      }
      expect(c.fps, 20);
      expect(c.nextDelay(ms(20)), ms(30));
      expect(c.nextDelay(ms(80)), Duration.zero);
    });

    test('one slow reply does nothing; confirmed congestion cuts quality '
        'first, then rate', () {
      final c = FrameRateControl(maxFps: 15, initFps: 15);
      c.onFrame(50);
      c.onFrame(400);
      c.onFrame(50);
      expect((c.fps, c.quality), (15, 60));
      for (var i = 0; i < 3; i++) {
        c.onFrame(400);
      }
      expect((c.fps, c.quality), (15, 50));
      for (var i = 0; i < 6; i++) {
        c.onFrame(400);
      }
      expect(c.quality, 35);
      for (var i = 0; i < 3; i++) {
        c.onFrame(400);
      }
      expect(c.fps, 12);
    });

    test('a second of excess halves at once and good replies restore', () {
      final c = FrameRateControl(maxFps: 16, initFps: 16);
      c.onFrame(40);
      c.onFrame(1200);
      expect(c.fps, 8);
      c.onFrame(40);
      c.onFrame(40);
      expect(c.fps, 16);
    });

    test('long good runs raise quality once the rate is at the cap', () {
      final c = FrameRateControl(maxFps: 10, initFps: 10);
      c.onFrame(40);
      for (var i = 0; i < 12; i++) {
        c.onFrame(45);
      }
      expect(c.quality, 70);
      expect(c.fps, 10);
    });
  });

  group('video stats', () {
    test('reads the inbound video stream and the selected pair', () {
      final t0 = DateTime(2026, 10, 21, 12);
      final a = parseVideoStats([
        ('inbound-rtp', {'kind': 'audio', 'bytesReceived': 999}),
        (
          'inbound-rtp',
          {
            'kind': 'video',
            'bytesReceived': 100000,
            'framesDecoded': 30,
            'packetsLost': 0,
            'frameWidth': 1920,
            'frameHeight': '1240',
          },
        ),
        (
          'candidate-pair',
          {
            'state': 'succeeded',
            'nominated': true,
            'currentRoundTripTime': 0.042,
          },
        ),
        (
          'candidate-pair',
          {'state': 'failed', 'nominated': false, 'currentRoundTripTime': 9},
        ),
      ], t0)!;
      expect((a.width, a.height, a.rttMs), (1920, 1240, 42.0));
      final b = parseVideoStats([
        (
          'inbound-rtp',
          {
            'mediaType': 'video',
            'bytesReceived': '304800',
            'framesDecoded': 60,
          },
        ),
      ], t0.add(const Duration(seconds: 2)))!;
      expect(b.kbps(a), closeTo(100, 0.01));
      expect(b.decodedFps(a), 15);
      expect(b.rttMs, isNull);
      expect(parseVideoStats([('track', {})], t0), isNull);
    });
  });
}
