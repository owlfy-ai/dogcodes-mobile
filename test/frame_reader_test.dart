import 'dart:convert';
import 'dart:typed_data';

import 'package:dogcodes_app/core/frame_reader.dart';
import 'package:dogcodes_app/core/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List json(Map<String, dynamic> value) {
  final body = utf8.encode(jsonEncode(value));
  return (BytesBuilder()
        ..add((ByteData(4)..setUint32(0, body.length)).buffer.asUint8List())
        ..add(body))
      .toBytes();
}

Uint8List binary(Map<String, dynamic> header, List<int> payload) {
  final head = utf8.encode(jsonEncode(header));
  final length = 4 + head.length + payload.length;
  return (BytesBuilder()
        ..add(
          (ByteData(4)..setUint32(0, length | 0x80000000)).buffer.asUint8List(),
        )
        ..add((ByteData(4)..setUint32(0, head.length)).buffer.asUint8List())
        ..add(head)
        ..add(payload))
      .toBytes();
}

List<Uint8List> fragments(Uint8List bytes, String id) => [
  for (var i = 0; i < bytes.length; i += 8192)
    binary({
      'type': 'fragment',
      'id': id,
      'offset': i,
      'total': bytes.length,
    }, bytes.sublist(i, (i + 8192).clamp(0, bytes.length))),
];

