import 'dart:async';
import 'dart:typed_data';

/// Relay video, phone side: the PC pushes numbered H.264 access units as
/// binary messages; this hands them to the decoder one at a time, in order,
/// and acknowledges the newest one handed over. The PC keeps at most a few
/// frames unacknowledged and paces its bitrate on how long acks take (the
/// RustDesk video-received loop), so acks go out promptly but coalesced, at
/// most one in flight.
///
/// After a decode error, or when the decoder falls behind, deltas are
/// skipped (still acknowledged) until a keyframe, which is requested.
class RelayVideoReceiver {
  RelayVideoReceiver({
    required this.decode,
    required this.control,
    this.onLiveChanged,
    this.ackInterval = const Duration(milliseconds: 100),
    this.maxBacklog = 6,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// Throws when the decoder cannot continue without a keyframe.
  final Future<void> Function(Uint8List data, bool keyframe) decode;

  /// `remote_desktop_video` with a cumulative ack and/or a keyframe request.
  final Future<void> Function({int? ack, bool keyframe}) control;

  /// Reference loss freezes input immediately; only decoded IDR output can
  /// restore it. Ordinary transport/PC status cannot prove a live picture.
  final void Function(bool live)? onLiveChanged;
  final Duration ackInterval;
  final int maxBacklog;
  final DateTime Function() _now;

  final _queue = <({int seq, bool key, Uint8List data})>[];
  bool _decoding = false, _needKey = true, _disposed = false;
  // The stream opens with an IDR; a keyframe is requested only on trouble.
  bool _ackInFlight = false, _keyPending = false;
  int _decodedSeq = 0, _ackedSeq = 0;
  int _referenceEpoch = 0;
  int _failures = 0;
  DateTime _lastAck = DateTime(0), _lastKeyRequest = DateTime(0);
  DateTime _retryAt = DateTime(0);
  Timer? _ackTimer;

  int decoded = 0, skipped = 0, bytes = 0;

  /// Whether the picture is current (a keyframe has been decoded since the
  /// last error).
  bool get live => !_needKey;

  void onFrame(Map<String, dynamic> event) {
    if (_disposed) return;
    final seq = (event['seq'] as num?)?.toInt();
    final data = event['payload'];
    if (seq == null || data is! Uint8List) return;
    bytes += data.length;
    _queue.add((seq: seq, key: event['key'] == true, data: data));
    if (_queue.length > maxBacklog) {
      // Decoding cannot keep up: keep only from the newest keyframe on.
      final lastKey = _queue.lastIndexWhere((f) => f.key);
      final drop = lastKey > 0 ? lastKey : _queue.length - 1;
      for (final f in _queue.take(drop)) {
        _decodedSeq = f.seq > _decodedSeq ? f.seq : _decodedSeq;
      }
      skipped += drop;
      _queue.removeRange(0, drop);
      if (lastKey <= 0) {
        _wantKey();
      } else {
        // The queued IDR can recover without requesting another one, but
        // an older in-flight frame cannot restore references we just dropped.
        _referenceEpoch++;
        _setNeedKey(true);
      }
      _scheduleAck();
    }
    unawaited(_pump());
  }

  Future<void> _pump() async {
    if (_decoding) return;
    _decoding = true;
    try {
      while (_queue.isNotEmpty && !_disposed) {
        final f = _queue.removeAt(0);
        var failed = false;
        if (_needKey && !f.key) {
          skipped++;
        } else {
          try {
            final references = _referenceEpoch;
            await decode(f.data, f.key);
            decoded++;
            if (f.key && references == _referenceEpoch) _setNeedKey(false);
          } catch (_) {
            failed = true;
          }
        }
        // Record the frame first, so a keyframe request rides on its ack.
        if (f.seq > _decodedSeq) _decodedSeq = f.seq;
        if (failed) _wantKey();
        _scheduleAck();
      }
    } finally {
      _decoding = false;
    }
  }

  void _wantKey() {
    _referenceEpoch++;
    _setNeedKey(true);
    _keyPending = true;
    _scheduleAck();
  }

  void _setNeedKey(bool value) {
    if (_needKey == value) return;
    _needKey = value;
    if (!_disposed) onLiveChanged?.call(!value);
  }

  void _scheduleAck() {
    if (_disposed || _ackInFlight || _ackTimer != null) return;
    var at = _lastAck.add(ackInterval);
    if (_retryAt.isAfter(at)) at = _retryAt;
    if (_decodedSeq <= _ackedSeq && _keyPending) {
      final keyAt = _lastKeyRequest.add(const Duration(milliseconds: 500));
      if (keyAt.isAfter(at)) at = keyAt;
    }
    final due = at.difference(_now());
    if (due <= Duration.zero) {
      _sendAck();
    } else {
      _ackTimer = Timer(due, () {
        _ackTimer = null;
        _sendAck();
      });
    }
  }

  void _sendAck() {
    if (_disposed || _ackInFlight) return;
    final now = _now();
    // A keyframe request at most every half second: the PC answers within
    // a frame, and the request rides on the ack.
    final key =
        _keyPending &&
        now.difference(_lastKeyRequest) >= const Duration(milliseconds: 500);
    final ack = _decodedSeq > _ackedSeq ? _decodedSeq : null;
    if (ack == null && !key) return;
    _ackInFlight = true;
    _lastAck = now;
    if (key) {
      _keyPending = false;
      _lastKeyRequest = now;
    }
    control(ack: ack, keyframe: key)
        .then<void>(
          (_) {
            if (ack != null && ack > _ackedSeq) _ackedSeq = ack;
            _failures = 0;
            _retryAt = DateTime(0);
          },
          onError: (Object _) {
            // Cumulative ACKs are idempotent, even if the reply was lost.
            // Keep the original high-water mark pending when no new frame
            // can arrive because the PC's unacknowledged window is full.
            _failures = (_failures + 1).clamp(1, 5);
            _retryAt = _now().add(
              Duration(milliseconds: 100 * (1 << _failures)),
            );
            if (key) _keyPending = true;
          },
        )
        .whenComplete(() {
          _ackInFlight = false;
          if (_decodedSeq > _ackedSeq || (_keyPending && _needKey)) {
            _scheduleAck();
          }
        });
  }

  void dispose() {
    _disposed = true;
    _ackTimer?.cancel();
    _queue.clear();
  }
}
