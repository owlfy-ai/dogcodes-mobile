import 'dart:ui';

/// What a touch sequence means on the remote screen. Positions are in view
/// coordinates; the page maps them through `RemoteViewport`.
sealed class RemoteGesture {
  const RemoteGesture();
}

/// Tap → left click; long-press or two-finger tap → right click.
class RemoteClick extends RemoteGesture {
  const RemoteClick(this.at, {this.button = 'left'});
  final Offset at;
  final String button;
  @override
  String toString() => 'click($button, $at)';
}

/// One-finger press, move, release: left button held for the whole drag
/// (select text, move windows, drag files).
class RemoteDragStart extends RemoteGesture {
  const RemoteDragStart(this.at);
  final Offset at;
  @override
  String toString() => 'dragStart($at)';
}

class RemoteDragUpdate extends RemoteGesture {
  const RemoteDragUpdate(this.at);
  final Offset at;
  @override
  String toString() => 'drag($at)';
}

class RemoteDragEnd extends RemoteGesture {
  const RemoteDragEnd(this.at);
  final Offset at;
  @override
  String toString() => 'dragEnd($at)';
}

/// Two fingers moving together: remote scroll by the finger movement.
class RemoteScroll extends RemoteGesture {
  const RemoteScroll(this.at, this.delta);

  /// Between the fingers: the remote pointer goes here so the window under
  /// the fingers is the one that scrolls.
  final Offset at;
  final Offset delta;
  @override
  String toString() => 'scroll($delta)';
}

/// Pinch: local zoom about [focal], plus the focal point's own movement.
class RemoteZoom extends RemoteGesture {
  const RemoteZoom(this.focal, this.factor, this.pan);
  final Offset focal;
  final double factor;
  final Offset pan;
  @override
  String toString() => 'zoom($focal, $factor, $pan)';
}

/// Moves the local view only (pan mode, one finger).
class RemotePan extends RemoteGesture {
  const RemotePan(this.delta);
  final Offset delta;
  @override
  String toString() => 'pan($delta)';
}

/// Long press feedback moment (haptics); the right click follows on release.
class RemoteHold extends RemoteGesture {
  const RemoteHold(this.at);
  final Offset at;
  @override
  String toString() => 'hold($at)';
}

enum _Phase {
  idle,
  pending,
  dragging,
  panning,
  held,
  twoPending,
  scrolling,
  zooming,
  done,
}

/// Raw-pointer state machine for remote control, after RustDesk's touch mode:
/// one finger is the mouse (tap, long-press, drag), two fingers either scroll
/// the remote or pinch the local view, decided by whichever moves first past
/// its threshold. Time is passed in, so tests drive it without timers; the
/// page calls [tick] when [longPressDue] arrives.
class RemoteGestureRecognizer {
  RemoteGestureRecognizer(this.emit);
  final void Function(RemoteGesture) emit;

  /// One finger pans the view instead of dragging on the remote.
  bool panMode = false;

  static const slop = 10.0;
  static const pinchSlop = 24.0;
  static const longPress = Duration(milliseconds: 500);
  static const twoFingerTap = Duration(milliseconds: 300);
  static const doubleTap = Duration(milliseconds: 350);
  static const doubleTapDistance = 32.0;

  final _points = <int, Offset>{};
  _Phase _phase = _Phase.idle;
  int? _primary;
  Offset _start = Offset.zero, _last = Offset.zero;
  Duration _startTime = Duration.zero;
  double _distance = 0, _startDistance = 0;
  Offset _centroid = Offset.zero, _startCentroid = Offset.zero;
  Offset? _lastTap;
  Duration _lastTapTime = Duration.zero;

  bool get active => _phase != _Phase.idle;

  /// When the current single press becomes a long press, if it still can.
  Duration? get longPressDue =>
      _phase == _Phase.pending ? _startTime + longPress : null;

