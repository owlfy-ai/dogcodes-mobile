import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/core/host_api.dart';
import 'package:dogcodes_app/core/terminal_input.dart';
import 'package:dogcodes_app/core/secure_host_client.dart';

class InputPeer implements HostApi {
  final writes = <Map<String, dynamic>>[], calls = <String>[];
  Map<String, dynamic> state = {
    'terminalId': 'terminal',
    'epoch': 'epoch',
    'revision': '0',
    'sequence': '0',
    'state': 'idle',
    'uncertain': false,
    'owned': true,
    'status': 'running',
  };
  Completer<void>? writeGate, capGate;
  bool lostAfter = false, unknown = false, available = true;
  String? corrupt;
  void apply() {
    state['state'] = 'applied';
  }

  @override
  Future<dynamic> call(String method, dynamic args) async {
    calls.add(method);
    if (method == 'remote_capabilities') {
      await capGate?.future;
      return {'terminalInputStreams': available};
    }
    if (method == 'terminal_get') {
      return {'id': 'terminal', 'epoch': 'epoch', 'status': 'running'};
    }
    expect(method, 'terminal_input');
    final body = Map<String, dynamic>.from(args as Map);
    if (body['type'] == 'inspect') return Map<String, dynamic>.from(state);
    if (body['type'] == 'open') {
      expect(body['expectedRevision'], state['revision']);
      state = {
        ...state,
        'revision': '${int.parse(state['revision'] as String) + 1}',
        'streamId': body['streamId'],
        'sequence': '0',
        'state': 'ready',
        'uncertain': false,
      };
      return Map<String, dynamic>.from(state);
    }
    expect(body['type'], 'write');
    writes.add(body);
    expect(body['streamId'], state['streamId']);
    expect(body['revision'], state['revision']);
    expect(
      int.parse(body['sequence'] as String),
      int.parse(state['sequence'] as String) + 1,
    );
    state = {
      ...state,
      'sequence': body['sequence'],
      'state': 'writing',
      'digest': sha256.convert(base64Decode(body['data'] as String)).toString(),
    };
    if (unknown) throw const RemoteOutcomeUnknown();
    await writeGate?.future;
    apply();
    if (lostAfter) throw const RemoteOutcomeUnknown();
    return {
      ...state,
      ?corrupt: ['revision', 'sequence'].contains(corrupt) ? '99' : 'mismatch',
    };
  }
}

Future<void> started(InputPeer api) async {
  for (var i = 0; i < 30 && api.writes.isEmpty; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(api.writes.length, 1);
}

void main() {
  test('one native write at a time preserves exact input order', () async {
    final api = InputPeer()..writeGate = Completer<void>(),
        input = TerminalInput(api, 'terminal');
    final first = input.send(utf8.encode('one')),
        second = input.send(utf8.encode('two'));
    await started(api);
    expect(api.writes.length, 1);
    api.writeGate!.complete();
    expect(await first, true);
    expect(await second, true);
    expect(
      api.writes.map((w) => utf8.decode(base64Decode(w['data'] as String))),
      ['one', 'two'],
    );
    expect(api.writes.map((w) => w['sequence']), ['1', '2']);
    input.dispose();
  });
  test('lost reply is proved read-only and never resends bytes', () async {
    final api = InputPeer()..lostAfter = true,
        input = TerminalInput(api, 'terminal');
    expect(await input.send(utf8.encode('once')), true);
    expect(api.writes.length, 1);
    expect(api.calls.last, 'terminal_input');
    expect(input.paused, false);
    input.dispose();
  });
  test(
    'unknown input discards queued bytes and explicit resume sends no command',
    () async {
      final api = InputPeer()..unknown = true,
          input = TerminalInput(api, 'terminal');
      final first = input.send([1]), queued = input.send([2]);
      expect(await first, false);
      expect(await queued, false);
      expect(input.paused, true);
      expect(api.writes.length, 1);
      expect(await input.send([3]), false);
      api.unknown = false;
      expect(await input.resume(), true);
      expect(api.writes.length, 1);
      expect(await input.send([4]), true);
      expect(api.writes.last['sequence'], '1');
      expect(api.writes.first['streamId'], isNot(api.writes.last['streamId']));
      input.dispose();
    },
  );
  test(
    'later verification clears uncertainty without replay or queued writes',
    () async {
      final api = InputPeer()..unknown = true,
          input = TerminalInput(api, 'terminal');
      expect(await input.send([1]), false);
      api.apply();
      expect(await input.verify(), true);
      expect(api.writes.length, 1);
      api.unknown = false;
      expect(await input.send([2]), true);
      expect(api.writes.last['sequence'], '2');
      input.dispose();
    },
  );
  test('wrong receipt identity cannot confirm input', () async {
    for (final field in [
      'epoch',
      'streamId',
      'revision',
      'sequence',
      'digest',
      'owned',
    ]) {
      final api = InputPeer()..corrupt = field,
          input = TerminalInput(api, 'terminal');
      expect(await input.send([1]), false);
      expect(input.paused, true);
      expect(api.writes.length, 1);
      input.dispose();
    }
  });
  test(
    'disposing during opening discards the queue before any input is sent',
    () async {
      final api = InputPeer()..capGate = Completer<void>(),
          input = TerminalInput(api, 'terminal');
      final first = input.send([1]), second = input.send([2]);
      input.dispose();
      api.capGate!.complete();
      expect(await first, false);
      expect(await second, false);
      expect(api.writes, isEmpty);
    },
  );
  test('older PC never falls back to unsequenced terminal_write', () async {
    final api = InputPeer()..available = false,
        input = TerminalInput(api, 'terminal');
    expect(await input.send([1]), false);
    expect(api.calls, ['remote_capabilities']);
    expect(input.canResume, false);
    input.dispose();
  });
  test('oversized input is rejected before transport', () async {
    final api = InputPeer(), input = TerminalInput(api, 'terminal');
    expect(await input.send(List.filled(16385, 1)), false);
    expect(api.calls, isEmpty);
    input.dispose();
  });
  test('disposed verification cannot update listeners', () async {
    final api = InputPeer()..unknown = true,
        input = TerminalInput(api, 'terminal');
    expect(await input.send([1]), false);
    api.apply();
    final verifying = input.verify();
    input.dispose();
    expect(await verifying, false);
  });
}
