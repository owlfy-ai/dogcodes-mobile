import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:dogcodes_app/core/adaptive_host_link.dart';
import 'package:dogcodes_app/core/clipboard_transfer.dart';
import 'package:dogcodes_app/core/host_api.dart';
import 'package:dogcodes_app/core/protocol.dart';
import 'package:dogcodes_app/core/secure_host_client.dart';
import 'package:flutter_test/flutter_test.dart';

class ClipboardLink implements HostLink {
  final calls = <Map<String, dynamic>>[];
  Uint8List clipboard = Uint8List(0),
      staged = Uint8List(0),
      snapshot = Uint8List(0);
  Map<String, dynamic>? manifest;
  String? lostCommit;
  bool corruptDownload = false, wrongOffset = false, wrongReceipt = false;
  int writes = 0, closed = 0;
  Future<void> Function()? appendWait;
  String? platform;
  @override
  String get hostId => 'pc';
  @override
  String? get hostName => 'fixture';
  @override
  Stream<Map<String, dynamic>> get events => const Stream.empty();
  @override
  Future<void> close() async {
    closed++;
  }

  @override
  Future<dynamic> call(String method, dynamic params) async {
    if (method == 'remote_capabilities') {
      return {
        'transportMethods': ['direct_open'],
        'clipboardTransfer': {'version': 1},
        'platform': ?platform,
      };
    }
    if (method != 'clipboard_transfer') throw StateError('unavailable');
    final p = Map<String, dynamic>.from(params as Map);
    calls.add(p);
    final op = p['operation'];
    if (op == 'begin_upload' || op == 'begin_download') {
      final down = op == 'begin_download';
      // As the computer reports an empty clipboard.
      if (down && clipboard.isEmpty) {
        throw ProtocolException(
          p['kind'] == 'text' ? '剪贴板没有文字' : '剪贴板内容为空或过大（图片限 16 MB，文字限 1 MB）',
        );
      }
      snapshot = Uint8List.fromList(clipboard);
      staged = Uint8List(0);
      manifest = {
        'transferId': 'fixture-transfer',
        'kind': p['kind'],
        'mimeType': p['kind'] == 'image'
            ? 'image/png'
            : 'text/plain;charset=utf-8',
        'size': down ? snapshot.length : p['size'],
        'sha256': down ? sha256.convert(snapshot).toString() : p['sha256'],
        'direction': down ? 'download' : 'upload',
        'state': down ? 'ready' : 'staging',
        'offset': down ? snapshot.length : 0,
        'chunkBytes': ClipboardTransfer.chunkBytes,
      };
      return Map.from(manifest!);
    }
    if (p['transferId'] != manifest?['transferId']) {
      throw StateError('identity mismatch');
    }
    if (op == 'close') {
      manifest = null;
      staged = Uint8List(0);
      return null;
    }
    if (op == 'append') {
      if (appendWait != null) await appendWait!();
      final data = base64Decode(p['bytes'] as String);
      expect(data.length, lessThanOrEqualTo(ClipboardTransfer.chunkBytes));
      expect(p['offset'], staged.length);
      staged = Uint8List.fromList([...staged, ...data]);
      return {
        'transferId': 'fixture-transfer',
        'offset': staged.length + (wrongOffset ? 1 : 0),
      };
    }
    if (op == 'commit') {
      if (lostCommit == 'before') throw const RemoteOutcomeUnknown();
      if (manifest!['state'] != 'applied') {
        clipboard = Uint8List.fromList(staged);
        writes++;
        manifest!['state'] = 'applied';
        manifest!['offset'] = clipboard.length;
      }
      if (lostCommit == 'after') throw const RemoteOutcomeUnknown();
      if (lostCommit == 'server-timeout') {
        throw const ProtocolException('系统操作超时');
      }
      return {...manifest!, if (wrongReceipt) 'transferId': 'wrong-transfer'};
    }
    if (op == 'status') return Map.from(manifest!);
    if (op == 'read') {
      final offset = p['offset'] as int;
      final end = (offset + ClipboardTransfer.chunkBytes).clamp(
        0,
        snapshot.length,
      );
      final bytes = Uint8List.fromList(snapshot.sublist(offset, end));
      if (corruptDownload) bytes[0] ^= 1;
      return {
        'transferId': 'fixture-transfer',
        'offset': offset,
        'nextOffset': end,
        'bytes': base64Encode(bytes),
      };
    }
    throw StateError('unknown op');
  }
}

