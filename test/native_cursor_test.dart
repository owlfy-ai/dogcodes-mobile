import 'dart:convert';
import 'dart:ui';
import 'package:dogcodes_app/features/computers/remote_cursor.dart';
import 'package:flutter_test/flutter_test.dart';

const nativeShapeId = '0123456789abcdef';
Map<String, dynamic> cursorWire({bool pixels = true}) => {
  'x': 32000,
  'y': 24000,
  'shapeId': nativeShapeId,
  'displayWidth': 1000,
  'displayHeight': 500,
  if (pixels)
    'shape': {
      'id': nativeShapeId,
      'width': 16,
      'height': 10,
      'hotX': 3,
      'hotY': 4,
      'bytes':
          'iVBORw0KGgoAAAANSUhEUgAAABAAAAAKCAIAAAAy3EnLAAAAEUlEQVR4nGNoIBEwjGoYmhoAv1XwATGE43sAAAAASUVORK5CYII=',
    },
};
void main() {
  final now = DateTime.utc(2026, 10, 27);
  test(
    'one verified cursor survives shape-only ACKs and is forgotten on source changes',
    () {
      final cursor = RemoteCursor();
      cursor.update({'cursor': cursorWire()}, now);
      final shape = cursor.shape!;
      expect(cursor.shapeId, nativeShapeId);
      cursor.update({
        'cursor': {...cursorWire(pixels: false), 'displayWidth': 2000},
      }, now);
      expect(identical(cursor.shape!.bytes, shape.bytes), true);
      expect(cursor.shape!.display.width, 2000);
      cursor.configure(video: {'cursorEmbedded': false});
      expect(cursor.shapeId, isNull);
      cursor.update({'cursor': cursorWire(pixels: false)}, now);
      expect(
        cursor.shapeId,
        isNull,
      ); // Request full pixels again, never acknowledge a lost shape.
      cursor.update({'cursor': cursorWire()}, now);
      expect(cursor.shapeId, nativeShapeId);
      cursor.update({'cursorEmbedded': true}, now);
      expect(cursor.shape, isNull);
      cursor.configure(video: {'cursorEmbedded': false});
      cursor.update({
        'video': {'cursorEmbedded': true},
        'cursor': cursorWire(),
      }, now);
      expect(cursor.embedded, isTrue);
      expect(cursor.shapeId, isNull);
      expect(cursor.position(now), isNull);
    },
  );
  test('native hotspot remains at the target through zoom and fitting', () {
    final shape = RemoteCursorShape.read(cursorWire(), null)!;
    const tip = Offset(100, 100);
    expect(
      shape.rect(tip, const Rect.fromLTWH(0, 0, 1000, 500)),
      const Rect.fromLTWH(97, 96, 16, 10),
    );
    expect(
      shape.rect(tip, const Rect.fromLTWH(0, 0, 2000, 1000)),
      const Rect.fromLTWH(94, 92, 32, 20),
    );
    expect(
      shape.rect(tip, const Rect.fromLTWH(0, 0, 100, 50)),
      const Rect.fromLTWH(98.5, 98, 8, 5),
    );
  });
  test(
    'new shape metadata is adopted while local movement still predicts the position',
    () {
      final cursor = RemoteCursor()..move(const Offset(.2, .3), now);
      cursor.update({'cursor': cursorWire()}, now);
      expect(cursor.shapeId, nativeShapeId);
      expect(cursor.position(now), const Offset(.2, .3));
      cursor.update({
        'cursor': null,
      }, now.add(const Duration(milliseconds: 401)));
      expect(
        cursor.position(now.add(const Duration(milliseconds: 401))),
        isNull,
      );
      expect(
        cursor.shapeId,
        nativeShapeId,
      ); // Hidden/off-display does not require resending pixels.
    },
  );
  test(
    'untrusted geometry, hotspot, identity and PNG dimensions are bounded before decode',
    () {
      for (final change in [
        {'width': 513},
        {'hotX': 16},
        {'hotY': -1},
        {'width': 15},
        {'id': 'fedcba9876543210'},
        {'bytes': 'not base64'},
        {'bytes': base64Encode(List.filled(33, 0))},
        {'bytes': 'A' * (RemoteCursorShape.maxBytes * 2)},
      ]) {
        final wire = cursorWire();
        wire['shape'] = {...wire['shape'] as Map, ...change};
        expect(
          RemoteCursorShape.read(wire, null),
          isNull,
          reason: change.keys.join(','),
        );
      }
      expect(
        RemoteCursorShape.read({...cursorWire(), 'displayWidth': 0}, null),
        isNull,
      );
      expect(
        RemoteCursorShape.read({
          ...cursorWire(),
          'displayHeight': double.infinity,
        }, null),
        isNull,
      );
    },
  );
}
