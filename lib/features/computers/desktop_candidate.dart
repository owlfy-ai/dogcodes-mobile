import 'dart:async';
import 'package:dogcodes_video/dogcodes_video.dart';
import '../../core/adaptive_host_link.dart';
import '../../core/host_api.dart';
import '../../core/rtc_transport.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../../core/owned_resource.dart';

final _rendererDisposals = Expando<Future<void>>('desktop-renderer-disposal');
Future<void> disposeDesktopRenderer(RTCVideoRenderer renderer) =>
    _rendererDisposals[renderer] ??= () async {
      try {
        await renderer
            .setSrcObject(stream: null)
            .timeout(const Duration(seconds: 3));
      } catch (_) {
        /* Engine may already be gone. */
      }
      try {
        await renderer.dispose().timeout(const Duration(seconds: 3));
      } catch (_) {
        /* Retired engine/texture. */
      }
    }();

/// Page cleanup and late negotiation callbacks share one disposal owner.
class DesktopCandidate {
  DesktopCandidate(this.source, this.connection, {this.desktop}) {
    unawaited(
      firstFrame.future.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      ),
    );
  }
  final HostLink source;
  final DirectConnection connection;
  final DesktopConnection? desktop;
  final firstFrame = Completer<void>();
  RTCVideoRenderer? renderer;
  H264Decoder? decoder;
  bool adopted = false, closed = false;
  Future<void>? _oldClose, _newClose;
  Future<void> _safe(Future<void> Function() close) async {
    try {
      await close().timeout(const Duration(seconds: 3));
    } catch (_) {
      /* Retired native/wire resource. */
    }
  }

  Future<void> closeOld() => _oldClose ??= _safe(source.close);
  Future<void> closeNew() => _newClose ??= _safe(connection.link.close);
  H264Decoder? takeDecoder() {
    final value = decoder;
    decoder = null;
    return value;
  }

  RTCVideoRenderer? takeRenderer() {
    final value = renderer;
    renderer = null;
    return value;
  }

  Future<void> _disposeRenderer(RTCVideoRenderer? value) async {
    if (value == null) return;
    await disposeDesktopRenderer(value);
  }

  Future<void> release() async {
    closed = true;
    final value = takeDecoder(), surface = takeRenderer();
    if (!firstFrame.isCompleted) {
      firstFrame.completeError(const ResourceExpired());
    }
    await Future.wait([
      _disposeRenderer(surface),
      if (value != null) _safe(value.dispose),
      if (adopted) closeOld() else closeNew(),
    ]);
  }

  Future<void> closeAll() async {
    closed = true;
    final value = takeDecoder(), surface = takeRenderer();
    if (!firstFrame.isCompleted) {
      firstFrame.completeError(const ResourceExpired());
    }
    await Future.wait([
      _disposeRenderer(surface),
      closeOld(),
      closeNew(),
      if (value != null) _safe(value.dispose),
    ]);
  }
}
