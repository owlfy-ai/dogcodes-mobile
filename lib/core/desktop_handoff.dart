import 'host_api.dart';
import 'pc_api.dart';

class DesktopHandoffUnknown implements Exception {
  const DesktopHandoffUnknown();
}

class DesktopHandoffResult {
  const DesktopHandoffResult(this.moved, this.snapshot);
  final bool moved;
  final Map<String, dynamic> snapshot;
}

/// One ephemeral PC lease transfer. Offer, stage and claim are sent once;
/// unknown claim outcomes are read back or fenced, never replayed.
class DesktopHandoff {
  DesktopHandoff({
    required this.source,
    required this.candidate,
    required this.lease,
    required this.revision,
    this.transport = 'binary',
  }) : ticket = uuid() {
    if (identical(source, candidate) || source.hostId != candidate.hostId) {
      throw const DesktopHandoffUnknown();
    }
  }
  final HostLink source, candidate;
  final String lease, ticket, revision, transport;
  int? _sequence;
  bool started = false, _claimed = false;
  Map<String, dynamic>? staged;
  Map<String, dynamic> _args(String phase) => {
    'leaseId': lease,
    'ticket': ticket,
    'phase': phase,
    'expectedRevision': revision,
  };
  Future<Map<String, dynamic>> _call(
    HostLink link,
    String phase, {
    Map<String, dynamic> extra = const {},
  }) async {
    final reply = await withReplyTimeout(
      const Duration(seconds: 3),
      () => link.call('remote_desktop_handoff', {..._args(phase), ...extra}),
    ).timeout(const Duration(seconds: 3));
    checkDesktopAuthorization(reply);
    if (reply is! Map ||
        reply['leaseId'] != lease ||
        reply['owner'] is! bool ||
        int.tryParse('${reply['revision']}') == null) {
      throw const DesktopHandoffUnknown();
    }
    return Map<String, dynamic>.from(reply);
  }

  Future<Map<String, dynamic>> prepare() async {
    if (started) throw const DesktopHandoffUnknown();
    started = true;
    final offered = await _call(source, 'offer');
    if (offered['state'] != 'offered' || offered['owner'] != true) {
      throw const DesktopHandoffUnknown();
    }
    final reply = await _call(
      candidate,
      'stage',
      extra: {'chunkedMessages': true, 'videoTransport': transport},
    );
    if (reply['state'] != 'staged' ||
        reply['owner'] != false ||
        reply['video'] is! Map) {
      throw const DesktopHandoffUnknown();
    }
    staged = reply;
    return reply;
  }

  DesktopHandoffResult? _moved(Map<String, dynamic> value) {
    if (value['owner'] != true ||
        !['applied', 'retired'].contains(value['state']) ||
        _sequence == null) {
      return null;
    }
    if (int.tryParse('${value['inputSequence']}') != _sequence) {
      throw const DesktopHandoffUnknown();
    }
    final expected = staged?['video'], video = value['video'];
    if (expected is! Map ||
        video is! Map ||
        video['codec'] != 'h264' ||
        video['transport'] != transport ||
        (expected['switchingCodec'] != true &&
            (video['width'] != expected['width'] ||
                video['height'] != expected['height'])) ||
        (expected['profile'] != null &&
            video['profile'] != expected['profile']) ||
        video['resize'] is! Map ||
        expected['resize'] is! Map ||
        video['resize']['instanceId'] != expected['resize']['instanceId'] ||
        video['resize']['applied'] != expected['resize']['applied'] ||
        video['generation'] is! int ||
        expected['generation'] is! int ||
        (video['generation'] as int) <= (expected['generation'] as int) ||
        video['clientReadyRequired'] != true) {
      throw const DesktopHandoffUnknown();
    }
    return DesktopHandoffResult(true, value);
  }

  bool _fenced(Map<String, dynamic> value) {
    final known =
        value['owner'] == true &&
        ['canceled', 'retired'].contains(value['state']) &&
        int.parse('${value['revision']}') > int.parse(revision);
    if (known &&
        _sequence != null &&
        int.tryParse('${value['inputSequence']}') != _sequence) {
      throw const DesktopHandoffUnknown();
    }
    return known;
  }

  Future<DesktopHandoffResult> claim(int sequence) async {
    if (_claimed || staged == null) throw const DesktopHandoffUnknown();
    _claimed = true;
    _sequence = sequence;
    try {
      final result = _moved(
        await _call(
          candidate,
          'claim',
          extra: {'expectedInputSequence': '$sequence'},
        ),
      );
      if (result != null) return result;
    } on DesktopAuthorizationEnded {
      rethrow;
    } catch (_) {
      /* Read/fence the original identity below. */
    }
    try {
      final result = _moved(await _call(candidate, 'status'));
      if (result != null) return result;
    } on DesktopAuthorizationEnded {
      rethrow;
    } catch (_) {
      /* A staged snapshot alone is not a rejection. */
    }
    return abandon();
  }

  Future<DesktopHandoffResult> abandon() async {
    // Cancel via old owner also fences an offer still queued before admission.
    try {
      final value = await _call(source, 'cancel');
      if (_fenced(value)) return DesktopHandoffResult(false, value);
    } on DesktopAuthorizationEnded {
      rethrow;
    } catch (_) {
      /* New owner may already have replaced it. */
    }
    try {
      final value = await _call(candidate, 'cancel');
      final moved = _moved(value);
      if (moved != null) return moved;
      final original = await _call(source, 'status');
      if (_fenced(original)) return DesktopHandoffResult(false, original);
    } on DesktopAuthorizationEnded {
      rethrow;
    } catch (_) {
      /* No proof: caller must end both physical links. */
    }
    throw const DesktopHandoffUnknown();
  }
}
