import 'dart:convert';
import 'dart:typed_data';

import 'package:dogcodes_video/dogcodes_video.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:integration_test/integration_test.dart';

import 'h264_sample.dart';
import 'h264_software_sample.dart';

List<(Uint8List, bool)> frames(String sample) {
  final bytes = base64.decode(sample);
  final out = <(Uint8List, bool)>[];
  var i = 0;
  while (i < bytes.length) {
    final length = ByteData.sublistView(bytes, i, i + 4).getUint32(0);
    out.add((bytes.sublist(i + 5, i + 5 + length), bytes[i + 4] == 1));
    i += 5 + length;
  }
  return out;
}

/// Runs on a phone or simulator: the platform decoder takes the PC encoder's
/// real output, and refuses to start from a delta frame.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  for (final (codec, sample) in [
    ('VideoToolbox', h264Sample),
    ('OpenH264', h264SoftwareSample),
  ]) {
    testWidgets('$codec output decodes on the native platform decoder', (
      tester,
    ) async {
      final stream = frames(sample);
      expect(stream.length, 20);
      expect(stream.first.$2, isTrue);
      final decoder = await H264Decoder.create(width: 480, height: 320);
      expect(decoder, isNotNull);
      await tester.pumpWidget(
        Center(
          child: SizedBox(
            width: 480,
            height: 320,
            child: Texture(textureId: decoder!.textureId),
          ),
        ),
      );
      for (final (data, key) in stream) {
        await decoder.decode(data, keyframe: key);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      var decoded = 0;
      for (var i = 0; i < 40 && decoded < stream.length; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        decoded = await decoder.decodedFrames();
      }
      expect(decoded, stream.length);
      final stats = await decoder.stats();
      expect(stats['pending'], 0);
      expect(stats['maxPending'], inInclusiveRange(1, 3));
      await tester.pumpWidget(const SizedBox.shrink());
      await decoder.dispose();

      final late = await H264Decoder.create(width: 480, height: 320);
      await expectLater(
        late!.decode(stream[1].$1, keyframe: false),
        throwsA(isA<NeedKeyframe>()),
      );
      // A keyframe recovers it.
      await late.decode(stream[12].$1, keyframe: true);
      await late.dispose();
    });
    testWidgets(
      '$codec: bounded admission and disposal settles pending frames',
      (tester) async {
        final stream = frames(sample);
        final decoder = await H264Decoder.create(width: 480, height: 320);
        expect(decoder, isNotNull);
        await tester.pumpWidget(
          Center(
            child: SizedBox(
              width: 480,
              height: 320,
              child: Texture(textureId: decoder!.textureId),
            ),
          ),
        );
        final jobs = <Future<void>>[];
        for (var i = 0; i < 12; i++) {
          jobs.add(
            decoder.decode(stream[0].$1, keyframe: true).catchError((
              Object error,
            ) {
              expect(error, isA<NeedKeyframe>());
            }),
          );
        }
        await Future.wait(jobs);
        final stats = await decoder.stats();
        expect(stats['pending'], 0);
        expect(stats['maxPending'], inInclusiveRange(1, 3));
        final ending = <Future<void>>[];
        for (var i = 0; i < 3; i++) {
          ending.add(
            decoder.decode(stream[0].$1, keyframe: true).catchError((
              Object error,
            ) {
              expect(error, isA<NeedKeyframe>());
            }),
          );
        }
        await decoder.dispose();
        await Future.wait(ending).timeout(const Duration(seconds: 1));
      },
    );
  }
}
