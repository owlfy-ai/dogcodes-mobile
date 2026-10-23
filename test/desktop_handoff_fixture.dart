import 'dart:async';
import 'package:dogcodes_app/core/secure_host_client.dart';
import 'remote_desktop_widget_test.dart' show DesktopLink;
import 'relay_video_test.dart' show frame;

/// An isolated PC fixture shared by two separately owned physical links.
class HandoffBroker {
  late final old = HandoffLink(this, false), next = HandoffLink(this, true);
  int revision = 0, inputSequence = 0, frameSequence = 0, generation = 1;
  bool offered = false, staged = false, applied = false, retired = false;
  late HandoffLink owner = old;
  HandoffLink? stagedPeer;
  bool get claimed => !identical(owner, old);
  bool loseClaimReply = false,
      loseClaimBefore = false,
      raceCancel = false,
      loseOffer = false;
  bool statusUnavailable = false, cancelUnavailable = false;
  Completer<void>? claiming;
  final phases = <String>[];
  String? ticket;
  String transport = 'binary';
  String? targetTransport;
  Completer<void>? codecGate;
  int movedWidth = 640, movedHeight = 400;
  Map<String, dynamic> get video => {
    'codec': 'h264',
    'transport': staged && !applied ? targetTransport ?? transport : transport,
    'profile':
        (staged && !applied ? targetTransport ?? transport : transport) ==
            'webrtc'
        ? 'cb31'
        : 'cb-auto',
    'switchingCodec': staged && !applied && targetTransport != transport,
    'codecReady': !applied || codecGate == null || codecGate!.isCompleted,
    'width': applied ? movedWidth : 640,
    'height': applied ? movedHeight : 400,
    'generation': generation,
    'clientReadyRequired': transport == 'binary' || applied,
    'resize': {
      'instanceId': 'video-one',
      'applied': '0',
      'requested': '0',
      'targetWidth': 480,
      'maxWidth': 1280,
      'state': 'ready',
    },
  };
  Map<String, dynamic> snapshot(HandoffLink link, [String? state]) => {
    'state':
        state ??
        (applied
            ? 'applied'
            : retired
            ? 'retired'
            : staged
            ? 'staged'
            : 'offered'),
    'owner': identical(link, owner),
    'leaseId': 'lease',
    'monitorId': 1,
    'inputSequence': '$inputSequence',
    'inputBatch': 64,
    'revision': '$revision',
    'video': video,
  };
  Future<dynamic> handoff(HandoffLink link, Map args) async {
    final phase = args['phase'] as String;
    phases.add('${link.candidate ? 'new' : 'old'}:$phase');
    if (phase == 'offer') {
      if (loseOffer) throw const RemoteOutcomeUnknown();
      if (args['expectedRevision'] != '$revision') {
        throw StateError('stale revision');
      }
      if (!identical(link, owner)) throw StateError('old owner');
      offered = true;
      staged = false;
      applied = false;
      retired = false;
      ticket = args['ticket'] as String;
      revision++;
    } else if (phase == 'stage') {
      if (!offered || ticket != args['ticket']) {
        throw StateError('missing offer');
      }
      staged = true;
      stagedPeer = link;
      targetTransport = args['videoTransport'] as String? ?? transport;
    } else if (phase == 'claim') {
      await claiming?.future;
      if (args['expectedInputSequence'] != '$inputSequence') {
        throw StateError('unconfirmed input');
      }
      if (loseClaimBefore) throw const RemoteOutcomeUnknown();
      if (!identical(link, stagedPeer)) throw StateError('not staged');
      owner = link;
      transport = targetTransport ?? transport;
      applied = true;
      generation++;
      if (loseClaimReply) throw const RemoteOutcomeUnknown();
    } else if (phase == 'cancel') {
      if (cancelUnavailable) throw const RemoteOutcomeUnknown();
      if (raceCancel && !applied) {
        owner = stagedPeer!;
        transport = targetTransport ?? transport;
        applied = true;
        generation++;
      }
      if (!applied) {
        retired = true;
        offered = staged = false;
        if (args['expectedRevision'] == '$revision') revision++;
      }
    } else if (phase == 'status' && statusUnavailable) {
      throw const RemoteOutcomeUnknown();
    }
    return snapshot(link, phase == 'cancel' && !applied ? 'canceled' : null);
  }

  void dropOld() {
    old.disconnected = true;
    old.pushed.add({'type': 'disconnected'});
  }
}

class HandoffLink extends DesktopLink {
  HandoffLink(this.broker, this.candidate) {
    relayVideo = true;
  }
  final HandoffBroker broker;
  final bool candidate;
  int closes = 0;
  bool disconnected = false;
  Completer<void>? inputGate;
  @override
  Future<void> close() async {
    closes++;
    disconnected = true;
  }

  @override
  Future<dynamic> call(String method, dynamic args) async {
    if (disconnected) throw const RemoteOutcomeUnknown();
    if (method == 'transport_status') {
      return {
        'route': {'mode': 'direct'},
      };
    }
    if (method == 'remote_desktop_handoff') {
      return broker.handoff(this, args as Map);
    }
    if (method == 'remote_desktop_open') {
      final result = await super.call(method, args);
      result['handoff'] = true;
      result['handoffRevision'] = '${broker.revision}';
      if (args['videoTransport'] == 'binary' ||
          (broker.transport == 'webrtc' && args['video'] == true)) {
        result['video'] = broker.video;
      }
      return result;
    }
    if (method == 'remote_desktop_video') {
      if (!identical(this, broker.owner)) {
        throw StateError('lease belongs to other physical owner');
      }
      controls.add(Map<String, dynamic>.from(args as Map));
      if (args['ready'] == true) {
        if (broker.transport == 'webrtc') {
          return {
            'frames': ++broker.frameSequence,
            'video': {...broker.video, 'ready': true},
          };
        }

        pushed.add({
          ...frame(++broker.frameSequence, key: true),
          'leaseId': 'lease',
          'generation': broker.generation,
        });
        return {
          'relay': {'ready': true, 'generation': broker.generation},
        };
      }
      return {
        'video': broker.video,
        'frames': broker.frameSequence,
        'handoffRevision': '${broker.revision}',
      };
    }
    if (method == 'remote_desktop_input') {
      if (!identical(this, broker.owner)) throw StateError('old owner');
      if (int.parse('${args['sequence']}') != broker.inputSequence + 1) {
        throw StateError('input replay');
      }
      broker.inputSequence++;
      final gate = inputGate;
      inputGate = null;
      await gate?.future;
      return super.call(method, args);
    }
    return super.call(method, args);
  }
}
