import 'dart:async';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/core/owned_resource.dart';

void main() {
  test('a native resource returned after a timeout is closed once', () {
    fakeAsync((time) {
      final pending = Completer<int>();
      final released = <int>[];
      Object? error;
      ownedResource<int>(
        create: () => pending.future,
        current: () => true,
        release: (id) async => released.add(id),
        timeout: const Duration(seconds: 2),
      ).then<void>(
        (_) => fail('late resource was accepted'),
        onError: (Object e) {
          error = e;
        },
      );
      time.elapse(const Duration(seconds: 3));
      expect(error, isA<TimeoutException>());
      pending.complete(7);
      time.flushMicrotasks();
      expect(released, [7]);
    });
  });
  test('an owner cancelled during a native dial releases its result', () async {
    var current = true;
    final pending = Completer<int>();
    final released = <int>[];
    final result = ownedResource<int>(
      create: () => pending.future,
      current: () => current,
      release: (id) async => released.add(id),
      timeout: const Duration(seconds: 2),
    );
    current = false;
    pending.complete(8);
    await expectLater(result, throwsA(isA<ResourceExpired>()));
    expect(released, [8]);
  });
}
