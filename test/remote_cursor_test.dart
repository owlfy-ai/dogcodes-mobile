import 'package:dogcodes_app/features/computers/remote_cursor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 10, 22);
  DateTime after(int ms) => now.add(Duration(milliseconds: ms));
  const local = Offset(0.2, 0.3);
  final remote = {
    'cursor': {'x': 65535, 'y': 0},
  };

  test('software video shows PC pointer and local movement wins for 400ms', () {
    final cursor = RemoteCursor()..configure(video: {'cursorEmbedded': false});
    cursor.update(remote, now);
    expect(cursor.position(now), const Offset(1, 0));
    cursor.move(local, now);
    cursor.update(remote, after(399));
    expect(cursor.position(after(399)), local);
    // A null PC location is equally stale during local prediction.
    cursor.update({'cursor': null}, after(399));
    expect(cursor.position(after(399)), local);
    cursor.update(remote, after(400));
    expect(cursor.position(after(400)), const Offset(1, 0));
    cursor.update({'cursor': null}, after(401));
    expect(cursor.position(after(401)), isNull);
  });

  test(
    'embedded pointer loses its predictive ghost without another PC event',
    () {
      final cursor = RemoteCursor()..configure(video: {'cursorEmbedded': true});
      cursor.move(local, now);
      expect(cursor.position(after(399)), local);
      cursor.update(remote, after(399));
      expect(cursor.position(after(400)), isNull);
      cursor.move(const Offset(0.7, 0.8), after(500));
      expect(cursor.position(after(899)), const Offset(0.7, 0.8));
      expect(cursor.position(after(900)), isNull);
      cursor.expirePrediction();
      expect(cursor.position(after(500)), isNull);
    },
  );

  test('legacy video embeds cursor, JPEG retains separate overlay', () {
    final cursor = RemoteCursor()..configure(video: {'codec': 'h264'});
    expect(cursor.embedded, isTrue);
    cursor.configure();
    expect(cursor.embedded, isFalse);
    cursor.update(remote, now);
    cursor.update({'unchanged': true}, after(1000));
    expect(cursor.position(after(1000)), const Offset(1, 0));
    cursor.expirePrediction();
    expect(cursor.position(after(1000)), const Offset(1, 0));
  });

  test('switching screens clears old geometry and prediction priority', () {
    final cursor = RemoteCursor()..move(local, now);
    cursor.configure(video: {'cursorEmbedded': false});
    expect(cursor.position(now), isNull);
    cursor.update(remote, after(10));
    expect(cursor.position(after(10)), const Offset(1, 0));
  });

  test('malformed or off-display pointer cannot escape the screen', () {
    final cursor = RemoteCursor();
    for (final bad in [
      {'x': -1, 'y': 2},
      {'x': 65536, 'y': 2},
      {'x': double.nan, 'y': 2},
      {'x': 2, 'y': double.infinity},
      {'x': '1', 'y': 2},
      null,
    ]) {
      cursor.update(remote, now);
      cursor.update({'cursor': bad}, now);
      expect(cursor.position(now), isNull);
    }
  });

  test('clock moving backwards cannot pin an embedded prediction forever', () {
    final cursor = RemoteCursor()..configure(video: {'cursorEmbedded': true});
    cursor.move(local, now);
    expect(cursor.position(after(-1)), isNull);
  });
}
