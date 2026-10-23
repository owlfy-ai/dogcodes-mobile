import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/core/desktop_handoff.dart';
import 'desktop_handoff_fixture.dart';

class WrongProfileLink extends HandoffLink {
  WrongProfileLink(HandoffBroker broker) : super(broker, true);
  @override
  Future<dynamic> call(String method, dynamic args) async {
    final result = await super.call(method, args);
    if (method == 'remote_desktop_handoff' &&
        result is Map &&
        result['owner'] == true &&
        result['state'] == 'applied') {
      return {
        ...result,
        'video': {...result['video'] as Map, 'profile': 'cb-auto'},
      };
    }
    return result;
  }
}

void main() {
  for (final scenario in [
    'normal',
    'reply lost',
    'not admitted',
    'cancel race',
  ]) {
    test('claim once and reconcile $scenario', () async {
      final pc = HandoffBroker()
        ..loseClaimReply = scenario == 'reply lost'
        ..loseClaimBefore =
            scenario == 'not admitted' || scenario == 'cancel race'
        ..raceCancel = scenario == 'cancel race';
      final transfer = DesktopHandoff(
        source: pc.old,
        candidate: pc.next,
        lease: 'lease',
        revision: '0',
      );
      await transfer.prepare();
      final result = await transfer.claim(0);
      expect(result.moved, scenario != 'not admitted');
      expect(pc.phases.where((p) => p == 'new:claim').length, 1);
      expect(pc.revision, 1);
      await expectLater(
        transfer.claim(0),
        throwsA(isA<DesktopHandoffUnknown>()),
      );
      expect(pc.phases.where((p) => p == 'new:claim').length, 1);
    });
  }
  test(
    'unknown offer cancellation fences its frozen original version',
    () async {
      final pc = HandoffBroker()..loseOffer = true;
      final transfer = DesktopHandoff(
        source: pc.old,
        candidate: pc.next,
        lease: 'lease',
        revision: '0',
      );
      await expectLater(transfer.prepare(), throwsA(anything));
      final result = await transfer.abandon();
      expect(result.moved, false);
      expect(result.snapshot['revision'], '1');
      expect(pc.phases, ['old:offer', 'old:cancel']);
    },
  );
  test(
    'unknown owner is never resolved by replaying claim or sending input',
    () async {
      final pc = HandoffBroker()
        ..loseClaimBefore = true
        ..statusUnavailable = true
        ..cancelUnavailable = true;
      final transfer = DesktopHandoff(
        source: pc.old,
        candidate: pc.next,
        lease: 'lease',
        revision: '0',
      );
      await transfer.prepare();
      await expectLater(
        transfer.claim(0),
        throwsA(isA<DesktopHandoffUnknown>()),
      );
      expect(pc.phases.where((p) => p == 'new:claim').length, 1);
      expect(pc.inputSequence, 0);
    },
  );
  test(
    'prepared decoder cannot adopt a mismatched acknowledged input sequence',
    () async {
      final pc = HandoffBroker();
      final transfer = DesktopHandoff(
        source: pc.old,
        candidate: pc.next,
        lease: 'lease',
        revision: '0',
      );
      await transfer.prepare();
      pc.inputSequence = 3;
      await expectLater(
        transfer.claim(0),
        throwsA(isA<DesktopHandoffUnknown>()),
      );
      expect(pc.claimed, false);
    },
  );
  for (final target in ['binary', 'webrtc']) {
    test(
      'mixed codec $target preserves the source and acknowledged sequence while geometry changes',
      () async {
        final pc = HandoffBroker()
          ..transport = target == 'binary' ? 'webrtc' : 'binary'
          ..codecGate = Completer<void>()
          ..movedWidth = 960
          ..movedHeight = 600;
        final transfer = DesktopHandoff(
          source: pc.old,
          candidate: pc.next,
          lease: 'lease',
          revision: '0',
          transport: target,
        );
        final stage = await transfer.prepare();
        expect(stage['video']['switchingCodec'], true);
        final result = await transfer.claim(0);
        expect(result.moved, true);
        expect(result.snapshot['video']['codecReady'], false);
        expect(result.snapshot['video']['width'], 960);
        expect(result.snapshot['video']['transport'], target);
        expect(result.snapshot['video']['resize']['instanceId'], 'video-one');
        expect(pc.inputSequence, 0);
        expect(pc.phases.where((p) => p == 'new:claim').length, 1);
      },
    );
  }
  test(
    'a claimed owner cannot be adopted with a profile different from the staged RTP budget',
    () async {
      final pc = HandoffBroker();
      final transfer = DesktopHandoff(
        source: pc.old,
        candidate: WrongProfileLink(pc),
        lease: 'lease',
        revision: '0',
        transport: 'webrtc',
      );
      await transfer.prepare();
      await expectLater(
        transfer.claim(0),
        throwsA(isA<DesktopHandoffUnknown>()),
      );
      expect(pc.claimed, true);
      expect(pc.phases.where((p) => p == 'new:claim').length, 1);
      expect(pc.inputSequence, 0);
    },
  );
}