  void down(int id, Offset at, Duration time) {
    _points[id] = at;
    switch (_phase) {
      case _Phase.idle:
        _phase = _Phase.pending;
        _primary = id;
        _start = _last = at;
        _startTime = time;
      case _Phase.pending:
        _phase = _Phase.twoPending;
        _startTime = time;
        _measure();
        _startDistance = _distance;
        _startCentroid = _centroid;
      default:
        // A finger joining a drag, scroll or pinch does not change it.
        break;
    }
  }

  void move(int id, Offset at, Duration time) {
    if (!_points.containsKey(id)) return;
    _points[id] = at;
    switch (_phase) {
      case _Phase.pending:
        if ((at - _start).distance <= slop) return;
        if (panMode) {
          _phase = _Phase.panning;
          emit(RemotePan(at - _start));
        } else {
          _phase = _Phase.dragging;
          emit(RemoteDragStart(_start));
          emit(RemoteDragUpdate(at));
        }
        _last = at;
      case _Phase.dragging when id == _primary:
        _last = at;
        emit(RemoteDragUpdate(at));
      case _Phase.panning when id == _primary:
        emit(RemotePan(at - _last));
        _last = at;
      case _Phase.twoPending:
        _measure();
        if ((_distance - _startDistance).abs() > pinchSlop) {
          _phase = _Phase.zooming;
          emit(
            RemoteZoom(
              _centroid,
              _startDistance > 0 ? _distance / _startDistance : 1,
              _centroid - _startCentroid,
            ),
          );
        } else if ((_centroid - _startCentroid).distance > slop) {
          _phase = _Phase.scrolling;
          emit(RemoteScroll(_startCentroid, _centroid - _startCentroid));
        }
      case _Phase.zooming:
        final (centroid, distance) = (_centroid, _distance);
        _measure();
        emit(
          RemoteZoom(
            _centroid,
            distance > 0 ? _distance / distance : 1,
            _centroid - centroid,
          ),
        );
      case _Phase.scrolling:
        final centroid = _centroid;
        _measure();
        emit(RemoteScroll(_centroid, _centroid - centroid));
      default:
        break;
    }
  }

  void up(int id, Duration time) => _lift(id, time, cancelled: false);

  void cancel(int id) => _lift(id, Duration.zero, cancelled: true);

  void tick(Duration time) {
    if (_phase != _Phase.pending || time - _startTime < longPress) return;
    _phase = _Phase.held;
    emit(RemoteHold(_start));
  }

  void _lift(int id, Duration time, {required bool cancelled}) {
    if (_points.remove(id) == null) return;
    final onePointer = const {
      _Phase.dragging,
      _Phase.panning,
      _Phase.held,
    }.contains(_phase);
    // A stray extra finger leaving does not end the primary finger's gesture.
    if (onePointer && id != _primary) return;
    switch (_phase) {
      case _Phase.pending:
        if (!cancelled) _tap(time);
      case _Phase.held:
        if (!cancelled) emit(RemoteClick(_start, button: 'right'));
      case _Phase.dragging:
        emit(RemoteDragEnd(_last));
      case _Phase.twoPending:
        if (!cancelled && time - _startTime <= twoFingerTap) {
          emit(RemoteClick(_startCentroid, button: 'right'));
        }
      default:
        break;
    }
    if (_phase != _Phase.idle) _phase = _Phase.done;
    if (_points.isEmpty) {
      _phase = _Phase.idle;
      _primary = null;
    }
  }

  /// A second tap close in time and place reuses the first position, so the
  /// PC sees a double click on one spot despite finger jitter.
  void _tap(Duration time) {
    final previous = _lastTap;
    final at =
        previous != null &&
            time - _lastTapTime <= doubleTap &&
            (previous - _start).distance <= doubleTapDistance
        ? previous
        : _start;
    _lastTap = at;
    _lastTapTime = time;
    emit(RemoteClick(at));
  }

  void _measure() {
    final two = _points.values.take(2).toList();
    if (two.length < 2) return;
    _centroid = (two[0] + two[1]) / 2;
    _distance = (two[0] - two[1]).distance;
  }
}
