import 'dart:math' as math;
import 'dart:ui';

/// Where the remote screen sits inside the phone view: fit-to-screen at
/// zoom 1, pinch up to [maxZoom], panned by [origin] (the frame's top-left in
/// view coordinates). All remote positions are normalised 0..1 across the
/// display, so the mapping does not depend on the frame's pixel size: a
/// Retina frame of 3456 px and a 1600 px thumbnail land on the same point,
/// and the PC turns the fraction into its own logical points.
class RemoteViewport {
  static const maxZoom = 6.0;

  Size view = Size.zero;
  Size content = Size.zero;
  double zoom = 1;
  Offset origin = Offset.zero;

  bool get ready => !view.isEmpty && content.width > 0 && content.height > 0;
  double get fitScale => ready
      ? math.min(view.width / content.width, view.height / content.height)
      : 1;
  double get scale => fitScale * zoom;
  Rect get rect => origin & (content * scale);

  /// New view size (rotation, keyboard) or frame aspect: keeps the remote
  /// point under the view centre where it was.
  void layout(Size newView, Size newContent) {
    if (newView == view && newContent == content) return;
    final hadLayout = ready;
    final centre = hadLayout ? toRemote(view.center(Offset.zero)) : null;
    view = newView;
    content = newContent;
    if (!ready) return;
    if (centre != null) origin += view.center(Offset.zero) - toLocal(centre);
    _clamp();
  }

  /// View point → normalised remote point, clamped onto the screen edge.
  Offset toRemote(Offset local) {
    final r = rect;
    return Offset(
      ((local.dx - r.left) / r.width).clamp(0.0, 1.0),
      ((local.dy - r.top) / r.height).clamp(0.0, 1.0),
    );
  }

  bool contains(Offset local) => rect.contains(local);

  Offset toLocal(Offset remote) {
    final r = rect;
    return Offset(r.left + remote.dx * r.width, r.top + remote.dy * r.height);
  }

  /// Zooms by [factor] keeping the remote point under [focal] fixed.
  void zoomAt(Offset focal, double factor) {
    if (!ready || !factor.isFinite || factor <= 0) return;
    final next = (zoom * factor).clamp(1.0, maxZoom);
    final anchor = (focal - origin) / scale;
    zoom = next;
    origin = focal - anchor * scale;
    _clamp();
  }

  void panBy(Offset delta) {
    origin += delta;
    _clamp();
  }

  void fit() {
    zoom = 1;
    _clamp();
  }

  /// Pans the least distance that brings [remote] at least [margin] inside
  /// the view. Returns whether anything moved.
  bool ensureVisible(Offset remote, {double margin = 32}) {
    if (!ready) return false;
    final p = toLocal(remote);
    final m = math.min(margin, math.min(view.width, view.height) / 4);
    var dx = 0.0, dy = 0.0;
    if (p.dx < m) dx = m - p.dx;
    if (p.dx > view.width - m) dx = view.width - m - p.dx;
    if (p.dy < m) dy = m - p.dy;
    if (p.dy > view.height - m) dy = view.height - m - p.dy;
    // Sub-pixel leftovers from an earlier pan are not worth a move.
    if (dx.abs() < 0.5 && dy.abs() < 0.5) return false;
    final before = origin;
    panBy(Offset(dx, dy));
    return origin != before;
  }

  /// A frame smaller than the view is centred on that axis; a larger one may
  /// not leave a gap at either edge.
  void _clamp() {
    final size = content * scale;
    double axis(double pos, double extent, double space) {
      if (extent <= space) return (space - extent) / 2;
      return pos.clamp(space - extent, 0.0);
    }

    origin = Offset(
      axis(origin.dx, size.width, view.width),
      axis(origin.dy, size.height, view.height),
    );
  }

  /// Width in remote pixels worth requesting: what the screen can show at
  /// this zoom, never more than the display has.
  int wantedWidth({
    required double devicePixelRatio,
    required int nativeWidth,
    int min = 640,
    int max = 2560,
  }) {
    final shown = view.width * zoom * devicePixelRatio;
    final cap = nativeWidth > 0 ? math.min(nativeWidth, max) : max;
    return shown.round().clamp(math.min(min, cap), cap);
  }
}

/// Fraction → the PC's 0..65535 wire coordinate.
Map<String, dynamic> moveEvent(Offset remote) => {
  'kind': 'move',
  'x': (remote.dx.clamp(0.0, 1.0) * 65535).round(),
  'y': (remote.dy.clamp(0.0, 1.0) * 65535).round(),
};
