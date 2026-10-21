import 'dart:async';

abstract interface class HostApi {
  Future<dynamic> call(String method, dynamic params);
}

/// An authenticated, key-pinned business connection to one PC.
abstract interface class HostLink implements HostApi {
  String get hostId;

  /// Display name reported by the PC on this authenticated connection.
  String? get hostName;
  Stream<Map<String, dynamic>> get events;
  Future<void> close();
}

/// Zone key for a longer reply deadline; see [withReplyTimeout].
const replyTimeoutKey = #dogcodes.replyTimeout;

/// Runs [body] with a longer reply deadline, for calls that do real work on
/// the PC before answering (e.g. an Agent writing a commit message).
Future<T> withReplyTimeout<T>(Duration timeout, Future<T> Function() body) =>
    runZoned(body, zoneValues: {replyTimeoutKey: timeout});