void main() {
  test(
    'monitor cancellation frees a partial picture before its replacement',
    () {
      final reader = FrameReader();
      reader.add(fragments(json({'text': 'old' * 10000}), 'a' * 32).first);
      expect(reader.next(), isNull);
      reader.add(json({'type': 'fragment_cancel', 'id': 'a' * 32}));
      reader.add(fragments(json({'text': 'new' * 10000}), 'b' * 32).first);
      reader.add(fragments(json({'text': 'control' * 10000}), 'c' * 32).first);
      reader.add(json({'type': 'response', 'requestId': 'monitor-selected'}));
      expect(reader.next()!['requestId'], 'monitor-selected');
      expect(reader.next(), isNull);
      // A duplicate cancel after the previous message was retired is harmless.
      reader.add(json({'type': 'fragment_cancel', 'id': 'a' * 32}));
      expect(reader.next(), isNull);
      reader.add(json({'type': 'fragment_cancel', 'id': 'bad'}));
      expect(reader.next, throwsA(isA<ProtocolException>()));
    },
  );

  test('delivery acknowledgements report only contiguous accepted bytes', () {
    final seen = <int>[];
    final bytes = json({'text': 'x' * 20000});
    final chunks = fragments(bytes, 'a' * 32);
    final reader = FrameReader(
      onFragment: (id, offset) {
        expect(id, 'a' * 32);
        seen.add(offset);
      },
    );
    for (final chunk in chunks) {
      reader.add(chunk);
      reader.next();
    }
    expect(seen, [8192, 16384, bytes.length]);
    reader.add(
      binary(
        {'type': 'fragment', 'id': 'a' * 32, 'offset': 5, 'total': 10},
        [1],
      ),
    );
    expect(reader.next, throwsA(isA<ProtocolException>()));
    expect(seen.length, 3);
  });

  test('JSON and binary messages reassemble from arbitrary chunks', () {
    final payload = List<int>.generate(300000, (i) => i & 0xff);
    final stream = BytesBuilder()
      ..add(json({'type': 'response', 'requestId': 'r1'}))
      ..add(binary({'type': 'video', 'seq': 3, 'key': true}, payload))
      ..add(json({'type': 'event', 'n': 2}));
    final bytes = stream.toBytes();
    final reader = FrameReader();
    final out = <Map<String, dynamic>>[];
    // Noise-sized chunks, one byte short so boundaries never line up.
    for (var i = 0; i < bytes.length; i += 15999) {
      reader.add(bytes.sublist(i, (i + 15999).clamp(0, bytes.length)));
      for (var m = reader.next(); m != null; m = reader.next()) {
        out.add(m);
      }
    }
    expect(out.map((m) => m['type']), ['response', 'video', 'event']);
    expect(out[1]['seq'], 3);
    expect(out[1]['payload'], payload);
    expect(out[2]['n'], 2);
    expect(reader.buffered, 0);
  });

  test('payload survives later chunks reusing the buffer', () {
    final reader = FrameReader()..add(binary({'seq': 1}, [1, 2, 3]));
    final first = reader.next()!;
    reader.add(binary({'seq': 2}, [9, 9, 9]));
    reader.next();
    expect(first['payload'], [1, 2, 3]);
  });

  test('invalid sizes are refused', () {
    final huge = FrameReader()
      ..add((ByteData(4)..setUint32(0, 9 * 1024 * 1024)).buffer.asUint8List());
    expect(huge.next, throwsA(isA<ProtocolException>()));
    final zero = FrameReader()..add([0, 0, 0, 0]);
    expect(zero.next, throwsA(isA<ProtocolException>()));
    // Header length past the message end.
    final bad = FrameReader()..add([0x80, 0, 0, 5, 0, 0, 0, 9, 0]);
    expect(bad.next, throwsA(isA<ProtocolException>()));
    // Incomplete is not an error.
    final partial = FrameReader()..add(json({'a': 1}).sublist(0, 6));
    expect(partial.next(), isNull);
  });

  test('control and a large response pass an incomplete video', () {
    final payload = Uint8List.fromList(List.generate(36000, (i) => i % 256));
    final video = fragments(
      binary({'type': 'video', 'seq': 9}, payload),
      'a' * 32,
    );
    final response = fragments(
      json({'type': 'response', 'text': List.filled(5000, '中文🙂').join()}),
      'b' * 32,
    );
    final reader = FrameReader()..add(video.first);
    expect(reader.next(), isNull);
    reader.add(response.first);
    expect(reader.next(), isNull);
    reader.add(json({'type': 'response', 'requestId': 'input-ack'}));
    expect(reader.next()!['requestId'], 'input-ack');
    Map<String, dynamic>? reply;
    for (final chunk in response.skip(1)) {
      reader.add(chunk);
      reply = reader.next() ?? reply;
    }
    expect(reply!['text'], List.filled(5000, '中文🙂').join());
    Map<String, dynamic>? frame;
    for (final chunk in video.skip(1)) {
      reader.add(chunk);
      frame = reader.next() ?? frame;
    }
    expect(frame!['payload'], payload);
    expect(frame['seq'], 9);
    expect(reader.buffered, 0);
  });

  test(
    'partial fragment does not hide a following control in the same read',
    () {
      final chunks = fragments(
        binary({'type': 'video'}, Uint8List(20000)),
        'a' * 32,
      );
      final bytes =
          (BytesBuilder()
                ..add(chunks.first)
                ..add(json({'type': 'event', 'n': 7})))
              .toBytes();
      final reader = FrameReader();
      // Fragment envelope boundaries can straddle decrypted Noise packets.
      reader.add(bytes.sublist(0, 19));
      expect(reader.next(), isNull);
      reader.add(bytes.sublist(19));
      expect(reader.next()!['n'], 7);
      expect(reader.next(), isNull);
    },
  );

  test('invalid or excessive assemblies are refused before allocating', () {
    final cases = [
      {'id': 'a' * 32, 'offset': 1, 'total': 10},
      {'id': 'a' * 32, 'offset': 0, 'total': FrameReader.maxMessage + 5},
      {'id': 'a' * 32, 'offset': 0, 'total': 4},
      {'id': 'bad', 'offset': 0, 'total': 10},
      {'id': 'a' * 32, 'offset': 0, 'total': '10'},
    ];
    for (final fields in cases) {
      final reader = FrameReader()
        ..add(binary({'type': 'fragment', ...fields}, [1]));
      expect(reader.next, throwsA(isA<ProtocolException>()));
    }
    final reader = FrameReader();
    for (final id in ['a' * 32, 'b' * 32]) {
      reader.add(fragments(json({'text': 'x' * 20000}), id).first);
      expect(reader.next(), isNull);
    }
    reader.add(fragments(json({'text': 'x' * 20000}), 'c' * 32).first);
    expect(reader.next, throwsA(isA<ProtocolException>()));
  });

  test(
    'changed lengths, duplicate chunks and nested fragments fail closed',
    () {
      final chunks = fragments(json({'text': 'x' * 20000}), 'a' * 32);
      final duplicate = FrameReader()..add(chunks.first);
      duplicate.next();
      duplicate.add(chunks.first);
      expect(duplicate.next, throwsA(isA<ProtocolException>()));
      final changed = FrameReader()..add(chunks.first);
      changed.next();
      changed.add(
        binary(
          {'type': 'fragment', 'id': 'a' * 32, 'offset': 8192, 'total': 30000},
          [1],
        ),
      );
      expect(changed.next, throwsA(isA<ProtocolException>()));
      final nested = binary(
        {'type': 'fragment', 'id': 'a' * 32, 'offset': 0, 'total': 10},
        [1],
      );
      final reader = FrameReader()..add(fragments(nested, 'b' * 32).single);
      expect(reader.next, throwsA(isA<ProtocolException>()));
      final malformed = FrameReader()
        ..add(
          binary(
            {'type': 'fragment', 'id': 'a' * 32, 'offset': 0, 'total': 5},
            [0, 0, 0, 40, 0],
          ),
        );
      expect(malformed.next, throwsA(isA<ProtocolException>()));
    },
  );

  test('retiring a connection drops incomplete fragments and buffers', () {
    final chunks = fragments(json({'text': 'x' * 20000}), 'a' * 32);
    final reader = FrameReader()..add(chunks.first);
    reader.next();
    reader.clear();
    for (final chunk in chunks) {
      reader.add(chunk);
    }
    expect(reader.next()!['text'], 'x' * 20000);
    expect(reader.next(), isNull);
  });
}
