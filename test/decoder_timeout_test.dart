import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_video/dogcodes_video.dart';

void main() {
  testWidgets(
    'a missing native output callback cannot hold relay consumption forever',
    (tester) async {
      const channel = MethodChannel('dogcodes/h264');
      final pending = Completer<Object?>();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'create') return 1;
        if (call.method == 'decode') return pending.future;
        return null;
      });
      final decoder = await H264Decoder.create(width: 480, height: 320);
      final decoded = expectLater(
        decoder!.decode(Uint8List.fromList([0, 0, 0, 1, 5]), keyframe: true),
        throwsA(isA<NeedKeyframe>()),
      );
      await tester.pump(const Duration(seconds: 3));
      await decoded;
      pending.completeError(PlatformException(code: 'needKeyframe'));
      await tester.pump();
      await decoder.dispose();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
    },
  );
  testWidgets('disposing completes a waiting decode and cancels its deadline', (
    tester,
  ) async {
    const channel = MethodChannel('dogcodes/h264');
    final pending = Completer<Object?>();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'create') return 1;
      if (call.method == 'decode') return pending.future;
      return null;
    });
    final decoder = await H264Decoder.create(width: 480, height: 320);
    final decoded = expectLater(
      decoder!.decode(Uint8List.fromList([0, 0, 0, 1, 5]), keyframe: true),
      throwsA(isA<NeedKeyframe>()),
    );
    await decoder.dispose();
    await decoded;
    pending.complete(null);
    await tester.pump();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      null,
    );
  });
}
