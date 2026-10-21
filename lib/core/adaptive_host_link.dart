import 'dart:async';
import 'host_api.dart';
import 'secure_host_client.dart';
import 'protocol.dart';

/// WebRTC can itself use TURN. Only a verified candidate pair is called P2P.
enum ConnectionRoute {
  relay('加密中继'),
  direct('P2P 直连'),
  turn('TURN 中继'),
  webRtc('WebRTC · 路径待确认');

  const ConnectionRoute(this.label);
  final String label;
  static ConnectionRoute fromStatus(Map status) =>
      switch ((status['route'] as Map?)?['mode']) {
        'direct' => direct,
        'turn-relay' => turn,
        _ => webRtc,
      };
}

abstract interface class RoutedHostLink implements HostLink {
  ConnectionRoute get route;
  Future<void> resume();
}

class DirectConnection {
  DirectConnection(this.link, this.route, {this.expiresAt});
  final HostLink link;
  final ConnectionRoute route;
  final DateTime? expiresAt;
}

typedef RelayDialer = Future<HostLink> Function();
typedef DirectDialer = Future<DirectConnection> Function(HostLink relay);

/// A stable logical connection. A failed RPC is NEVER replayed on a new path.
/// The caller retains its original operation identity and verifies its receipt.
class AdaptiveHostLink implements RoutedHostLink {
  AdaptiveHostLink({
    required HostLink relay,
    required this.relayDialer,
    required this.directDialer,
    this.retryDelay = const Duration(minutes: 2),
  }) : _active = relay,
       hostId = relay.hostId {
    _listen();
    _events.onListen = () {
      unawaited(tryDirect());
    };
  }
  final RelayDialer relayDialer;
  final DirectDialer directDialer;
  final Duration retryDelay;
  @override
  final String hostId;
  HostLink _active;
  @override
  String? get hostName => _active.hostName;
  @override
  ConnectionRoute get route => _route;
  ConnectionRoute _route = ConnectionRoute.relay;
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  @override
  Stream<Map<String, dynamic>> get events => _events.stream;
  StreamSubscription<Map<String, dynamic>>? _subscription;
  final _inFlight = <HostLink, int>{};
  final _retired = <HostLink>{};
  Future<void>? _upgrade, _recovering, _closing;
  Timer? _retry;
  bool _closed = false, _available = true;
  int _generation = 0;
  DateTime? _lastAttempt;

  void _listen() {
    final source = _active;
    _subscription = source.events.listen(
      (event) {
        if (_closed || source != _active) return;
        if (event['type'] == 'disconnected') {
          unawaited(_recover());
        } else {
          _events.add(event);
        }
      },
      onError: (Object _, StackTrace _) {
        unawaited(_recover());
      },
    );
  }

  @override
  Future<dynamic> call(String method, dynamic params) async {
    if (_closed || !_available) throw const RemoteOutcomeUnknown();
    final source = _active;
    _inFlight[source] = (_inFlight[source] ?? 0) + 1;
    try {
      return await source.call(method, params);
    } finally {
      final count = (_inFlight[source] ?? 1) - 1;
      if (count == 0) {
        _inFlight.remove(source);
        if (_retired.remove(source)) unawaited(_disposeLink(source));
      } else {
        _inFlight[source] = count;
      }
    }
  }

  /// Start only after listeners are installed. Negotiation leaves the existing
  /// relay usable; a candidate isn't promoted until fresh Noise authentication.
  Future<void> tryDirect() {
    if (_closed || _recovering != null || _route != ConnectionRoute.relay) {
      return Future.value();
    }
    return _upgrade ??= _tryDirect().whenComplete(() => _upgrade = null);
  }

  Future<void> _tryDirect() async {
    final relay = _active;
    final generation = _generation;
    _lastAttempt = DateTime.now();
    try {
      final caps = await relay.call('remote_capabilities', null) as Map;
      if (!(caps['transportMethods'] as List? ?? []).contains('direct_open')) {
        return;
      }
      if (_closed || generation != _generation) return;
      final candidate = await directDialer(relay);
      if (_closed || generation != _generation || relay != _active) {
        await _disposeLink(candidate.link);
        return;
      }
      await _activate(candidate.link, candidate.route);
      _scheduleRenew(candidate);
    } catch (_) {
      // Failed/unsupported ICE leaves the authenticated relay intact.
      if (!_closed &&
          generation == _generation &&
          _route == ConnectionRoute.relay) {
        _scheduleUpgrade();
      }
    }
  }