void main() {
  test(
    'text and image transfers stay below the phone frame limit and apply only after all chunks',
    () async {
      for (final kind in ClipboardKind.values) {
        final link = ClipboardLink();
        final bytes = Uint8List.fromList(List.generate(200123, (i) => i % 251));
        final progress = <int>[];
        await ClipboardTransfer(
          link,
          current: () => true,
          onProgress: (n, _) => progress.add(n),
        ).send(bytes, kind);
        expect(link.clipboard, orderedEquals(bytes));
        expect(link.writes, 1);
        expect(
          link.calls.where((p) => p['operation'] == 'commit'),
          hasLength(1),
        );
        expect(
          link.calls.where((p) => p['operation'] == 'append'),
          hasLength(7),
        );
        expect(
          link.calls.every(
            (p) => utf8.encode(jsonEncode(p)).length < maxFrameBytes,
          ),
          isTrue,
        );
        expect(progress.last, bytes.length);
        expect(link.manifest, isNull);
      }
    },
  );
  test(
    'a download is assembled and checked before it can reach the phone clipboard',
    () async {
      final link = ClipboardLink()
        ..clipboard = Uint8List.fromList(List.generate(90001, (i) => i % 251));
      final original = Uint8List.fromList(link.clipboard);
      final bytes = await ClipboardTransfer(
        link,
        current: () => true,
      ).receive(ClipboardKind.image);
      expect(bytes, orderedEquals(original));
      expect(link.writes, 0);
      expect(link.manifest, isNull);
    },
  );
  test('corrupt downloads and wrong upload offsets fail closed', () async {
    final link = ClipboardLink()
      ..clipboard = Uint8List.fromList([1, 2, 3])
      ..corruptDownload = true;
    await expectLater(
      ClipboardTransfer(link, current: () => true).receive(ClipboardKind.image),
      throwsA(isA<ProtocolException>()),
    );
    expect(link.writes, 0);
    expect(link.manifest, isNull);
    link.wrongOffset = true;
    await expectLater(
      ClipboardTransfer(
        link,
        current: () => true,
      ).send(Uint8List.fromList([1, 2]), ClipboardKind.image),
      throwsA(isA<ProtocolException>()),
    );
    expect(link.calls.where((p) => p['operation'] == 'commit'), isEmpty);
  });
  test(
    'a lost commit reply is read-only verified and never reapplied',
    () async {
      final link = ClipboardLink()..lostCommit = 'after';
      await ClipboardTransfer(
        link,
        current: () => true,
      ).send(Uint8List.fromList([1, 2, 3]), ClipboardKind.image);
      expect(link.writes, 1);
      expect(link.calls.where((p) => p['operation'] == 'commit'), hasLength(1));
      expect(link.calls.where((p) => p['operation'] == 'status'), hasLength(1));
    },
  );
  test(
    'a PC-side timeout can also mean applied and is verified without replay',
    () async {
      final link = ClipboardLink()..lostCommit = 'server-timeout';
      await ClipboardTransfer(
        link,
        current: () => true,
      ).send(Uint8List.fromList([1, 2, 3]), ClipboardKind.image);
      expect(link.writes, 1);
      expect(link.calls.where((p) => p['operation'] == 'commit'), hasLength(1));
      expect(link.calls.where((p) => p['operation'] == 'status'), hasLength(1));
    },
  );
  test('a commit lost before delivery is not automatically resent', () async {
    final link = ClipboardLink()..lostCommit = 'before';
    await expectLater(
      ClipboardTransfer(
        link,
        current: () => true,
      ).send(Uint8List.fromList([1, 2, 3]), ClipboardKind.image),
      throwsA(predicate((e) => '$e'.contains('不会自动重发'))),
    );
    expect(link.writes, 0);
    expect(link.calls.where((p) => p['operation'] == 'commit'), hasLength(1));
    expect(link.manifest, isNull);
  });
  test(
    'cancellation during an upload closes staging without committing',
    () async {
      final link = ClipboardLink();
      final entered = Completer<void>(), release = Completer<void>();
      link.appendWait = () async {
        entered.complete();
        await release.future;
      };
      final transfer = ClipboardTransfer(link, current: () => true);
      final result = expectLater(
        transfer.send(Uint8List.fromList([1, 2, 3]), ClipboardKind.image),
        throwsA(isA<ClipboardCancelled>()),
      );
      await entered.future;
      transfer.cancel();
      release.complete();
      await result;
      expect(link.writes, 0);
      expect(link.calls.where((p) => p['operation'] == 'commit'), isEmpty);
      expect(link.manifest, isNull);
    },
  );
  test(
    'wrong commit identity and excessive payloads cannot be treated as success',
    () async {
      final link = ClipboardLink()..wrongReceipt = true;
      await expectLater(
        ClipboardTransfer(
          link,
          current: () => true,
        ).send(Uint8List.fromList([1, 2]), ClipboardKind.image),
        throwsA(isA<ProtocolException>()),
      );
      expect(link.calls.where((p) => p['operation'] == 'status'), isEmpty);
      final other = ClipboardLink();
      await expectLater(
        ClipboardTransfer(
          other,
          current: () => true,
        ).send(Uint8List(1024 * 1024 + 1), ClipboardKind.text),
        throwsA(isA<ProtocolException>()),
      );
      expect(other.calls, isEmpty);
    },
  );
  test(
    'clipboard chooses an owned P2P/TURN link without touching business or screen connections',
    () async {
      final main = ClipboardLink(),
          relay = ClipboardLink(),
          direct = ClipboardLink();
      final business = AdaptiveHostLink(
        relay: main,
        relayDialer: () async => relay,
        directDialer: (s) async {
          expect(identical(s, relay), isTrue);
          return DirectConnection(direct, ConnectionRoute.turn);
        },
      );
      final own = await openClipboardLink(business, current: () => true);
      expect(identical(own, direct), isTrue);
      expect(relay.closed, 1);
      expect(main.closed, 0);
      expect(main.calls, isEmpty);
      await own.close();
      await business.close();
    },
  );
  test(
    'failed ICE keeps the independent relay and cancellation releases it',
    () async {
      final main = ClipboardLink(), relay = ClipboardLink();
      var alive = true;
      final business = AdaptiveHostLink(
        relay: main,
        relayDialer: () async => relay,
        directDialer: (_) async => throw StateError('no ICE'),
      );
      expect(
        identical(
          await openClipboardLink(business, current: () => alive),
          relay,
        ),
        isTrue,
      );
      await relay.close();
      final late = ClipboardLink();
      final pending = Completer<HostLink>();
      final cancelled = AdaptiveHostLink(
        relay: main,
        relayDialer: () => pending.future,
        directDialer: (_) async => throw StateError('unreachable'),
      );
      final result = expectLater(
        openClipboardLink(cancelled, current: () => alive),
        throwsA(anything),
      );
      alive = false;
      pending.complete(late);
      await result;
      await Future<void>.delayed(Duration.zero);
      expect(late.closed, 1);
      expect(main.closed, 0);
      await business.close();
      await cancelled.close();
    },
  );
}
