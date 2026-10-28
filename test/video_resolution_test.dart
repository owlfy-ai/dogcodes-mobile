import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/features/computers/video_resolution.dart';
import 'package:dogcodes_app/features/computers/remote_view.dart';

Map<String, dynamic> description({
  String id = 'screen-a',
  int seq = 0,
  int width = 640,
  int max = 1280,
  int? generation,
  String state = 'ready',
}) => {
  'generation': generation,
  'width': width,
  'height': width * 5 ~/ 8,
  'resize': {
    'instanceId': id,
    'requested': '$seq',
    'applied': '$seq',
    'targetWidth': width,
    'maxWidth': max,
    'state': state,
  },
};
void main() {
  test(
    'source geometry uses its generation without losing an outstanding width request',
    () {
      final resolution = VideoResolution()
        ..start(description(generation: 3))
        ..want(960);
      final pending = resolution.request(Duration.zero);
      expect(
        resolution.newer(description(generation: 4, state: 'updating')),
        false,
      );
      final rotated = description(generation: 4, width: 640, max: 960);
      expect(resolution.newer(rotated), true);
      resolution.accept(rotated);
      expect(resolution.limit, 960);
      expect(resolution.request(const Duration(seconds: 3)), pending);
      expect(resolution.newer(rotated), false);
      expect(resolution.newer(description(generation: 3, seq: 1)), false);
      expect(resolution.newer(description(id: 'other', generation: 99)), false);
      resolution.accept(description(generation: 5, seq: 1, width: 960));
      expect(resolution.inFlight, false);
    },
  );
  test(
    'freezes an unknown request, coalesces later wishes and ignores another monitor',
    () {
      final resolution = VideoResolution()
        ..start(description())
        ..want(960);
      final first = resolution.request(Duration.zero);
      expect(first, {
        'videoInstance': 'screen-a',
        'viewRequest': '1',
        'targetWidth': 960,
      });
      first['targetWidth'] = 111; // A caller cannot mutate the retry identity.
      resolution.want(1280);
      expect(
        resolution.request(const Duration(seconds: 1))['targetWidth'],
        960,
      );
      resolution.accept(description(id: 'screen-b', seq: 999, width: 1280));
      expect(
        resolution.request(const Duration(seconds: 2))['viewRequest'],
        '1',
      );
      resolution.accept(description(seq: 1, width: 960));
      expect(resolution.request(const Duration(milliseconds: 1500)), isEmpty);
      expect(resolution.request(const Duration(seconds: 2)), {
        'videoInstance': 'screen-a',
        'viewRequest': '2',
        'targetWidth': 1280,
      });
      resolution.start(description(id: 'screen-b'));
      expect(resolution.request(const Duration(seconds: 3)), isEmpty);
    },
  );
  test(
    'uses the fitted screen width, density and zoom within the negotiated budget',
    () {
      final resolution = VideoResolution()..start(description());
      final view = RemoteViewport()
        ..layout(const Size(1000, 400), const Size(600, 1000));
      expect(view.rect.width, 240);
      expect(resolution.widthFor(view, 2), 480);
      view.zoomAt(const Offset(500, 200), 6);
      expect(resolution.widthFor(view, 2), 1280);
      resolution.start(description(max: 3840));
      expect(
        resolution.widthFor(view, 2),
        1920,
      ); // Current tested phone decoder envelope.
    },
  );
  test(
    'hysteresis avoids rebuilding for layout rounding; old PCs remain unchanged',
    () {
      final resolution = VideoResolution()
        ..start(description(width: 960))
        ..want(1120);
      expect(resolution.request(Duration.zero)['targetWidth'], 1120);
      resolution.accept(description(seq: 1, width: 1120));
      resolution.want(960);
      expect(resolution.request(const Duration(seconds: 3)), isEmpty);
      resolution.want(800);
      expect(
        resolution.request(const Duration(seconds: 3))['targetWidth'],
        800,
      );
      resolution.start({'width': 1280, 'height': 800});
      resolution.want(640);
      expect(resolution.supported, false);
      expect(resolution.request(const Duration(seconds: 5)), isEmpty);
    },
  );
}
