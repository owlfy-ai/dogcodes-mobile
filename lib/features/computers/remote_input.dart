import 'dart:async';

/// Sends remote input in order with one request in flight. Events queued
/// while a request is out go together in the next one; a newer pointer
/// position replaces an older queued one, and queued scrolls add up, so a
/// slow link delivers the latest state instead of a growing backlog.
///
/// The PC numbers input per request and refuses anything out of order, so
/// overlapping requests (which its worker may run in either order) would end
/// the session; serialising here is what keeps a fast drag valid.
class RemoteInputQueue {
  RemoteInputQueue(this.send, {this.maxBatch = 32, this.onError});

  /// Delivers one ordered batch. A PC without batch support gets lists of
  /// length one ([maxBatch] = 1).
  final Future<void> Function(List<Map<String, dynamic>> events) send;
  final int maxBatch;
  final void Function(Object error)? onError;

  final _queue = <Map<String, dynamic>>[];
  bool _sending = false, _failed = false, _paused = false;
  Completer<void>? _idle;
  Completer<bool>? _barrier;
  int sentRequests = 0, sentEvents = 0;
  bool _viewReady = true;
  final _held = <String, Map<String, dynamic>>{};

  bool get busy => _sending || _queue.isNotEmpty;

  /// Completes once everything queued so far has been answered.
  Future<void> get idle {
    if (!busy) return Future.value();
    return (_idle ??= Completer<void>()).future;
  }

  /// Stop starting batches and wait only for the one already on the wire.
  /// Newly arriving touches remain queued/coalesced for the *same* lease.
  /// False means its result is unknown or the queue was disposed; a caller
  /// must not promote a new connection or replay the old batch in that case.
  Future<bool> pause() {
    _paused = true;
    if (_failed) return Future.value(false);
    if (!_sending) return Future.value(true);
    return (_barrier ??= Completer<bool>()).future;
  }

  void resume() {
    if (_failed) return;
    // Aborting a migration before its in-flight input settles must invalidate
    // that waiter; a later completed batch cannot revive the canceled claim.
    _barrier?.complete(false);
    _barrier = null;
    _paused = false;
    unawaited(_pump());
  }

  static bool _release(Map<String, dynamic> event) =>
      (event['kind'] == 'key' || event['kind'] == 'button') &&
      event['direction'] == 'release';
  static String _identity(Map<String, dynamic> event) =>
      '${event['kind']}:${event['key'] ?? event['button']}';

  /// A stale picture cannot queue new intent for replay after recovery. Keep
  /// releases, and release keys/buttons this queue has already sent or has on
  /// the wire; the existing request still settles in its original sequence.
  void setViewReady(bool ready) {
    if (_failed || _viewReady == ready) return;
    _viewReady = ready;
    if (!ready) {
      _queue.removeWhere(
        (event) => !_release(event) || !_held.containsKey(_identity(event)),
      );
      final releases = _queue.map(_identity).toSet();
      for (final entry in _held.entries) {
        if (releases.add(entry.key)) _queue.add(Map.of(entry.value));
      }
    }
    if (!_sending && _queue.isEmpty) {
      _idle?.complete();
      _idle = null;
    }
    unawaited(_pump());
  }

  void add(Map<String, dynamic> event) {
    if (_failed ||
        (!_viewReady &&
            (!_release(event) || !_held.containsKey(_identity(event))))) {
      return;
    }
    final last = _queue.isEmpty ? null : _queue.last;
    final kind = event['kind'];
    if (last != null && last['kind'] == kind && kind == 'move') {
      _queue[_queue.length - 1] = event;
    } else if (last != null && last['kind'] == kind && kind == 'scroll') {
      int sum(String axis) =>
          ((last[axis] as int) + (event[axis] as int)).clamp(-100, 100);
      _queue[_queue.length - 1] = {
        'kind': 'scroll',
        'x': sum('x'),
        'y': sum('y'),
      };
    } else {
      _queue.add(event);
    }
    unawaited(_pump());
  }

  void addAll(Iterable<Map<String, dynamic>> events) => events.forEach(add);

  /// Pending touches belong to the old lease. Never deliver them to its
  /// replacement after a disconnect, background transition or screen close.
  void dispose() {
    _failed = true;
    _queue.clear();
    _idle?.complete();
    _idle = null;
    _barrier?.complete(false);
    _barrier = null;
  }

  Future<void> _pump() async {
    if (_sending || _paused || _failed) return;
    _sending = true;
    try {
      while (_queue.isNotEmpty && !_failed && !_paused) {
        final n = _queue.length < maxBatch ? _queue.length : maxBatch;
        final batch = List<Map<String, dynamic>>.of(_queue.take(n));
        _queue.removeRange(0, n);
        try {
          for (final event in batch) {
            if (event['kind'] != 'key' && event['kind'] != 'button') continue;
            final id = _identity(event);
            if (event['direction'] == 'press') {
              _held[id] = {...event, 'direction': 'release'};
            } else if (event['direction'] == 'release') {
              _held.remove(id);
            }
          }
          await send(batch);
          sentRequests++;
          sentEvents += batch.length;
        } catch (e) {
          // The PC ends the lease on a failed input; later events cannot apply.
          _failed = true;
          _queue.clear();
          onError?.call(e);
        }
      }
    } finally {
      _sending = false;
      _barrier?.complete(!_failed);
      _barrier = null;
      if (_queue.isEmpty || _failed) {
        final idle = _idle;
        _idle = null;
        idle?.complete();
      }
    }
  }
}