  void _scheduleUpgrade() {
    if (_closed) return;
    _retry?.cancel();
    _retry = Timer(retryDelay, () {
      unawaited(tryDirect());
    });
  }

  void _scheduleRenew(DirectConnection candidate) {
    // Refresh configurations containing TURN even if the selected pair was
    // initially direct/unknown: ICE can later nominate a relay candidate.
    final expiry = candidate.expiresAt;
    if (_closed || expiry == null) return;
    final delay =
        expiry.difference(DateTime.now()) - const Duration(minutes: 1);
    _retry?.cancel();
    _retry = Timer(
      delay > const Duration(seconds: 30) ? delay : const Duration(seconds: 30),
      () {
        unawaited(_renew());
      },
    );
  }

  Future<void> _renew() async {
    if (_closed || _recovering != null) return;
    final generation = _generation;
    HostLink? relay;
    try {
      relay = await relayDialer();
      if (_closed || generation != _generation) return;
      final candidate = await directDialer(relay);
      if (_closed || generation != _generation) {
        await _disposeLink(candidate.link);
        return;
      }
      // Replace only after authenticating a fresh candidate.
      await _activate(candidate.link, candidate.route);
      _scheduleRenew(candidate);
    } catch (_) {
      if (!_closed && generation == _generation) {
        _retry = Timer(retryDelay, () {
          unawaited(_renew());
        });
      }
    } finally {
      if (relay != null) await _disposeLink(relay);
    }
  }

  Future<void> _activate(HostLink link, ConnectionRoute route) async {
    if (_closed) {
      await _disposeLink(link);
      return;
    }
    if (link.hostId != hostId) {
      await _disposeLink(link);
      throw const ProtocolException('连接的电脑身份不一致。');
    }
    final old = _active;
    _generation++;
    _retry?.cancel();
    unawaited(_subscription?.cancel());
    _active = link;
    _available = true;
    _route = route;
    _listen();
    _events.add({'type': 'transport_changed', 'route': route.name});
    // Old requests may still carry successful write receipts. Let them finish;
    // close the retired physical connection after its final pending request.
    if ((_inFlight[old] ?? 0) == 0) {
      unawaited(_disposeLink(old));
    } else {
      _retired.add(old);
    }
  }

  Future<void> _recover() {
    if (_closed) return Future.value();
    return _recovering ??= _recoverRelay().whenComplete(
      () => _recovering = null,
    );
  }

  Future<void> _recoverRelay() async {
    _generation++;
    _available = false;
    _retry?.cancel();
    _events.add({'type': 'transport_changing'});
    // Bounded automatic reconnects, without any replay of user operations.
    for (var attempt = 0; attempt < 3 && !_closed; attempt++) {
      if (attempt > 0) await Future<void>.delayed(Duration(seconds: attempt));
      if (_closed) return;
      try {
        final relay = await relayDialer();
        if (_closed) {
          await _disposeLink(relay);
          return;
        }
        await _activate(relay, ConnectionRoute.relay);
        _scheduleUpgrade();
        return;
      } catch (_) {
        /* The final event offers explicit reconnect in the UI. */
      }
    }
    if (!_closed) _events.add({'type': 'disconnected'});
  }

  @override
  Future<void> resume() async {
    if (_closed || _recovering != null) return;
    // A suspended mobile socket can appear open even after the OS removed it.
    try {
      await call('transport_status', null);
    } catch (_) {
      await _recover();
      return;
    }
    if (_lastAttempt == null ||
        DateTime.now().difference(_lastAttempt!) >= retryDelay) {
      await tryDirect();
    }
  }

  Future<void> _disposeLink(HostLink link) async {
    try {
      await link.close();
    } catch (_) {
      /* Already closed. */
    }
  }

  @override
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    _generation++;
    _retry?.cancel();
    await _subscription?.cancel();
    await Future.wait([
      _disposeLink(_active),
      for (final link in _retired) _disposeLink(link),
    ]);
    _retired.clear();
    await _events.close();
  }
}
