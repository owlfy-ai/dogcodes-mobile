import 'package:dogcodes_app/l10n/strings.dart';
import 'dart:async';
import '../../core/protocol.dart';
import 'dart:convert';
import 'package:dogcodes_video/dogcodes_video.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../../core/adaptive_host_link.dart';
import '../../core/clipboard_transfer.dart';
import '../../core/host_hub.dart';
import '../../core/host_api.dart';
import '../../core/desktop_handoff.dart';
import 'clipboard_sheets.dart';
import 'desktop_candidate.dart';
import '../../core/pc_api.dart';
import '../../core/owned_resource.dart';
import '../../core/rtc_transport.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../tools/tool_context.dart';
import 'frame_rate.dart';
import 'remote_gestures.dart';
import 'remote_input.dart';
import 'relay_video.dart';
import 'remote_view.dart';
import 'remote_cursor.dart';
import 'video_stats.dart';
import 'video_resolution.dart';
import 'video_recovery.dart';

/// 10 远程桌面: device-level screen and input for one PC, independent of any
/// Agent. Where WebRTC reaches the PC (direct or TURN), the page opens a
/// connection of its own and the screen arrives as a hardware-decoded H.264
/// track whose bitrate follows the link (PC-side congestion control);
/// otherwise frames are JPEG pulls, one at a time, paced by
/// [FrameRateControl]. Input goes through [RemoteInputQueue] so every request
/// carries the next sequence and a retried request can never replay a click.
///
/// Touch: tap = click, long-press or two-finger tap = right click, press and
/// move = left drag (select, move windows), two fingers together = scroll,
/// pinch = zoom the local view (its focal movement pans).
class DesktopPreparationFailure implements Exception {
  DesktopPreparationFailure(this.cause);
  final Object cause;
  @override
  String toString() => '$cause';
}

class RemoteDesktopPage extends StatefulWidget {
  const RemoteDesktopPage({super.key, required this.host, this.recoveryClock});
  final HostState host;
  @visibleForTesting
  final Duration Function()? recoveryClock;
  @override
  State<RemoteDesktopPage> createState() => _RemoteDesktopPageState();
}

