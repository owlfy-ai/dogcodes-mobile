import 'dart:collection';
import 'dart:math' as math;

/// Picks frame rate and JPEG quality from frame round trips, after RustDesk's
/// video QoS (server/video_qos.rs): the delay above the best recent delay
/// says how much is queued in front of the frames. Two clean replies double
/// the rate at startup; three in a row above [badExcessMs] confirm congestion
/// and lower quality first (fewer bytes per frame), then the rate by a fifth;
/// a full second of excess halves the rate at once. Good replies climb back,
/// returning to the level held before congestion after two of them.
class FrameRateControl {
  FrameRateControl({
    this.maxFps = 15,
    this.minFps = 2,
    double initFps = 8,
    this.minQuality = 35,
    this.maxQuality = 70,
  }) : fps = math.min(initFps, maxFps.toDouble()),
       quality = maxQuality - 10;

  static const badExcessMs = 150;
  static const startupExcessMs = 50;
  static const baselineWindow = 20;

  double maxFps;
  final double minFps;
  final int minQuality, maxQuality;
  double fps;
  int quality;

  final _delays = Queue<int>();
  int _good = 0, _bad = 0;
  bool _startup = true;
  double? _beforeCongestion;

  int get baselineMs => _delays.isEmpty ? 0 : _delays.reduce(math.min);
  Duration get interval => Duration(microseconds: (1e6 / fps).round());

  /// How long to wait before asking for the next frame, given how long the
  /// last request took: pulls are one at a time, so the round trip already
  /// counts toward the interval.
  Duration nextDelay(Duration roundTrip) {
    final left = interval - roundTrip;
    return left.isNegative ? Duration.zero : left;
  }

  /// One answered frame request and its round trip in milliseconds.
  void onFrame(int delayMs) {
    if (_delays.length >= baselineWindow) _delays.removeFirst();
    _delays.add(delayMs);
    final excess = delayMs - baselineMs;
    if (_startup) {
      if (excess >= startupExcessMs) {
        _startup = false;
      } else if (++_good >= 2) {
        _good = 0;
        fps = math.min(fps * 2, maxFps);
        if (fps >= maxFps) _startup = false;
        return;
      } else {
        return;
      }
    }
    if (excess < badExcessMs) {
      _bad = 0;
      _good++;
      _recover();
      return;
    }
    _good = 0;
    if (excess >= 1000) {
      _bad = 0;
      _beforeCongestion ??= fps;
      fps = math.max(minFps, fps / 2);
      quality = math.max(minQuality, quality - 15);
      return;
    }
    if (++_bad < 3) return;
    _bad = 0;
    if (quality > minQuality) {
      quality = math.max(minQuality, quality - 10);
    } else {
      _beforeCongestion ??= fps;
      fps = math.max(minFps, fps - math.max(1, fps / 5));
    }
  }

  void _recover() {
    final before = _beforeCongestion;
    if (before != null && _good >= 2) {
      _beforeCongestion = null;
      _good = 0;
      fps = math.min(math.max(fps, before), maxFps);
    } else if (_good >= 3) {
      _good = 0;
      if (fps < maxFps) {
        fps = math.min(maxFps, fps + math.max(1, fps / 5));
      } else if (quality < maxQuality) {
        quality = math.min(maxQuality, quality + 5);
      }
    }
  }
}
