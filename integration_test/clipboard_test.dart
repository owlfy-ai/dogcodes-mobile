import 'dart:ui' as ui;
import 'package:dogcodes_clipboard/dogcodes_clipboard.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

Future<Uint8List> png() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 16, 10),
    Paint()..color = const Color(0xff22aa44),
  );
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 8, 10),
    Paint()..color = const Color(0xffff2244),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(16, 10);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

Future<void> pixelsMatch(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final image = (await codec.getNextFrame()).image;
  expect(image.width, 16);
  expect(image.height, 10);
  final rgba = (await image.toByteData(
    format: ui.ImageByteFormat.rawRgba,
  ))!.buffer.asUint8List();
  expect(rgba.sublist(0, 4), [255, 34, 68, 255]);
  expect(rgba.sublist(12 * 4, 13 * 4), [34, 170, 68, 255]);
  image.dispose();
  codec.dispose();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native image clipboard round trip preserves PNG pixels and rejects corrupt replacement',
    (t) async {
      debugPrint('clipboard: mount');
      await t.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Text('Isolated clipboard acceptance')),
        ),
      );
      debugPrint('clipboard: mounted');
      await t.pump();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      debugPrint('clipboard: create sample');
      final source = await png();
      debugPrint('clipboard: write');
      await ImageClipboard.writePng(source);
      debugPrint('clipboard: read');
      await pixelsMatch((await ImageClipboard.readPng())!);
      await expectLater(
        ImageClipboard.writePng(Uint8List.fromList([1, 2, 3, 4])),
        throwsA(isA<PlatformException>()),
      );
      debugPrint('clipboard: read');
      await pixelsMatch((await ImageClipboard.readPng())!);
      // Native cancellation acknowledges whether it removed the pending write.
      // If it wins, a later completion must not modify a newer clipboard value.
      final write = ImageClipboard.beginWrite(source);
      final completion = write.done.then(
        (_) => true,
        onError: (Object e) {
          if (e is PlatformException && e.code == 'cancelled') return false;
          throw e;
        },
      );
      final cancelled = await write.cancel();
      final applied = await completion;
      expect(applied, !cancelled);
      await Clipboard.setData(const ClipboardData(text: 'fixture text'));
      expect(await ImageClipboard.readPng(), isNull);
    },
  );
}