class _RemoteDesktopPageState extends State<RemoteDesktopPage>
    with WidgetsBindingObserver {
  /// Finger travel per scrolled line, in view pixels.
  static const _scrollStep = 18.0;

  List<Map<String, dynamic>> displays = [];
  int? monitor;
  String? lease, error;
  String? _desktopPreparationNote;
  bool _requiresDesktopPreparation = false, _freshDesktopPermission = false;
  bool locked = false, busy = false;
  Uint8List? frame;
  String? frameId;
  int _session = 0;
  int _screenGeneration = 0;
  ClipboardTransfer? _clipboardTransfer;
  HostLink? _clipboardLink;
  bool _clipboardBusy = false,
      _clipboardWriteStarted = false,
      _clipboardSending = false;
  int _clipboardEpoch = 0;
  double? _clipboardProgress;

  final keyboard = TextEditingController(text: _sentinel);
  final keyFocus = FocusNode();
  final viewport = RemoteViewport();
  late final gestures = RemoteGestureRecognizer(_gesture);
  RemoteInputQueue? _queue;
  FrameRateControl _rate = FrameRateControl();
  Timer? _longPress;

  /// Remote pointer (0..1). Our own moves win for a moment over the position
  /// the PC reports with each frame, which lags by a round trip.
  final _cursorState = RemoteCursor();
  Timer? _cursorExpiry;
  Offset? get _cursor => _cursorState.position(DateTime.now());
  Offset _scrollRest = Offset.zero;
  final _modifiers = <String>{};

  /// Dedicated desktop connection (RPCs + screen track), when available.
  DesktopConnection? _desk;
  HostLink? _relayLink;
  StreamSubscription<Map<String, dynamic>>? _connectionEvents;
  Timer? _renewal, _reconnect, _upgradeTimer;
  Future<void>? _handoffWork;
  DesktopCandidate? _handoffCandidate;
  bool _handoffEnabled = false,
      _handoffPreparing = false,
      _handoffCommitting = false;
  String _handoffRevision = '0';
  int _inputSequence = 0;
  ConnectionRoute _binaryRoute = ConnectionRoute.relay;
  DateTime? _binaryExpiry;
  int _routeProbeTicks = 0;
  bool _paused = false, _resumeDesktop = false, _videoDisabled = false;
  int _recoveries = 0;
  int _lastDecoded = 0, _sentAtProgress = 0, _stalledTicks = 0;
  final _waiters = <Timer, Completer<void>>{};
  RTCVideoRenderer? _renderer, _heldRenderer;
  bool _video = false, _gotVideoFrame = false;

  /// Relay video: binary H.264 messages on the ordinary link, decoded by the
  /// platform decoder into a texture.
  H264Decoder? _decoder, _heldDecoder;
  final _resolution = VideoResolution();
  final _pipelineRecovery = VideoRecovery();
  final _resolutionClock = Stopwatch()..start();
  Timer? _resolutionDebounce;
  int? _resolutionCandidate;
  Map? _activeVideoDescription;
  RelayVideoReceiver? _relay;
  StreamSubscription<Map<String, dynamic>>? _relayFrames;
  int _relayBytes = 0;
  bool _relayVideoOff = false;

  /// Hardware decoding into a texture exists on the phones only.
  bool get _relayVideoSupported =>
      !_relayVideoOff &&
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);
  VideoStatsSample? _videoStats;
  double _videoFps = 0, _videoKbps = 0;
  String? _videoNote;

  /// Desktop RPCs follow the lease: over the desktop connection if open.
  HostLink? get _api => _desk?.link ?? _relayLink ?? h.link;

  // Measured over the last second, for the status line.
  final _frameTimes = <DateTime>[];
  int _bytesWindow = 0, _lastRtt = 0;
  DateTime _windowStart = DateTime.now();
  double _kbps = 0;

  HostState get h => widget.host;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cancelClipboard();
    _stop();
    _longPress?.cancel();
    keyboard.dispose();
    keyFocus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _resumeDesktop = _resumeDesktop || lease != null || busy;
      _paused = true;
      _cancelClipboard();
      _stop();
    } else if (state == AppLifecycleState.resumed) {
      _paused = false;
      if (_resumeDesktop && mounted) {
        _resumeDesktop = false;
        unawaited(_start());
      }
    }
  }

  void _closeRelayVideo() {
    final decoder = _decoder, held = _heldDecoder;
    _heldDecoder = null;
    unawaited(held?.dispose());
    unawaited(_relayFrames?.cancel());
    _relayFrames = null;
    _relay?.dispose();
    _relay = null;
    _decoder = null;
    unawaited(decoder?.dispose());
  }

  Future<void> _closeDesktop({Future<void>? after}) async {
    // Detach synchronously: cleanup of an old session must never close its
    // replacement, even when the old native operations finish late.
    _closeRelayVideo();
    final renderer = _renderer,
        heldRenderer = _heldRenderer,
        desk = _desk,
        relay = _relayLink;
    _heldRenderer = null;
    final events = _connectionEvents, migration = _handoffCandidate;
    _handoffCandidate = null;
    _handoffWork = null;
    _handoffPreparing = _handoffCommitting = _handoffEnabled = false;
    _upgradeTimer?.cancel();
    _binaryRoute = ConnectionRoute.relay;
    _binaryExpiry = null;
    _routeProbeTicks = 0;
    _handoffRevision = '0';
    _renderer = null;
    _desk = null;
    _relayLink = null;
    _connectionEvents = null;
    _video = false;
    _resolutionDebounce?.cancel();
    _resolution.reset();
    _resolutionCandidate = null;
    _activeVideoDescription = null;
    _configureCursor();
    _renewal?.cancel();
    unawaited(events?.cancel().catchError((Object _) {}));
    if (after != null) {
      await after.timeout(const Duration(seconds: 3)).catchError((Object _) {});
    }
    Future<void> release(Future<void> Function() dispose) async {
      try {
        await dispose().timeout(const Duration(seconds: 3));
      } catch (_) {
        // Cleanup of one native object must not retain the other transports.
      }
    }

    await Future.wait([
      if (renderer != null) release(() => disposeDesktopRenderer(renderer)),
      if (heldRenderer != null)
        release(() => disposeDesktopRenderer(heldRenderer)),
      if (desk != null &&
          (migration == null ||
              (!identical(desk.link, migration.source) &&
                  !identical(desk.link, migration.connection.link))))
        release(desk.close),
      if (relay != null &&
          (migration == null ||
              (!identical(relay, migration.source) &&
                  !identical(relay, migration.connection.link))))
        release(relay.close),
      if (migration != null) release(migration.closeAll),
    ]);
  }

  bool _current(int session) => mounted && !_paused && session == _session;

  Future<void> _wait(Duration duration) {
    final done = Completer<void>();
    late Timer timer;
    timer = Timer(duration, () {
      _waiters.remove(timer);
      done.complete();
    });
    _waiters[timer] = done;
    return done.future;
  }

  void _cancelWaiters() {
    for (final entry in _waiters.entries) {
      entry.key.cancel();
      entry.value.complete();
    }
    _waiters.clear();
  }

  /// Both video modes own a physical connection. The business link can
  /// upgrade or recover without retiring the desktop's lease or carrying
  /// large video frames in front of Agent messages and approvals.
  Future<void> _openDesktop(int session) async {
    final business = h.link;
    if (business is! AdaptiveHostLink) return;
    final relay = await ownedResource<HostLink>(
      create: business.relayDialer,
      current: () => _current(session),
      release: (link) => link.close(),
      timeout: const Duration(seconds: 12),
    );
    if (!_current(session)) {
      await relay.close();
      return;
    }
    _relayLink = relay;
    if (business.desktopDialer == null) return;
    try {
      final caps = await relay.call('remote_capabilities', null) as Map;
      if (!_current(session)) return;
      if (!(caps['transportMethods'] as List? ?? []).contains('direct_open')) {
        return;
      }
      final desk = await ownedResource<DesktopConnection>(
        create: () async =>
            await business.desktopDialer!(relay) as DesktopConnection,
        current: () => _current(session),
        release: (value) => value.close(),
        timeout: const Duration(seconds: 20),
      );
      if (!_current(session)) {
        await desk.close();
        return;
      }
      _desk = desk;
      _relayLink = null;
      await relay.close();
    } catch (_) {
      if (_current(session) && !_videoDisabled) {
        _videoNote = tr("直连未建立，使用加密中继");
      }
    }
  }

  void _watchConnection(int session) {
    final source = _api;
    bool deferLoss() {
      if (_handoffPreparing &&
          _handoffCandidate != null &&
          identical(source, _handoffCandidate!.source) &&
          !_handoffCandidate!.adopted) {
        unawaited(_queue?.pause());
        return true;
      }
      return false;
    }

    _connectionEvents = source?.events.listen(
      (event) {
        if (!_current(session) || !identical(source, _api)) return;
        if (event['type'] == 'disconnected' ||
            event['type'] == 'transport_changed') {
          if (deferLoss()) return;
          _recover(tr("连接已变化，正在恢复远程桌面"));
        }
      },
      onDone: () {
        if (_current(session) && identical(source, _api) && !deferLoss()) {
          _recover(tr("连接中断，正在恢复远程桌面"));
        }
      },
    );
    _renewal?.cancel();
    final expires = _desk?.expiresAt ?? _binaryExpiry;
    if (expires != null) {
      final delay =
          expires.difference(DateTime.now()) - const Duration(minutes: 1);
      _renewal = Timer(
        delay > const Duration(seconds: 30)
            ? delay
            : const Duration(seconds: 30),
        () {
          if (_current(session)) {
            if (_video && _handoffEnabled) {
              unawaited(_tryHandoff(renewing: true));
            } else {
              unawaited(_start());
            }
          }
        },
      );
    }
    _scheduleHandoff(session);
  }

  void _observeHandoffRevision(dynamic value) {
    final next = int.tryParse('$value'),
        previous = int.tryParse(_handoffRevision);
    if (next != null && (previous == null || next >= previous)) {
      _handoffRevision = '$next';
    }
  }

  void _scheduleHandoff(int session) {
    _upgradeTimer?.cancel();
    final business = h.link;
    if (!_current(session) ||
        !_handoffEnabled ||
        business is! AdaptiveHostLink) {
      return;
    }
    final renew =
        (_desk?.expiresAt ?? _binaryExpiry) != null &&
        (_desk?.expiresAt ?? _binaryExpiry)!.difference(DateTime.now()) <=
            const Duration(minutes: 1);
    if (_desk != null && !renew) return;
    if (_binaryRoute == ConnectionRoute.direct && !renew) return;
    final delay = renew && business.retryDelay > const Duration(seconds: 30)
        ? const Duration(seconds: 30)
        : business.retryDelay;
    _upgradeTimer = Timer(delay, () {
      if (_current(session)) unawaited(_tryHandoff(renewing: renew));
    });
  }

  Future<void> _tryHandoff({bool renewing = false}) {
    if (_handoffWork != null) return _handoffWork!;
    final session = _session;
    if (!_current(session) ||
        busy ||
        !_gotVideoFrame ||
        (_decoder == null && _renderer == null) ||
        !_handoffEnabled) {
      _scheduleHandoff(session);
      return Future.value();
    }
    late Future<void> work;
    work = _runHandoff(session, renewing).whenComplete(() {
      if (identical(_handoffWork, work)) {
        _handoffWork = null;
        if (_current(session)) _scheduleHandoff(session);
      }
    });
    _handoffWork = work;
    return work;
  }

  Future<void> _runHandoff(int session, bool renewing) async {
    final source = _api, id = lease, queue = _queue, business = h.link;
    if (source == null ||
        id == null ||
        queue == null ||
        business is! AdaptiveHostLink) {
      return;
    }
    final media = _desk != null && _decoder == null;
    final generation = _screenGeneration;
    bool original() =>
        _current(session) &&
        lease == id &&
        identical(_api, source) &&
        identical(_queue, queue) &&
        _screenGeneration == generation &&
        !busy;
    DesktopCandidate? resource;
    DesktopHandoff? protocol;
    bool settled = false, safeResume = true;
    try {
      final candidate = await ownedResource<DesktopCandidate>(
        create: () async {
          DesktopConnection? desktop;
          DirectConnection result;
          final dial = business.desktopDialer;
          if (dial != null) {
            try {
              desktop = await dial(source) as DesktopConnection;
              if (!desktop.video) {
                await desktop.close();
                desktop = null;
              }
            } catch (_) {
              desktop = null;
            }
          }
          if (desktop != null) {
            result = DirectConnection(
              desktop.link,
              ConnectionRoute.webRtc,
              expiresAt: desktop.expiresAt,
            );
          } else if (media && renewing) {
            result = DirectConnection(
              await business.relayDialer(),
              ConnectionRoute.relay,
            );
          } else {
            result = await business.directDialer(source);
          }
          if (identical(result.link, source) ||
              identical(result.link, business)) {
            throw const DesktopHandoffUnknown();
          }
          if (result.route == ConnectionRoute.webRtc) {
            try {
              final status = await result.link
                  .call('transport_status', null)
                  .timeout(const Duration(seconds: 2));
              if (status is Map) {
                result = DirectConnection(
                  result.link,
                  ConnectionRoute.fromStatus(status),
                  expiresAt: result.expiresAt,
                );
              }
            } catch (_) {
              /* Unverified candidates are never labelled P2P. */
            }
          }
          return DesktopCandidate(source, result, desktop: desktop);
        },
        current: original,
        release: (value) => value.release(),
        timeout: const Duration(seconds: 20),
      );
      resource = candidate;
      if (!original()) return;
      _handoffCandidate = candidate;
      if (!renewing && candidate.connection.route != ConnectionRoute.direct) {
        return;
      }
      if (_resolution.inFlight) return;
      final targetMedia = candidate.desktop != null;
      _handoffPreparing = true;
      protocol = DesktopHandoff(
        source: source,
        candidate: candidate.connection.link,
        lease: id,
        revision: _handoffRevision,
        transport: targetMedia ? 'webrtc' : 'binary',
      );
      final stage = await protocol.prepare();
      if (!original()) throw const ResourceExpired();
      final video = stage['video'] as Map;
      final width = (video['width'] as num).toInt(),
          height = (video['height'] as num).toInt();
      if (width < 2 ||
          height < 2 ||
          width > 3840 ||
          height > 3840 ||
          width * height > 3840 * 2160) {
        throw const DesktopHandoffUnknown();
      }
      if (targetMedia) {
        await _prepareRtpCandidate(candidate, original);
      } else {
        final prepared = await ownedResource<H264Decoder?>(
          create: () => H264Decoder.create(width: width, height: height),
          current: () => original() && !candidate.closed,
          release: (value) async {
            await value?.dispose();
          },
          timeout: const Duration(seconds: 3),
        );
        if (prepared == null) throw StateError(tr("无法准备新解码器"));
        candidate.decoder = prepared;
      }
      if (!original()) throw const ResourceExpired();
      _handoffCommitting = true;
      final commitGeneration = ++_screenGeneration;
      bool committing() =>
          _current(session) &&
          lease == id &&
          identical(_queue, queue) &&
          _screenGeneration == commitGeneration;
      safeResume = false;
      final drained = await queue.pause().timeout(const Duration(seconds: 4));
      if (!drained || !committing()) throw const ResourceExpired();
      final result = await protocol.claim(_inputSequence);
      settled = true;
      if (!committing()) return;
      _handoffRevision = '${result.snapshot['revision']}';
      if (!result.moved) {
        safeResume = true;
        return;
      }
      if (targetMedia) {
        _desk = candidate.desktop;
        _relayLink = null;
      } else {
        _desk = null;
        _relayLink = candidate.connection.link;
      }
      candidate.adopted = true;
      _binaryRoute = candidate.connection.route;
      _binaryExpiry = candidate.connection.expiresAt;
      final oldEvents = _connectionEvents;
      _connectionEvents = null;
      _watchConnection(session);
      unawaited(oldEvents?.cancel());
      safeResume = true;
      queue.resume();

      final migratedVideo = await _waitHandoffCodec(
        candidate,
        id,
        result.snapshot['video'] as Map,
        committing,
      );
      if (!committing()) return;
      if (!targetMedia && video['switchingCodec'] == true) {
        await candidate.takeDecoder()?.dispose();
        candidate.decoder = await ownedResource<H264Decoder?>(
          create: () => H264Decoder.create(
            width: (migratedVideo['width'] as num).toInt(),
            height: (migratedVideo['height'] as num).toInt(),
          ),
          current: committing,
          release: (value) async {
            await value?.dispose();
          },
          timeout: const Duration(seconds: 3),
        );
        if (candidate.decoder == null) throw const DesktopHandoffUnknown();
      }
      final adopted = targetMedia
          ? await _adoptRtpCandidate(candidate, migratedVideo, id, committing)
          : await _startRelayVideo(
              migratedVideo,
              id,
              candidate.connection.link,
              resizing: true,
              prepared: candidate.takeDecoder(),
            );
      if (!committing()) return;
      if (!adopted) throw StateError(tr("新画面解码不可用"));
      _resolution.start(migratedVideo);
      _activeVideoDescription = Map.from(migratedVideo);
      _resolutionCandidate = null;
      _lastDecoded = _sentAtProgress = _stalledTicks = 0;
      _gotVideoFrame = true;
      _syncInputPicture();
      _videoNote = null;
      setState(() {});
    } on DesktopAuthorizationEnded catch (e) {
      if (_current(session) && lease == id) _authorizationEnded(e);
    } catch (_) {
      if (_current(session) && lease == id && resource?.adopted == true) {
        await _fallback(session, tr("换路后画面不可用"));
      }
    } finally {
      if (!settled &&
          protocol?.started == true &&
          _current(session) &&
          lease == id) {
        try {
          final result = await protocol!.abandon();
          if (result.moved) {
            _recover(tr("正在核实并恢复远程桌面连接"));
          } else {
            safeResume = true;
            _handoffRevision = '${result.snapshot['revision']}';
          }
        } catch (_) {
          if (_current(session) && lease == id) {
            _recover(tr("连接归属暂时无法核实，正在恢复远程桌面"));
          }
        }
      }
      if (safeResume && _current(session) && identical(_queue, queue)) {
        queue.resume();
      }
      if (identical(_handoffCandidate, resource)) _handoffCandidate = null;
      await resource?.release();
      if (_current(session) && lease == id) {
        _handoffPreparing = false;
        _handoffCommitting = false;
      }
    }
  }

  Future<Map<String, dynamic>> _waitHandoffCodec(
    DesktopCandidate candidate,
    String id,
    Map initial,
    bool Function() current,
  ) async {
    var video = Map<String, dynamic>.from(initial);
    var waiting = true;
    try {
      return await (() async {
        while (video['codecReady'] == false ||
            video['resize']?['state'] == 'updating') {
          if (!current() || !waiting) {
            throw const DesktopHandoffUnknown();
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
          if (!current() || !waiting) throw const DesktopHandoffUnknown();
          final reply = await candidate.connection.link
              .call('remote_desktop_video', {'leaseId': id})
              .timeout(const Duration(seconds: 3));
          checkDesktopAuthorization(reply);
          if (reply is! Map ||
              reply['error'] != null ||
              reply['video'] is! Map) {
            throw const DesktopHandoffUnknown();
          }
          video = Map<String, dynamic>.from(reply['video'] as Map);
          if (video['codec'] != 'h264' ||
              video['transport'] != initial['transport'] ||
              video['generation'] != initial['generation'] ||
              video['profile'] != initial['profile'] ||
              video['resize']?['instanceId'] !=
                  initial['resize']?['instanceId'] ||
              video['resize']?['applied'] != initial['resize']?['applied']) {
            throw const DesktopHandoffUnknown();
          }
        }
        final w = (video['width'] as num?)?.toInt() ?? 0,
            h = (video['height'] as num?)?.toInt() ?? 0;
        if (w < 2 || h < 2 || w > 3840 || h > 3840 || w * h > 3840 * 2160) {
          throw const DesktopHandoffUnknown();
        }
        return video;
      })().timeout(const Duration(seconds: 10));
    } finally {
      waiting = false;
    }
  }

  Future<RTCVideoRenderer> _createRtpRenderer(bool Function() current) =>
      ownedResource<RTCVideoRenderer>(
        create: () async {
          final value = RTCVideoRenderer();
          try {
            await value.initialize();
            return value;
          } catch (_) {
            await disposeDesktopRenderer(value);
            rethrow;
          }
        },
        current: current,
        release: disposeDesktopRenderer,
        timeout: const Duration(seconds: 3),
      );

  Future<void> _prepareRtpCandidate(
    DesktopCandidate candidate,
    bool Function() current,
  ) async {
    final renderer = await _createRtpRenderer(
      () => current() && !candidate.closed,
    );
    candidate.renderer = renderer;
    renderer.onFirstFrameRendered = () {
      if (!candidate.firstFrame.isCompleted) candidate.firstFrame.complete();
    };
    final stream = await candidate.desktop!.stream.timeout(
      const Duration(seconds: 5),
    );
    await renderer
        .setSrcObject(stream: stream)
        .timeout(const Duration(seconds: 3));
  }

  Future<bool> _adoptRtpCandidate(
    DesktopCandidate candidate,
    Map video,
    String id,
    bool Function() current,
  ) async {
    final renderer = candidate.takeRenderer();
    if (renderer == null) return false;
    final previous = _renderer,
        previousDecoder = _decoder,
        previousRelay = _relay,
        previousFrames = _relayFrames;
    _heldRenderer = previous;
    _heldDecoder = previousDecoder;
    _decoder = null;
    _relay = null;
    _relayFrames = null;
    unawaited(previousFrames?.cancel());
    previousRelay?.dispose();
    _renderer = renderer;
    renderer.onResize = () {
      if (current() &&
          identical(_renderer, renderer) &&
          _heldRenderer == null &&
          _heldDecoder == null &&
          renderer.videoWidth > 0) {
        setState(
          () => viewport.layout(
            viewport.view,
            Size(
              renderer.videoWidth.toDouble(),
              renderer.videoHeight.toDouble(),
            ),
          ),
        );
      }
    };
    try {
      final response = await withReplyTimeout(
        const Duration(seconds: 5),
        () => candidate.connection.link.call('remote_desktop_video', {
          'leaseId': id,
          'generation': video['generation'],
          'ready': true,
          'keyframe': true,
        }),
      ).timeout(const Duration(seconds: 5));
      if (!current()) return false;
      checkDesktopAuthorization(response);
      if (response is! Map ||
          response['video'] is! Map ||
          response['video']['generation'] != video['generation'] ||
          response['video']['ready'] != true) {
        throw const DesktopHandoffUnknown();
      }
      await candidate.firstFrame.future.timeout(const Duration(seconds: 5));
      if (!current() || !identical(_renderer, renderer)) return false;
      _heldRenderer = null;
      _heldDecoder = null;
      final width = renderer.videoWidth > 0
          ? renderer.videoWidth
          : (video['width'] as num).toInt();
      final height = renderer.videoHeight > 0
          ? renderer.videoHeight
          : (video['height'] as num).toInt();
      viewport.layout(viewport.view, Size(width.toDouble(), height.toDouble()));
      return true;
    } finally {
      if (identical(_heldRenderer, previous)) _heldRenderer = null;
      if (identical(_heldDecoder, previousDecoder)) _heldDecoder = null;
      unawaited(previousDecoder?.dispose());
      if (previous != null) unawaited(disposeDesktopRenderer(previous));
    }
  }

  void _recover(String message) {
    if (!mounted || _paused || _reconnect?.isActive == true) return;
    _stop();
    if (++_recoveries > 3) {
      setState(() {
        busy = false;
        error = tr("连接暂时无法恢复，请点击重新连接。");
      });
      return;
    }
    setState(() {
      error = message;
      busy = true;
    });
    _reconnect = Timer(Duration(seconds: _recoveries), () {
      if (mounted && !_paused) unawaited(_start());
    });
  }

  Future<void> _start() async {
    if (!mounted || _paused) return;
    _reconnect?.cancel();
    final session = ++_session;
    _cancelWaiters();
    setState(() {
      busy = true;
      error = null;
      _desktopPreparationNote = null;
    });
    try {
      final old = lease, api = _api;
      lease = null;
      _queue?.dispose();
      _queue = null;
      await _closeDesktop(
        after: old == null ? null : api?.desktopClose(old).then<void>((_) {}),
      );
      if (!_current(session)) return;
      if (h.link == null) throw StateError(tr("电脑离线，连接后再打开远程桌面"));
      await _openDesktop(session);
      if (!_current(session)) return;
      final link = _api!;
      final status = await link.deviceStatus();
      if (!_current(session)) return;
      locked = status['locked'] == true;
      if (locked) {
        _stop();
        if (mounted) setState(() => busy = false);
        return;
      }
      _requiresDesktopPreparation =
          status['desktopPreparationRequired'] == true;
      if (_requiresDesktopPreparation) {
        if (!await _prepareDesktop(session, link)) return;
      }
      displays = await link.displays();
      if (!_current(session)) return;
      if (displays.isEmpty) throw StateError(tr("电脑没有可用的显示器"));
      if (!displays.any((d) => d['id'] == monitor)) {
        monitor =
            (displays.firstWhere(
                      (d) => d['primary'] == true,
                      orElse: () => displays.first,
                    )['id']
                    as num)
                .toInt();
      }
      final relayVideo =
          !_videoDisabled && _desk == null && _relayVideoSupported;
      final wantVideo = !_videoDisabled && (_desk?.video == true || relayVideo);
      final opened = await link.desktopOpen(
        monitor!,
        video: wantVideo,
        videoMaxWidth: _videoWidth(),
        videoTransport: relayVideo ? 'binary' : null,
      );
      final id = opened['leaseId'] as String;
      if (!_current(session)) {
        unawaited(link.desktopClose(id).catchError((Object _) => null));
        return;
      }
      lease = id;
      _inputSequence = int.tryParse('${opened['inputSequence']}') ?? 0;
      _handoffEnabled = opened['handoff'] == true;
      _handoffRevision = '${opened['handoffRevision'] ?? '0'}';
      final batch = (opened['inputBatch'] as num?)?.toInt() ?? 0;
      _queue = RemoteInputQueue(
        (events) async {
          if (!_current(session) || lease != id) return;
          if (batch > 0) {
            await _api!.desktopInputBatch(id, ++_inputSequence, events);
          } else {
            for (final event in events) {
              if (!_current(session) || lease != id) return;
              await _api!.desktopInput(id, ++_inputSequence, event);
            }
          }
        },
        maxBatch: batch > 0 ? batch : 1,
        onError: (e) {
          if (_current(session) && lease == id) _inputFailed(e);
        },
      );
      _rate = FrameRateControl(
        maxFps: ((opened['maxFps'] as num?) ?? 5).toDouble().clamp(1, 30),
        initFps: 5,
      );
      frameId = null;
      frame = null;
      _videoStats = null;
      _lastDecoded = _sentAtProgress = _stalledTicks = 0;
      _gotVideoFrame = false;
      _watchConnection(session);
      final video = opened['video'];
      if (video is Map && video['transport'] == 'binary') {
        if (!await _startRelayVideo(video, id, link)) {
          await _fallback(session, tr("手机解码器不可用"));
          return;
        }
        if (_current(session)) unawaited(_videoLoop(session));
      } else if (video is Map) {
        if (!await _startVideo(video)) {
          if (_current(session)) await _fallback(session, tr("手机视频画面不可用"));
          return;
        }
        if (_current(session)) unawaited(_videoLoop(session));
      } else {
        if (!_current(session)) return;
        if (wantVideo) _videoNote = tr("视频画面不可用，使用图片模式");
        setState(() => busy = false);
        unawaited(_frames(session));
        return;
      }
    } on ResourceExpired {
      return;
    } on DesktopAuthorizationEnded catch (e) {
      if (_current(session)) _authorizationEnded(e);
      return;
    } on DesktopPreparationFailure catch (e) {
      if (_current(session)) {
        _stop();
        setState(() {
          busy = false;
          _desktopPreparationNote = null;
          error = '$e';
        });
      }
      return;
    } catch (e) {
      if (_current(session)) _recover(tr("暂时无法连接：{0}", [e]));
      return;
    }
    if (_current(session)) setState(() => busy = false);
  }

  Future<void> _fallback(int session, String reason) async {
    if (!_current(session)) return;
    _videoDisabled = true;
    _relayVideoOff = true;
    _videoNote = tr("{0}，已切换图片模式", [reason]);
    await _start();
  }

  Future<bool> _prepareDesktop(int session, HostLink link) async {
    setState(() {
      _desktopPreparationNote = tr("请在电脑上允许共享屏幕和键鼠控制");
    });
    try {
      final fresh = _freshDesktopPermission;
      final deadline = Stopwatch()..start();
      while (_current(session)) {
        final result = await link.call('remote_desktop_prepare', {
          'control': true,
          if (fresh) 'fresh': true,
        });
        if (!_current(session)) return false;
        if (result is! Map) throw StateError(tr("电脑授权回复无效，请重新连接"));
        if (result['state'] == 'ready') {
          setState(() {
            _desktopPreparationNote = null;
            _freshDesktopPermission = false;
          });
          return true;
        }
        if (result['state'] != 'pending') {
          throw StateError(tr("电脑未能准备屏幕共享，请重新连接并授权"));
        }
        if (deadline.elapsed >= const Duration(minutes: 2)) {
          throw StateError(tr("等待电脑授权超时，请重新连接后再试"));
        }
        await _wait(const Duration(milliseconds: 500));
      }
      return false;
    } catch (error) {
      if (!_current(session)) return false;
      throw DesktopPreparationFailure(error);
    }
  }

  void _stop() {
    ++_session;
    _cancelWaiters();
    _reconnect?.cancel();
    final l = lease, api = _api;
    lease = null;
    _queue?.dispose();
    _queue = null;
    unawaited(
      _closeDesktop(
        after: l == null ? null : api?.desktopClose(l).then<void>((_) {}),
      ),
    );
  }

  /// Relay video: a platform decoder fed by the binary `video` messages of
  /// this lease. Successful frames wait for native decoded output; discarded
  /// frames release their window and request a keyframe.
  Future<bool> _startRelayVideo(
    Map video,
    String id,
    HostLink link, {
    bool resizing = false,
    H264Decoder? prepared,
  }) async {
    final session = _session;
    final screenGeneration = _screenGeneration;
    bool current() =>
        _current(session) &&
        _screenGeneration == screenGeneration &&
        lease == id;
    final width = ((video['width'] as num?) ?? 1920).toInt();
    final height = ((video['height'] as num?) ?? 1080).toInt();
    final H264Decoder decoder;
    if (prepared != null) {
      decoder = prepared;
    } else {
      try {
        final created = await ownedResource<H264Decoder?>(
          create: () => H264Decoder.create(width: width, height: height),
          current: current,
          release: (value) async {
            await value?.dispose();
          },
          timeout: const Duration(seconds: 3),
        );
        if (created == null) return false;
        decoder = created;
      } on TimeoutException {
        return false;
      }
    }
    if (!current()) {
      await decoder.dispose();
      return false;
    }
    final previousDecoder = _decoder,
        previousRelay = _relay,
        previousFrames = _relayFrames,
        previousRenderer = _renderer;
    final firstDecoded = Completer<void>();
    if (resizing) {
      _heldDecoder = previousDecoder;
      _heldRenderer = previousRenderer;
      _renderer = null;
    }
    late final RelayVideoReceiver relay;
    relay = RelayVideoReceiver(
      onLiveChanged: (live) {
        if (!current() || !identical(_relay, relay)) return;
        _syncInputPicture();
        setState(() {
          if (!live && !_pipelineRecovery.active) {
            _videoNote = tr("画面正在恢复");
          } else if (live && _videoNote == tr("画面正在恢复")) {
            _videoNote = null;
          }
        });
      },
      decode: (data, keyframe) async {
        await decoder.decode(data, keyframe: keyframe);
        if (!firstDecoded.isCompleted) firstDecoded.complete();
        if (_decoder == decoder) _relayBytes += data.length;
      },
      control: ({int? ack, bool keyframe = false}) async {
        final started = DateTime.now();
        await link.call('remote_desktop_video', {
          'leaseId': id,
          'ack': ?ack?.toString(),
          'keyframe': keyframe,
        });
        _lastRtt = DateTime.now().difference(started).inMilliseconds;
      },
    );
    _decoder = decoder;
    _relay = relay;
    _syncInputPicture();
    _relayFrames = link.events
        .where(
          (e) =>
              e['type'] == 'video' &&
              e['leaseId'] == id &&
              (video['generation'] == null ||
                  e['generation'] == video['generation']),
        )
        .listen(relay.onFrame);
    _video = true;
    _gotVideoFrame = false;
    if (!resizing) _configureCursor(video: video);
    viewport.layout(viewport.view, Size(width.toDouble(), height.toDouble()));
    try {
      if (video['clientReadyRequired'] == true) {
        try {
          final response = await withReplyTimeout(
            const Duration(seconds: 5),
            () => link.call('remote_desktop_video', {
              'leaseId': id,
              'ready': true,
              'generation': video['generation'],
              'keyframe': true,
              'includeCursor': true,
              'knownCursorShapeId': ?_cursorState.shapeId,
            }),
          );
          if (!current() || _decoder != decoder) return false;
          checkDesktopAuthorization(response);
          if (response is! Map ||
              response['relay'] is! Map ||
              response['relay']['ready'] != true ||
              response['relay']['generation'] != video['generation']) {
            throw StateError(tr("电脑未确认当前画面的就绪状态"));
          }
          _cursorState.update(response, DateTime.now());
        } catch (_) {
          if (!current() || _decoder != decoder) return false;
          rethrow;
        }
      }
      if (resizing) {
        await firstDecoded.future.timeout(const Duration(seconds: 3));
        if (!current() || _decoder != decoder) return false;
      } else {
        _resolutionCandidate = null;
        _resolution.start(video);
      }
      _activeVideoDescription = Map.from(video);
      return true;
    } finally {
      if (resizing) {
        if (identical(_heldDecoder, previousDecoder)) _heldDecoder = null;
        unawaited(previousFrames?.cancel());
        previousRelay?.dispose();
        unawaited(previousDecoder?.dispose());
        if (identical(_heldRenderer, previousRenderer)) _heldRenderer = null;
        if (previousRenderer != null) {
          unawaited(disposeDesktopRenderer(previousRenderer));
        }
      }
    }
  }

  /// Attaches the screen track to a renderer; false falls back to pulls.
  Future<bool> _startVideo(Map video) async {
    final session = _session;
    final desk = _desk;
    if (desk == null) return false;
    bool current() => _current(session) && identical(desk, _desk);
    final RTCVideoRenderer renderer;
    try {
      renderer = await _createRtpRenderer(current);
    } catch (_) {
      return false;
    }
    try {
      final stream = await desk.stream.timeout(const Duration(seconds: 5));
      if (!current()) {
        await disposeDesktopRenderer(renderer);
        return false;
      }
      await renderer
          .setSrcObject(stream: stream)
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      await disposeDesktopRenderer(renderer);
      return false;
    }
    if (!current()) {
      await disposeDesktopRenderer(renderer);
      return false;
    }
    renderer.onResize = () {
      if (!current() || _renderer != renderer || renderer.videoWidth == 0) {
        return;
      }
      setState(() {
        _gotVideoFrame = true;
        viewport.layout(
          viewport.view,
          Size(renderer.videoWidth.toDouble(), renderer.videoHeight.toDouble()),
        );
      });
    };
    _renderer = renderer;
    _resolutionCandidate = null;
    _resolution.start(video);
    _activeVideoDescription = Map.from(video);
    _video = true;
    _gotVideoFrame = false;
    _configureCursor(video: video);
    viewport.layout(
      viewport.view,
      Size(
        ((video['width'] as num?) ?? 16).toDouble(),
        ((video['height'] as num?) ?? 10).toDouble(),
      ),
    );
    return true;
  }

  /// Keeps the lease alive (video has no frame pulls), asks for a keyframe
  /// until the first frame shows, and samples WebRTC stats for the status.
  Future<void> _videoLoop(int session) async {
    while (_current(session) && _video) {
      await _wait(const Duration(seconds: 1));
      final l = lease, api = _api, desk = _desk, decoder = _decoder;
      if (!_current(session) || l == null || api == null) return;
      if (busy || _handoffCommitting) continue;
      final screenGeneration = _screenGeneration;
      try {
        final remote =
            await api.call('remote_desktop_video', {
                  'leaseId': l,
                  if (_gotVideoFrame && !gestures.active && !_handoffPreparing)
                    ..._resolution.request(_resolutionClock.elapsed),
                  'keyframe': !_gotVideoFrame || _stalledTicks >= 2,
                  'knownCursorShapeId': ?_cursorState.shapeId,
                  'includeCursor': true,
                })
                as Map;
        if (!_current(session)) return;
        if (screenGeneration != _screenGeneration || busy) continue;
        checkDesktopAuthorization(remote);
        if (remote['handoffRevision'] != null) {
          _observeHandoffRevision(remote['handoffRevision']);
        }
        _cursorState.update(remote, DateTime.now());
        if (remote['error'] != null) {
          await _fallback(session, tr("电脑视频编码异常"));
          return;
        }
        final description = remote['video'];
        final pictureChanging =
            description is Map &&
            (description['codecReady'] == false ||
                (description['resize'] is Map &&
                    description['resize']['state'] == 'updating') ||
                (_resolution.newer(description) &&
                    description['generation'] !=
                        _activeVideoDescription?['generation']));
        final recoveryExpired = _pipelineRecovery.observe(
          remote['recovery'],
          widget.recoveryClock?.call() ?? _resolutionClock.elapsed,
          scope: (session, screenGeneration),
          changing: pictureChanging,
        );
        _syncInputPicture();
        if (recoveryExpired) {
          await _fallback(session, tr("电脑画面恢复超时"));
          return;
        }
        if (_pipelineRecovery.active &&
            (description is! Map ||
                description['codecReady'] == false ||
                (description['resize'] is Map &&
                    description['resize']['state'] == 'updating'))) {
          _videoNote = tr("电脑画面正在恢复");
          _stalledTicks = 0;
          if (_current(session)) setState(() {});
          continue;
        }
        if (_pipelineRecovery.active) {
          _videoNote = tr("电脑画面正在恢复");
        } else if (_videoNote == tr("电脑画面正在恢复")) {
          _videoNote = null;
        }
        if (description is Map && _resolution.newer(description)) {
          final previous = _activeVideoDescription;
          if (decoder != null &&
              description['generation'] != previous?['generation']) {
            bool adopted;
            try {
              adopted = await _startRelayVideo(
                description,
                l,
                api,
                resizing: true,
              );
            } on DesktopAuthorizationEnded {
              rethrow;
            } catch (_) {
              if (!_current(session) || screenGeneration != _screenGeneration) {
                continue;
              }
              await _fallback(session, tr("清晰度调整后解码器不可用"));
              return;
            }
            if (!_current(session) || screenGeneration != _screenGeneration) {
              continue;
            }
            if (!adopted) {
              await _fallback(session, tr("清晰度调整后解码器不可用"));
              return;
            }
            _lastDecoded = _sentAtProgress = _stalledTicks = 0;
            _gotVideoFrame = true;
            _pipelineRecovery.decoded();
            _syncInputPicture();
            if (_videoNote == tr("电脑画面正在恢复")) _videoNote = null;
          }
          if (decoder == null &&
              desk != null &&
              description['clientReadyRequired'] == true &&
              description['ready'] != true) {
            final previousReports = await desk.peer.getStats().timeout(
              const Duration(seconds: 3),
            );
            if (!_current(session) || screenGeneration != _screenGeneration) {
              continue;
            }
            final beforeReady = parseVideoStats([
              for (final report in previousReports)
                (report.type, report.values),
            ], DateTime.now());
            if (beforeReady != null) _lastDecoded = beforeReady.framesDecoded;
            final ack = await api
                .call('remote_desktop_video', {
                  'leaseId': l,
                  'generation': description['generation'],
                  'ready': true,
                  'keyframe': true,
                })
                .timeout(const Duration(seconds: 5));
            if (!_current(session) || screenGeneration != _screenGeneration) {
              continue;
            }
            checkDesktopAuthorization(ack);
            if (ack is! Map ||
                ack['video'] is! Map ||
                ack['video']['generation'] != description['generation'] ||
                ack['video']['ready'] != true) {
              throw StateError(tr("电脑画面代次尚未确认"));
            }
            _stalledTicks = 0;
          }
          _resolution.accept(description);
          _activeVideoDescription = Map.from(description);
          viewport.layout(
            viewport.view,
            Size(
              (description['width'] as num).toDouble(),
              (description['height'] as num).toDouble(),
            ),
          );
          if (_current(session)) setState(() {});
          if (decoder != _decoder) continue;
        }
        if (decoder != null &&
            _binaryRoute != ConnectionRoute.relay &&
            !_handoffPreparing &&
            ++_routeProbeTicks % 10 == 0) {
          try {
            final status = await api
                .call('transport_status', null)
                .timeout(const Duration(seconds: 2));
            if (_current(session) &&
                screenGeneration == _screenGeneration &&
                identical(api, _api) &&
                status is Map) {
              final observed = ConnectionRoute.fromStatus(status);
              if (observed != _binaryRoute) {
                _binaryRoute = observed;
                _scheduleHandoff(session);
              }
            }
          } catch (_) {
            /* Advisory route sampling must not end a healthy video lease. */
          }
        }
        var count = _lastDecoded;
        if (decoder != null) {
          try {
            count = await decoder.decodedFrames().timeout(
              const Duration(seconds: 3),
            );
          } catch (_) {
            if (screenGeneration != _screenGeneration || busy) continue;
            if (decoder != _decoder) continue;
            await _fallback(session, tr("手机解码器停止响应"));
            return;
          }
          if (!_current(session)) return;
          if (screenGeneration != _screenGeneration || busy) continue;
          if (decoder != _decoder) continue;
          _videoFps = (count - _lastDecoded).clamp(0, 120).toDouble();
          _videoKbps = _relayBytes / 1024;
          _relayBytes = 0;
        } else if (desk != null) {
          final List<StatsReport> reports;
          try {
            reports = await desk.peer.getStats().timeout(
              const Duration(seconds: 3),
            );
          } catch (_) {
            if (!_current(session)) return;
            if (screenGeneration != _screenGeneration ||
                busy ||
                !identical(desk, _desk)) {
              continue;
            }
            await _fallback(session, tr("手机视频状态读取失败"));
            return;
          }
          if (!_current(session)) return;
          if (screenGeneration != _screenGeneration ||
              busy ||
              !identical(desk, _desk)) {
            continue;
          }
          final sample = parseVideoStats([
            for (final r in reports) (r.type, r.values),
          ], DateTime.now());
          if (sample != null) {
            count = sample.framesDecoded;
            _videoFps = sample.decodedFps(_videoStats);
            _videoKbps = sample.kbps(_videoStats);
            if (sample.rttMs != null) _lastRtt = sample.rttMs!.round();
            _videoStats = sample;
          }
        }
        final sent = (remote['frames'] as num?)?.toInt() ?? 0;
        if (count > _lastDecoded && sent > 0) {
          if (_pipelineRecovery.active) {
            _pipelineRecovery.decoded();
            _syncInputPicture();
            if (_videoNote == tr("电脑画面正在恢复")) _videoNote = null;
          }
          _gotVideoFrame = true;
          _stalledTicks = 0;
          _sentAtProgress = sent;
          _recoveries = 0;
        } else if (!_gotVideoFrame || sent > _sentAtProgress) {
          _stalledTicks++;
        }
        _lastDecoded = count;
        if (_stalledTicks >= (_gotVideoFrame ? 5 : 8)) {
          await _fallback(
            session,
            _gotVideoFrame ? tr("视频解码停止响应") : tr("视频首帧等待超时"),
          );
          return;
        }
        if (_current(session)) setState(() {});
      } catch (e) {
        if (!_current(session)) return;
        if (screenGeneration != _screenGeneration || busy) continue;
        if (e is DesktopAuthorizationEnded) {
          _authorizationEnded(e);
        } else if ((e is ProtocolException ? e.rawMessage : '$e').contains(
              '锁定',
            ) ||
            '$e'.toLowerCase().contains('locked')) {
          _stop();
          setState(() {
            locked = true;
            busy = false;
          });
        } else {
          _recover(tr("远控连接中断，正在重新连接"));
        }
        return;
      }
    }
  }

  /// Encoded width for video: what the phone screen can show at 2× zoom,
  /// within the display and a 1920 cap (the PC encodes this once per open).
  int _videoWidth() {
    final ratio = MediaQuery.devicePixelRatioOf(context);
    return (MediaQuery.sizeOf(context).width * ratio).round().clamp(640, 1920);
  }

  void _scheduleResolution() {
    if (!_video || !_resolution.supported || busy || !viewport.ready) return;
    final width = _resolution.widthFor(
      viewport,
      MediaQuery.devicePixelRatioOf(context),
    );
    if (width == _resolutionCandidate) return;
    _resolutionCandidate = width;
    _resolutionDebounce?.cancel();
    final session = _session, generation = _screenGeneration;
    _resolutionDebounce = Timer(const Duration(milliseconds: 350), () {
      if (_current(session) && _screenGeneration == generation && !busy) {
        _resolution.want(width);
      }
    });
  }

  void _authorizationEnded(Object reason) {
    _stop();
    if (mounted) {
      setState(() {
        busy = false;
        _desktopPreparationNote = null;
        error = '$reason';
      });
    }
  }

  void _inputFailed(Object e) {
    if (!mounted) return;
    if (e is DesktopAuthorizationEnded) {
      _authorizationEnded(e);
      return;
    }
    showError(context, e);
    setState(() {
      _stop();
      error = '$e';
    });
  }

  /// One frame request at a time; the controller paces the next one.
  Future<void> _frames(int session) async {
    while (mounted && session == _session) {
      if (busy) {
        await _wait(const Duration(milliseconds: 50));
        continue;
      }
      final link = _api, l = lease;
      if (link == null || l == null) return;
      final screenGeneration = _screenGeneration, display = monitor;
      final started = DateTime.now();
      var roundTrip = Duration.zero;
      try {
        final f = await link.desktopFrame(
          l,
          maxWidth: _wantedWidth(),
          quality: _rate.quality,
          knownFrameId: frameId,
          knownCursorShapeId: _cursorState.shapeId,
        );
        if (!mounted || session != _session) return;
        if (busy ||
            screenGeneration != _screenGeneration ||
            display != monitor ||
            (f['monitorId'] != null && f['monitorId'] != monitor)) {
          await _wait(const Duration(milliseconds: 50));
          continue;
        }
        roundTrip = DateTime.now().difference(started);
        _rate.onFrame(roundTrip.inMilliseconds);
        _measure(f, roundTrip);
        _recoveries = 0;
        setState(() => _apply(f));
      } catch (e) {
        if (!mounted || session != _session) return;
        if (busy || screenGeneration != _screenGeneration) {
          await _wait(const Duration(milliseconds: 50));
          continue;
        }
        if (e is DesktopAuthorizationEnded) {
          _authorizationEnded(e);
          return;
        }
        final message = '$e';
        if (!message.contains('过于频繁') &&
            !message.toLowerCase().contains('too many requests')) {
          if (message.contains('锁定') ||
              message.toLowerCase().contains('locked')) {
            _stop();
            setState(() {
              locked = true;
              busy = false;
            });
          } else {
            _recover(tr("画面连接中断，正在重新连接"));
          }
          return;
        }
      }
      await _wait(_rate.nextDelay(roundTrip));
    }
  }

  void _apply(Map<String, dynamic> f) {
    frameId = f['frameId'] as String?;
    if (f['unchanged'] != true) {
      frame = base64.decode(f['bytes'] as String);
      viewport.layout(
        viewport.view,
        Size((f['width'] as num).toDouble(), (f['height'] as num).toDouble()),
      );
    }
    _cursorState.update(f, DateTime.now());
  }

  void _measure(Map<String, dynamic> f, Duration roundTrip) {
    final now = DateTime.now();
    _lastRtt = roundTrip.inMilliseconds;
    if (f['unchanged'] != true) {
      _frameTimes.add(now);
      _bytesWindow += (f['bytes'] as String? ?? '').length * 3 ~/ 4;
    }
    _frameTimes.removeWhere(
      (t) => now.difference(t) > const Duration(seconds: 1),
    );
    final window = now.difference(_windowStart);
    if (window >= const Duration(seconds: 1)) {
      _kbps = _bytesWindow / 1024 / (window.inMilliseconds / 1000);
      _bytesWindow = 0;
      _windowStart = now;
    }
  }

  /// Resolution the current zoom can show, in 160 px steps so small view
  /// changes keep matching the PC's last frame.
  int _wantedWidth() {
    final d = displays.where((d) => d['id'] == monitor).firstOrNull;
    final native = d == null
        ? 0
        : ((d['width'] as num) * ((d['scale'] as num?) ?? 1)).round();
    final width = viewport.wantedWidth(
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      nativeWidth: native,
      max: 1920,
    );
    return ((width / 160).ceil() * 160).clamp(320, 2560);
  }

  // ── Input ──────────────────────────────────────────────────────────────

  void _configureCursor({Map? video}) {
    _cursorExpiry?.cancel();
    _cursorExpiry = null;
    _cursorState.configure(video: video);
  }

  void _input(Map<String, dynamic> event) {
    if (!busy) _queue?.add(event);
  }

  bool get _pictureReady => !_pipelineRecovery.active && (_relay?.live ?? true);

  void _syncInputPicture() => _queue?.setViewReady(_pictureReady);

  void _moveTo(Offset local) {
    if (!_pictureReady) return;
    final remote = viewport.toRemote(local);
    _cursorState.move(remote, DateTime.now());
    _cursorExpiry?.cancel();
    if (_cursorState.predictionOnly) {
      _cursorExpiry = Timer(RemoteCursor.predictionWindow, () {
        _cursorState.expirePrediction();
        if (mounted) setState(() {});
      });
    }
    _input(moveEvent(remote));
  }

  void _button(String button, String direction) =>
      _input({'kind': 'button', 'button': button, 'direction': direction});

  void _gesture(RemoteGesture g) {
    if (lease == null || busy) return;
    if (!_pictureReady &&
        g is! RemoteDragEnd &&
        g is! RemoteZoom &&
        g is! RemotePan) {
      return;
    }
    switch (g) {
      case RemoteClick(:final at, :final button):
        if (!viewport.contains(at)) return;
        _moveTo(at);
        _withModifiers(() {
          _button(button, 'press');
          _button(button, 'release');
        });
      case RemoteHold():
        HapticFeedback.mediumImpact();
      case RemoteDragStart(:final at):
        _moveTo(at);
        _pressModifiers();
        _button('left', 'press');
      case RemoteDragUpdate(:final at):
        _moveTo(at);
        if (viewport.zoom > 1) viewport.ensureVisible(_cursor!);
      case RemoteDragEnd(:final at):
        _moveTo(at);
        _button('left', 'release');
        _releaseModifiers();
      case RemoteScroll(:final at, :final delta):
        if (_scrollRest == Offset.zero) _moveTo(at);
        // Content follows the fingers, as on the phone itself.
        final total = _scrollRest - delta;
        final x = (total.dx / _scrollStep).truncate();
        final y = (total.dy / _scrollStep).truncate();
        _scrollRest = total - Offset(x * _scrollStep, y * _scrollStep);
        if (x != 0 || y != 0) {
          _input({
            'kind': 'scroll',
            'x': x.clamp(-100, 100),
            'y': y.clamp(-100, 100),
          });
        }
      case RemoteZoom(:final focal, :final factor, :final pan):
        viewport.zoomAt(focal, factor);
        viewport.panBy(pan);
      case RemotePan(:final delta):
        viewport.panBy(delta);
    }
    setState(() {});
  }

  void _pointer(PointerEvent e) {
    final t = e.timeStamp;
    switch (e) {
      case PointerDownEvent():
        _scrollRest = Offset.zero;
        gestures.down(e.pointer, e.localPosition, t);
      case PointerMoveEvent():
        gestures.move(e.pointer, e.localPosition, t);
      case PointerUpEvent():
        gestures.up(e.pointer, t);
      case PointerCancelEvent():
        gestures.cancel(e.pointer);
      default:
        return;
    }
    _longPress?.cancel();
    final due = gestures.longPressDue;
    if (due != null) {
      _longPress = Timer(due - t, () => gestures.tick(due));
    }
  }

  // Sticky modifiers: tapped once, they apply to the next click, drag or key.
  void _pressModifiers() {
    for (final m in _modifiers) {
      _input({'kind': 'key', 'key': m, 'direction': 'press'});
    }
  }

  void _releaseModifiers() {
    for (final m in _modifiers) {
      _input({'kind': 'key', 'key': m, 'direction': 'release'});
    }
    if (_modifiers.isNotEmpty && mounted) setState(_modifiers.clear);
  }

  void _withModifiers(void Function() body) {
    _pressModifiers();
    body();
    _releaseModifiers();
  }

  void _key(String key) => _withModifiers(() {
    _input({'kind': 'key', 'key': key, 'direction': 'press'});
    _input({'kind': 'key', 'key': key, 'direction': 'release'});
  });

  /// The hidden field always holds [_sentinel], so a backspace on an "empty"
  /// field is still seen; composing (e.g. pinyin) text waits until committed.
  static const _sentinel = '​​';
  void _typed(TextEditingValue v) {
    if (busy) return;
    if (v.composing.isValid && !v.composing.isCollapsed) return;
    final text = v.text;
    if (text == _sentinel) return;
    if (text.length < _sentinel.length && _sentinel.startsWith(text)) {
      for (var i = text.length; i < _sentinel.length; i++) {
        _key('backspace');
      }
    } else {
      final typed = text.replaceAll('​', '');
      if (typed.isNotEmpty) {
        if (_modifiers.isNotEmpty && typed.runes.length == 1) {
          _key(typed.toLowerCase());
        } else {
          _input({'kind': 'text', 'text': typed});
        }
      }
    }
    keyboard.value = const TextEditingValue(
      text: _sentinel,
      selection: TextSelection.collapsed(offset: _sentinel.length),
    );
  }

  Future<void> _select(int id) async {
    final sessionBefore = _session;
    if (_handoffCommitting) await _handoffWork;
    if (!_current(sessionBefore)) return;
    final l = lease, api = _api, session = _session;
    if (l == null || api == null || busy) return;
    setState(() {
      busy = true;
      _screenGeneration++;
      _modifiers.clear();
      _scrollRest = Offset.zero;
      _configureCursor();
    });
    keyFocus.unfocus();
    keyboard.value = const TextEditingValue(
      text: _sentinel,
      selection: TextSelection.collapsed(offset: _sentinel.length),
    );
    try {
      await _queue?.idle;
      if (!_current(session)) return;
      if (_desk != null && _video && _decoder == null) {
        // A fresh screen peer also discards old RTP/jitter-buffer output,
        // including switches between displays with identical dimensions.
        setState(() => monitor = id);
        await _start();
        return;
      }
      final selected = await api.desktopSelect(l, id) as Map;
      if (!_current(session)) return;
      final video = selected['video'];
      if (_decoder != null && video is Map) {
        _closeRelayVideo();
        if (!await _startRelayVideo(video, l, api)) {
          await _fallback(session, tr("切屏后解码器不可用"));
          return;
        }
        if (video['clientReadyRequired'] != true) {
          await api.call('remote_desktop_video', {
            'leaseId': l,
            'keyframe': true,
          });
        }
      }
      if (!_current(session)) return;
      setState(() {
        monitor = id;
        frameId = null;
        if (video is! Map) frame = null;
        if (video is Map && video['width'] is num && video['height'] is num) {
          viewport.layout(
            viewport.view,
            Size(
              (video['width'] as num).toDouble(),
              (video['height'] as num).toDouble(),
            ),
          );
        } else {
          final display = displays.where((d) => d['id'] == id).firstOrNull;
          if (display != null) {
            viewport.layout(
              viewport.view,
              Size(
                (display['width'] as num).toDouble(),
                (display['height'] as num).toDouble(),
              ),
            );
          }
        }
        _lastDecoded = 0;
        _sentAtProgress = _stalledTicks = 0;
        _gotVideoFrame = false;
        viewport.fit();
      });
    } catch (e) {
      if (_current(session)) {
        if (e is DesktopAuthorizationEnded) {
          _authorizationEnded(e);
        } else {
          _recover(tr("切换屏幕失败，正在恢复连接"));
        }
      }
    } finally {
      if (_current(session)) setState(() => busy = false);
    }
  }

  void _cancelClipboard() {
    ++_clipboardEpoch;
    _clipboardTransfer?.cancel();
    _clipboardTransfer = null;
    final link = _clipboardLink;
    _clipboardLink = null;
    unawaited(link?.close().catchError((Object _) {}));
    _clipboardBusy = false;
    _clipboardWriteStarted = false;
    _clipboardProgress = null;
  }

  Future<void> _clipboard() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (s) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.upload_outlined),
              title: Text(tr("发送文字到电脑")),
              subtitle: Text(tr("编辑后发送到电脑剪贴板")),
              onTap: () => Navigator.pop(s, 'send'),
            ),
            ListTile(
              leading: const Icon(Icons.download_outlined),
              title: Text(tr("从电脑获取文字")),
              subtitle: Text(tr("读取电脑剪贴板，复制到这部手机")),
              onTap: () => Navigator.pop(s, 'get'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted || _paused || _clipboardBusy) return;
    if (action == 'get') {
      final text = await _clipboardText();
      if (text != null && mounted) await showReceivedText(context, text);
      return;
    }
    // Read only after the explicit action; iOS may ask to allow pasting.
    String initial = '';
    try {
      initial = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
    } catch (_) {}
    if (!mounted) return;
    final draft = await showClipboardComposer(
      context,
      initial: initial,
      canPaste: _queue != null && !locked,
    );
    if (draft == null || !mounted || _paused || _clipboardBusy) return;
    await _clipboardText(send: draft.text, paste: draft.paste);
  }

  /// Sends [send] to the computer clipboard, or returns the computer's text
  /// after copying it to the phone. Null when it did not complete.
  Future<String?> _clipboardText({String? send, bool paste = false}) async {
    final business = h.link;
    if (business is! AdaptiveHostLink) {
      showError(context, tr("当前连接不支持独立剪贴板传输，请更新电脑和 App 后重试"));
      return null;
    }
    final epoch = ++_clipboardEpoch;
    bool current() => mounted && !_paused && epoch == _clipboardEpoch;
    final sending = send != null;
    setState(() {
      _clipboardBusy = true;
      _clipboardSending = sending;
      _clipboardProgress = null;
    });
    HostLink? link;
    try {
      link = await openClipboardLink(business, current: current, direct: false);
      if (!current()) throw const ClipboardCancelled();
      _clipboardLink = link;
      final caps = await link.call('remote_capabilities', null);
      if (caps is! Map ||
          (caps['clipboardTransfer'] as Map?)?['version'] != 1) {
        throw tr("电脑尚不支持分块剪贴板传输，请更新电脑客户端");
      }
      if (!current()) throw const ClipboardCancelled();
      final transfer = ClipboardTransfer(
        link,
        current: current,
        onProgress: (done, total) {
          if (current()) setState(() => _clipboardProgress = done / total);
        },
      );
      _clipboardTransfer = transfer;
      if (sending) {
        await transfer.send(
          Uint8List.fromList(utf8.encode(send)),
          ClipboardKind.text,
        );
        if (!mounted || !current()) return null;
        final pasteKey = switch (caps['platform']) {
          'macos' => 'meta',
          'windows' || 'linux' => 'ctrl',
          _ => null,
        };
        if (paste && pasteKey != null && _queue != null) {
          _pasteOnComputer(pasteKey);
          showError(context, tr("已粘贴到电脑"));
        } else if (paste) {
          showError(context, tr("已发送到电脑剪贴板。更新电脑端后可自动粘贴"));
        } else {
          showError(context, tr("已发送到电脑剪贴板，可在电脑上粘贴"));
        }
        return send;
      }
      final Uint8List bytes;
      try {
        bytes = await transfer.receive(ClipboardKind.text);
      } on ProtocolException catch (e) {
        // Older computers report an empty clipboard as "empty or too large".
        if (e.rawMessage == '剪贴板没有文字' ||
            e.rawMessage == '剪贴板内容为空或过大（图片限 16 MB，文字限 1 MB）') {
          throw tr("电脑剪贴板里没有文字，先在电脑上复制后再试");
        }
        rethrow;
      }
      if (!current()) throw const ClipboardCancelled();
      final text = utf8.decode(bytes, allowMalformed: true);
      if (text.isEmpty) throw tr("电脑剪贴板里没有文字，先在电脑上复制后再试");
      _clipboardWriteStarted = true;
      await Clipboard.setData(ClipboardData(text: text));
      return current() ? text : null;
    } on ClipboardCancelled {
      // Background/route closure never resumes a write.
    } on ResourceExpired {
      // A connection that arrives after cancellation is closed by its owner.
    } catch (e) {
      if (mounted && current()) {
        showError(context, switch (e) {
          PlatformException() => e.message ?? tr("剪贴板操作未完成"),
          TimeoutException() => tr("连接超时，请检查网络后重试。"),
          _ => e,
        });
      }
    } finally {
      if (link != null) unawaited(link.close().catchError((Object _) {}));
      if (epoch == _clipboardEpoch) {
        _clipboardLink = null;
        _clipboardTransfer = null;
        if (mounted) {
          setState(() {
            _clipboardBusy = false;
            _clipboardWriteStarted = false;
            _clipboardProgress = null;
          });
        }
      }
    }
    return null;
  }

  /// ⌘V / Ctrl+V on the computer, ignoring any sticky modifier chips.
  void _pasteOnComputer(String modifier) {
    if (_modifiers.isNotEmpty) setState(_modifiers.clear);
    for (final (key, direction) in [
      (modifier, 'press'),
      ('v', 'press'),
      ('v', 'release'),
      (modifier, 'release'),
    ]) {
      _input({'kind': 'key', 'key': key, 'direction': direction});
    }
  }

  String get _status {
    if (lease == null) return locked ? tr("电脑已锁定") : tr("未连接");
    if (_video) {
      return 'H.264${_decoder != null ? ' · ${_binaryRoute.label}' : ''} · '
          '${_videoFps.round()} fps · $_lastRtt ms · '
          '${_videoKbps.toStringAsFixed(0)} KB/s';
    }
    if (frame == null) return tr("连接中");
    return '${_frameTimes.length} fps · $_lastRtt ms · '
        '${_kbps.toStringAsFixed(0)} KB/s';
  }

  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final c = context.dc;
    return Scaffold(
      backgroundColor: c.canvas,
      appBar: DetailBar(
        title: tr("远程桌面"),
        subtitle: '${h.name} · $_status',
        actions: [
          if (displays.length > 1 || _requiresDesktopPreparation)
            PopupMenuButton<int>(
              enabled: !busy,
              tooltip: tr("切换屏幕"),
              icon: const Icon(Icons.monitor_outlined),
              onSelected: (display) {
                if (display == -1) {
                  _freshDesktopPermission = true;
                  unawaited(_start());
                } else {
                  unawaited(_select(display));
                }
              },
              itemBuilder: (_) => [
                for (final (i, d) in displays.indexed)
                  PopupMenuItem(
                    value: (d['id'] as num).toInt(),
                    child: Text(
                      tr("屏幕 {0}{1}", [
                        i + 1,
                        d['primary'] == true ? tr("（主）") : '',
                      ]),
                    ),
                  ),
                if (_requiresDesktopPreparation) ...[
                  const PopupMenuDivider(),
                  PopupMenuItem(value: -1, child: Text(tr("重新选择共享屏幕"))),
                ],
              ],
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(child: _screen(c)),
            if (_clipboardBusy)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _clipboardSending ? tr("正在发送到电脑…") : tr("正在从电脑获取…"),
                          ),
                          LinearProgressIndicator(value: _clipboardProgress),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        final unknown =
                            _clipboardWriteStarted ||
                            (_clipboardTransfer?.mayHaveWritten ?? false);
                        setState(_cancelClipboard);
                        if (unknown) {
                          showError(context, tr("已停止等待，复制操作可能已完成，请核实剪贴板"));
                        }
                      },
                      child: Text(tr("取消")),
                    ),
                  ],
                ),
              ),
            // Kept laid out (1×1, invisible) so the system keyboard attaches.
            SizedBox(
              width: 1,
              height: 1,
              child: Opacity(
                opacity: 0,
                child: TextField(
                  enabled: !busy,
                  controller: keyboard,
                  focusNode: keyFocus,
                  autocorrect: false,
                  enableSuggestions: false,
                  keyboardType: TextInputType.visiblePassword,
                  onChanged: (_) => _typed(keyboard.value),
                  onSubmitted: (_) {
                    _key('enter');
                    keyFocus.requestFocus();
                  },
                ),
              ),
            ),
            if (lease != null) IgnorePointer(ignoring: busy, child: _keys()),
            Container(
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: c.line)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Tool(
                    icon: Icons.keyboard_outlined,
                    label: tr("键盘"),
                    onTap: lease == null || busy
                        ? null
                        : () => keyFocus.hasFocus
                              ? keyFocus.unfocus()
                              : keyFocus.requestFocus(),
                  ),
                  _Tool(
                    icon: gestures.panMode
                        ? Icons.pan_tool
                        : Icons.pan_tool_outlined,
                    label: gestures.panMode ? tr("移动画面") : tr("操作电脑"),
                    onTap: lease == null || busy
                        ? null
                        : () => setState(
                            () => gestures.panMode = !gestures.panMode,
                          ),
                  ),
                  _Tool(
                    icon: Icons.fit_screen_outlined,
                    label: tr("适应屏幕"),
                    onTap: lease == null || busy
                        ? null
                        : () => setState(viewport.fit),
                  ),
                  _Tool(
                    icon: Icons.content_paste,
                    label: tr("剪贴板"),
                    onTap: h.link == null || _paused || _clipboardBusy
                        ? null
                        : _clipboard,
                  ),
                  _Tool(
                    icon: Icons.refresh,
                    label: tr("重新连接"),
                    onTap: busy
                        ? null
                        : () {
                            _recoveries = 0;
                            _videoDisabled = _relayVideoOff = false;
                            unawaited(_start());
                          },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _keys() => SizedBox(
    height: 48,
    child: ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      children: [
        for (final (label, key) in const [
          ('⌘', 'meta'),
          ('⌃', 'ctrl'),
          ('⌥', 'alt'),
          ('⇧', 'shift'),
        ])
          Padding(
            padding: const EdgeInsets.only(right: 6, top: 6, bottom: 6),
            child: FilterChip(
              label: Text(label),
              selected: _modifiers.contains(key),
              showCheckmark: false,
              onSelected: (on) => setState(
                () => on ? _modifiers.add(key) : _modifiers.remove(key),
              ),
            ),
          ),
        for (final (label, key) in const [
          ('Esc', 'escape'),
          ('Tab', 'tab'),
          ('⌫', 'backspace'),
          ('↵', 'enter'),
          ('←', 'left'),
          ('↑', 'up'),
          ('↓', 'down'),
          ('→', 'right'),
          ('Del', 'delete'),
        ])
          Padding(
            padding: const EdgeInsets.only(right: 6, top: 6, bottom: 6),
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(minimumSize: const Size(44, 36)),
              onPressed: () => _key(key),
              child: Text(label),
            ),
          ),
      ],
    ),
  );

  Widget _screen(DcColors c) {
    if (!h.online && lease == null) {
      return Center(child: Text(tr("电脑离线")));
    }
    if (locked) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            tr("电脑已锁定，Agent 操作仍可用。\n解锁电脑后点「重新连接」。"),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (error != null) {
      return Center(child: InlineNotice(error!, danger: true));
    }
    if (busy && _desktopPreparationNote != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 20),
              Text(_desktopPreparationNote!, textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }
    final image = frame,
        renderer = _heldDecoder != null ? null : _heldRenderer ?? _renderer,
        decoder = _heldRenderer != null ? null : _heldDecoder ?? _decoder;
    if (image == null && !(_video && (renderer != null || decoder != null))) {
      return const Center(child: CircularProgressIndicator());
    }
    return LayoutBuilder(
      builder: (context, box) {
        viewport.layout(Size(box.maxWidth, box.maxHeight), viewport.content);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _scheduleResolution();
        });
        final pointer = _cursor;
        final cursor = pointer == null ? null : viewport.toLocal(pointer);
        final shape = _cursorState.shape;
        final shapeRect = cursor == null
            ? null
            : shape?.rect(cursor, viewport.rect);
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _pointer,
          onPointerMove: _pointer,
          onPointerUp: _pointer,
          onPointerCancel: _pointer,
          child: ClipRect(
            child: ColoredBox(
              color: Colors.black,
              child: Stack(
                children: [
                  Positioned.fromRect(
                    rect: viewport.rect,
                    child: _video && decoder != null
                        ? Texture(
                            textureId: decoder.textureId,
                            filterQuality: viewport.zoom > 1.5
                                ? FilterQuality.medium
                                : FilterQuality.low,
                          )
                        : _video && renderer != null
                        // The rect has the stream's aspect, so cover fills it
                        // exactly; zoom and pan are the viewport's.
                        ? RTCVideoView(
                            renderer,
                            objectFit: RTCVideoViewObjectFit
                                .RTCVideoViewObjectFitCover,
                            filterQuality: viewport.zoom > 1.5
                                ? FilterQuality.medium
                                : FilterQuality.low,
                          )
                        : Image.memory(
                            image!,
                            gaplessPlayback: true,
                            fit: BoxFit.fill,
                            filterQuality: viewport.zoom > 1.5
                                ? FilterQuality.medium
                                : FilterQuality.low,
                          ),
                  ),
                  if (_videoNote != null && (!_video || !_pictureReady))
                    Positioned(
                      left: 8,
                      bottom: 8,
                      child: IgnorePointer(
                        child: Text(
                          _videoNote!,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ),
                  if (cursor != null)
                    Positioned(
                      key: const ValueKey('desktop-cursor'),
                      left: shapeRect?.left ?? cursor.dx,
                      top: shapeRect?.top ?? cursor.dy,
                      child: IgnorePointer(
                        child: shape != null && shapeRect != null
                            ? Image.memory(
                                shape.bytes,
                                key: ValueKey(
                                  'desktop-cursor-shape-${shape.id}',
                                ),
                                width: shapeRect.width,
                                height: shapeRect.height,
                                fit: BoxFit.fill,
                                filterQuality: FilterQuality.none,
                                errorBuilder: (_, _, _) => const CustomPaint(
                                  size: Size(14, 20),
                                  painter: _CursorPainter(),
                                ),
                              )
                            : const CustomPaint(
                                size: Size(14, 20),
                                painter: _CursorPainter(),
                              ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A plain arrow pointer, tip at the origin.
class _CursorPainter extends CustomPainter {
  const _CursorPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(0, size.height * 0.8)
      ..lineTo(size.width * 0.3, size.height * 0.6)
      ..lineTo(size.width * 0.5, size.height)
      ..lineTo(size.width * 0.65, size.height * 0.93)
      ..lineTo(size.width * 0.45, size.height * 0.55)
      ..lineTo(size.width * 0.8, size.height * 0.55)
      ..close();
    canvas.drawPath(path, Paint()..color = Colors.black);
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _Tool extends StatelessWidget {
  const _Tool({required this.icon, required this.label, this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    // Equal shares of the bar, so longer translations wrap instead of
    // overflowing.
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: onTap == null ? context.dc.secondary : null),
              const SizedBox(height: 2),
              Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 11, height: 1.2),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
