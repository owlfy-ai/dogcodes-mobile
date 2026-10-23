import 'dart:async';

/// A timeout does not cancel a native dial. Dispose a resource that arrives
/// after its owner left, was replaced, or stopped waiting for it.
Future<T> ownedResource<T>({
  required Future<T> Function() create,
  required bool Function() current,
  required Future<void> Function(T) release,
  required Duration timeout,
}) async {
  var abandoned = false;
  final pending = create().then((value) {
    if (abandoned || !current()) {
      unawaited(release(value).catchError((Object _) {}));
      throw const ResourceExpired();
    }
    return value;
  });
  try {
    return await pending.timeout(timeout);
  } finally {
    abandoned = true;
  }
}

class ResourceExpired implements Exception {
  const ResourceExpired();
}
