/// One local deadline across all retry/warmup states in one desktop instance.
/// Server restarts or repeated status changes cannot extend it indefinitely.
class VideoRecovery {
  Object? _scope;
  Duration? _began;
  Object? _attempt, _confirmedAttempt;
  bool _wasChanging = false;
  bool get active => _began != null;
  static const deadline = Duration(seconds: 20);

  bool observe(
    dynamic raw,
    Duration now, {
    required Object scope,
    bool changing = false,
  }) {
    if (_scope != scope) {
      _scope = scope;
      _began = null;
      _attempt = _confirmedAttempt = null;
      _wasChanging = false;
    }
    final state = raw is Map ? raw['state'] : null;
    final pending = state == 'restarting' || state == 'warming' || changing;
    if (changing && !_wasChanging) _confirmedAttempt = null;
    _wasChanging = changing;
    if (pending) {
      final attempt = raw is Map ? raw['attempts'] ?? 0 : 0;
      _attempt = attempt;
      if (_confirmedAttempt != attempt) _began ??= now;
    }
    // A PC ready state proves sent output, not that this phone decoded it.
    // Preserve the same deadline until the caller observes decoder progress.
    return _began != null && now - _began! >= deadline;
  }

  void decoded() {
    if (_began == null) return;
    _confirmedAttempt = _attempt;
    _began = null;
  }
}
