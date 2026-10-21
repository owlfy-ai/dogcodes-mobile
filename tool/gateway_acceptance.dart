import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:dogcodes_app/core/protocol.dart';
import 'package:dogcodes_app/core/secure_host_client.dart';
import 'package:dogcodes_app/core/mobile_operations.dart';
import 'package:dogcodes_app/core/security/noise_endpoint.dart';
import 'package:dogcodes_app/core/security/secret_storage.dart';

class MemorySecrets implements SecretStorage {
  final data = <String, String>{};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async {
    data[key] = value;
  }
}

void require(bool value, String reason) {
  if (!value) throw StateError(reason);
}

Future<T> until<T>(Future<T?> Function() read) async => await (() async {
  while (true) {
    final value = await read();
    if (value != null) return value;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
})().timeout(const Duration(seconds: 15));
Future<void> main(List<String> args) async {
  final directory = Directory(args[0]);
  final status =
      jsonDecode(await File('${directory.path}/invitation.json').readAsString())
          as Map<String, dynamic>;
  final service = Uri.parse(Platform.environment['DOGCODES_PROBE_ORIGIN']!);
  final invitation = PairingInvitation.parse(
    (status['invitation'] as Map)['uri'] as String,
    trustedService: service,
    now: DateTime.now().toUtc(),
    allowLocalDevelopment: true,
  );
  final endpoint = NoiseEndpoint(
    DynamicLibrary.open(Platform.environment['DOGCODES_ENDPOINT_LIBRARY']!),
  );
  final phone = endpoint.createIdentity();
  final (client, ack) = await SecureHostClient.pair(
    invitation,
    phone,
    endpoint,
  );
  SecureHostClient? second;
  try {
    require(
      ack['type'] == 'paired' &&
          ack['binding'] == client.session.binding &&
          ack['phonePublicKey'] == phone.publicHex,
      'Invalid pairing receipt',
    );
    require(
      displayHostName(ack['hostName']) != null,
      'Pairing receipt lacks a computer name',
    );
    final bootstrap = await client.call('bootstrap', null);
    final project = (bootstrap['projects'] as List).single['projectId'];
    final executor =
        (await client.call('registered_executors', null) as List).single;
    final stream = <Map<String, dynamic>>[];
    final subscription = client.events.listen(stream.add);
    await client.call('subscribe_project', [0, project]);
    // Re-subscribing a project replaces its stream instead of failing.
    await client.call('subscribe_project', [0, project]);
    require(
      await client.call('quota_snapshots_for', [null, null, true]) is List,
      'Read-only quota unavailable',
    );
    final ops = MobileOperations(MemorySecrets(), client.hostId);
    final original = {
      'scope': 'mobile-fixture',
      'taskId': null,
      'projectId': project,
      'target': executor,
      'input': {
        'prompt': 'encrypted gateway fixture',
        'model': null,
        'thinking': null,
        'permissionMode': null,
        'attachments': [],
      },
    };
    final sent = await ops.send(client, original);
    require(sent['state'] == 'closed', 'Send was not accepted');
    final taskId = sent['resolution']['taskId'];
    final approval = await until<Map<String, dynamic>>(() async {
      final list = await client.call('pending_approvals', [taskId, 50]) as List;
      return list.isEmpty ? null : Map<String, dynamic>.from(list.first as Map);
    });
    final current = await client.call('bootstrap', null);
    final task = Map<String, dynamic>.from(
      (current['tasks'] as List).single as Map,
    );
    await ops.approval(client, task, approval, 'allow-once');
    await until<bool>(() async {
      final fresh = await client.call('bootstrap', null);
      return (fresh['tasks'] as List).single['activePrimaryRun'] == null
          ? true
          : null;
    });
    final timeline = await client.call('timeline_snapshot', [taskId]);
    require(
      (timeline['items'] as List).any(
        (v) => (v['text'] as String).contains('encrypted gateway fixture'),
      ),
      'Canonical timeline missing',
    );
    require(stream.any((e) => e['type'] == 'event'), 'No streamed events');

    // A follow-up turn is stopped from the phone while it waits for approval.
    final followUp = await ops.send(client, {
      ...original,
      'scope': 'mobile-fixture-follow-up',
      'taskId': taskId,
      'input': {...(original['input'] as Map), 'prompt': 'stop this follow-up'},
    });
    require(followUp['state'] == 'closed', 'Follow-up was not accepted');
    final running = await until<Map<String, dynamic>>(() async {
      final fresh = await client.call('bootstrap', null);
      final t = Map<String, dynamic>.from(
        (fresh['tasks'] as List).single as Map,
      );
      final waiting =
          await client.call('pending_approvals', [taskId, 50]) as List;
      return t['activePrimaryRun'] != null && waiting.isNotEmpty ? t : null;
    });
    await ops.cancel(client, running);
    await until<bool>(() async {
      final fresh = await client.call('bootstrap', null);
      return (fresh['tasks'] as List).single['activePrimaryRun'] == null
          ? true
          : null;
    });
    var rejected = false;
    try {
      await client.call('scan_agent', 'fake');
    } catch (_) {
      rejected = true;
    }
    require(rejected, 'Host-only method exposed');
    await subscription.cancel();
    await client.close();
    second = await SecureHostClient.reconnect(
      {
        'hostId': invitation.hostId,
        'service': invitation.service.toString(),
        'publicKey': hexBytes(
          base64Url.decode(base64Url.normalize(invitation.hostKey)),
        ),
        'routeToken': ack['routeToken'],
      },
      phone,
      endpoint,
    );
    require(second.hostName != null, 'Reconnect lacks a computer name');
    final after = await second.call('bootstrap', null);
    require(
      (after['tasks'] as List).single['taskId'] == taskId,
      'Reconnect lost task',
    );
    // Session organization is shared PC state, not a phone-only preference.
    for (final state in ['pinned', 'archived', null]) {
      await ops.setHistoryState(second, taskId as String, state);
      final preferences = await second.call('history_preferences', null);
      require(
        preferences['preferences']['tasks'][taskId] == state,
        'Session organization did not persist',
      );
      require(
        await ops.pending() == null,
        'History write has no confirmed receipt',
      );
    }
    final page = await second.call('query_history', [
      {
        'taskId': taskId,
        'kind': 'search',
        'text': 'encrypted gateway fixture',
        'afterSequence': 0,
        'throughSequence': null,
        'limit': 1,
      },
    ]);
    require(
      (page['items'] as List).isNotEmpty,
      'Full-text history query lost the prompt',
    );
    if (page['nextCursor'] != null) {
      final next = await second.call('query_history', [
        {
          'taskId': taskId,
          'kind': 'search',
          'text': 'encrypted gateway fixture',
          'afterSequence': int.parse('${page['nextCursor']}'),
          'throughSequence': int.parse('${page['throughSequence']}'),
          'limit': 1,
        },
      ]);
      require(
        '${next['throughSequence']}' == '${page['throughSequence']}',
        'Search upper bound changed',
      );
    }
    final originalTimeline = await second.call('timeline_snapshot', [taskId]);
    final turn =
        (originalTimeline['items'] as List).firstWhere(
              (i) => i['kind'] == 'user_message',
            )['turnId']
            as String;
    final fork = await ops.fork(second, taskId, turn, 'workspace');
    require(
      fork['completed'] == true && fork['taskAvailable'] == true,
      'Fork not completed',
    );
    final target = fork['request']['newTaskId'];
    require(
      target != taskId && await ops.pending() == null,
      'Fork identity/receipt invalid',
    );
    final forked = await second.call('timeline_snapshot', [target]);
    require(
      (forked['items'] as List).any((i) => i['kind'] == 'fork_context'),
      'Fork has no retained history',
    );
    final disconnected = second.events
        .firstWhere((e) => e['type'] == 'disconnected')
        .timeout(const Duration(seconds: 10));
    await File(
      '${directory.path}/revoke',
    ).writeAsString('revoke synthetic device');
    await disconnected;
    rejected = false;
    try {
      await second.call('bootstrap', null);
    } catch (_) {
      rejected = true;
    }
    require(rejected, 'Revoked live session accepted command');
    final evidence = jsonDecode(
      await File('${directory.path}/evidence.json').readAsString(),
    );
    require(
      evidence['requests'] == 2 && evidence['tasks'] == 2,
      'Task duplicated',
    );
  } finally {
    await client.close();
    await second?.close();
  }
  stdout.writeln(
    'PASS: real Core gateway pairing, send, stream, approval, stop, quota, reconnect, pin/archive, history search, Fork and revocation (isolated synthetic agent).',
  );
}
