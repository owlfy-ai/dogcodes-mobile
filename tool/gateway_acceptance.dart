import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dogcodes_app/core/pc_api.dart' show uuid, PcApi;
import 'package:dogcodes_app/core/host_api.dart';
import 'package:dogcodes_app/core/protocol.dart';
import 'package:dogcodes_app/core/secure_host_client.dart';
import 'package:dogcodes_app/core/mobile_operations.dart';
import 'package:dogcodes_app/core/security/pairing_recovery.dart';
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

/// Discard only the reply after the isolated PC has processed the original
/// command. This exercises the phone journal without a second Git effect.
class LostGitReply implements HostApi {
  LostGitReply(this.client);
  final HostApi client;
  bool lost = false;
  @override
  Future<dynamic> call(String method, dynamic params) async {
    final result = await client.call(method, params);
    if (!lost && method == 'review' && params['operation'] == 'git_action') {
      lost = true;
      throw const RemoteOutcomeUnknown();
    }
    return result;
  }
}

class LostWorkspaceReply implements HostApi {
  LostWorkspaceReply(this.client, this.method, {this.before = false});
  final HostApi client;
  final String method;
  final bool before;
  bool lost = false;
  @override
  Future<dynamic> call(String name, dynamic params) async {
    if (before && !lost && name == method) {
      lost = true;
      throw const RemoteOutcomeUnknown();
    }
    final result = await client.call(name, params);
    if (!lost && name == method) {
      lost = true;
      throw const RemoteOutcomeUnknown();
    }
    return result;
  }
}

Future<String> fixtureGit(Directory directory, List<String> args) async {
  require(
    await File('${directory.path}/.remote-acceptance').exists(),
    'Not an isolated fixture directory',
  );
  final result = await Process.run(
    'git',
    args,
    workingDirectory: directory.path,
  );
  require(result.exitCode == 0, 'Isolated Git fixture failed: ${args.first}');
  return '${result.stdout}'.trim();
}

Future<void> main(List<String> args) async {
  final directory = Directory(args[0]);
  require(
    await File('${directory.path}/.remote-acceptance').exists(),
    'Not an isolated fixture directory',
  );
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
  final pairStorage = MemorySecrets();
  final originalPair = PairingRecovery.fromInvitation(
    invitation,
    phone.publicHex,
    bindingEpoch: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
  );
  await PairingJournal(
    pairStorage,
    allowLocalDevelopment: true,
  ).begin(originalPair);
  final (unconfirmed, discardedAck) = await SecureHostClient.pair(
    invitation,
    phone,
    endpoint,
  );
  await unconfirmed.close();
  // A restarted phone has neither route credential nor a trusted-host record.
  // Recover from only the saved original invitation and its original identity.
  final recoveredOriginal = (await PairingJournal(
    pairStorage,
    allowLocalDevelopment: true,
  ).list()).single;
  final (client, ack) = await SecureHostClient.recoverPairing(
    recoveredOriginal,
    phone,
    endpoint,
  );
  require(
    ack['binding'] != discardedAck['binding'] &&
        ack['invitationId'] == originalPair.invitationId,
    'Pairing recovery reused an old handshake or another invitation',
  );
  await PairingJournal(
    pairStorage,
    allowLocalDevelopment: true,
  ).clear(recoveredOriginal);
  require(
    (await PairingJournal(
      pairStorage,
      allowLocalDevelopment: true,
    ).list()).isEmpty,
    'Confirmed pair recovery remained pending',
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
    final otherPhone = endpoint.createIdentity();
    final stolen = PairingRecovery.fromJson({
      ...originalPair.toJson(),
      'phonePublicKey': otherPhone.publicHex,
    }, allowLocalDevelopment: true);
    var stolenRejected = false;
    try {
      final (intruder, _) = await SecureHostClient.recoverPairing(
        stolen,
        otherPhone,
        endpoint,
      );
      await intruder.close();
    } catch (_) {
      stolenRejected = true;
    }
    require(
      stolenRejected,
      'Original QR transport ticket authorized a different phone',
    );
    final pairingBook =
        jsonDecode(await File('${directory.path}/devices.json').readAsString())
            as Map;
    require(
      (pairingBook['grants'] as Map).length == 1,
      'Recovery created another phone grant',
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
    const attachmentChunkBytes = 256 * 1024;
    final attachmentBytes = List<int>.generate(
      attachmentChunkBytes * 2 + 137,
      (i) => i % 256,
    );
    final upload = {
      'uploadId': uuid(),
      'name': 'gateway-fixture.bin',
      'mimeType': 'application/octet-stream',
      'byteLength': attachmentBytes.length,
      'sha256': sha256.convert(attachmentBytes).toString(),
    };
    await client.call('attachment_upload_begin', upload);
    await client.call('attachment_upload_chunk', [
      upload,
      '0',
      base64.encode(attachmentBytes.sublist(0, attachmentChunkBytes)),
    ]);
    final resumed = await client.call('attachment_upload_status', upload);
    require(
      resumed['offset'] == '$attachmentChunkBytes',
      'Attachment resume offset lost',
    );
    for (
      var offset = attachmentChunkBytes;
      offset < attachmentBytes.length;
      offset += attachmentChunkBytes
    ) {
      await client.call('attachment_upload_chunk', [
        upload,
        '$offset',
        base64.encode(
          attachmentBytes.sublist(
            offset,
            (offset + attachmentChunkBytes).clamp(0, attachmentBytes.length),
          ),
        ),
      ]);
    }
    final attachment = await client.call('attachment_upload_commit', upload);
    final receipt = await client.call('attachment_receipt', upload);
    require(
      receipt['path'] == attachment['path'] &&
          receipt['integrity']['sha256'] == upload['sha256'],
      'Attachment receipt changed',
    );
    final firstChunk = await client.call('attachment_read_chunk', [
      attachment['path'],
      '0',
      65536,
    ]);
    final readBytes = base64.decode(firstChunk['bytes'] as String);
    require(
      readBytes.length == 65536 &&
          sha256.convert(readBytes).toString() ==
              sha256.convert(attachmentBytes.sublist(0, 65536)).toString(),
      'Attachment read bytes changed',
    );
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
        'attachments': [attachment],
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
    require(
      (timeline['items'] as List).any(
        (i) => (i['attachments'] as List? ?? []).any(
          (a) => a['integrity']?['sha256'] == upload['sha256'],
        ),
      ),
      'Submitted attachment not retained in timeline',
    );

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
    final transport = await second.call('transport_options', {
      'fragmentedMessages': true,
    });
    require(
      transport['fragmentAcks'] == true &&
          transport['bulkWindowBytes'] == 32768,
      'Fragment transport not negotiated',
    );

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

    // A real Core read whose encrypted response exceeds the delivery window.
    // This can finish only when Dart reassembles and acknowledges Rust chunks.
    final muxText = List.filled(24000, '网关分片🙂').join();
    final muxFile = File('${directory.path}/gateway-multiplex.txt');
    await muxFile.writeAsString(muxText);
    final repetitions = Platform.environment['DOGCODES_TEST_LONG_STREAM'] == '1'
        ? 200
        : 1;
    for (var i = 0; i < repetitions; i++) {
      final muxReply = await PcApi(
        second,
      ).filePreview(taskId as String, 0, 'gateway-multiplex.txt');
      require(
        muxReply['text'] == muxText,
        'Encrypted fragmented Core response was corrupted or stalled',
      );
    }
    if (repetitions > 1) {
      require(
        utf8.encode(muxText).length * repetitions > 64 * 1024 * 1024,
        'Long-stream fixture must exceed the former transfer threshold',
      );
      stdout.writeln('PASS gateway_more_than_64MiB_on_one_connection');
    }
    stdout.writeln('PASS gateway_fragmented_large_reply');
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

    var recoveredSession = MobileOperations(ops.storage, ops.hostId);
    Map<String, dynamic> forkTask = Map<String, dynamic>.from(
      ((await second.call('bootstrap', null))['tasks'] as List).singleWhere(
            (t) => t['taskId'] == target,
          )
          as Map,
    );
    var renameLost = false;
    try {
      await recoveredSession.renameSession(
        LostWorkspaceReply(second, 'execute'),
        forkTask,
        'Recovered phone fork',
      );
    } on RemoteOutcomeUnknown {
      renameLost = true;
    }
    require(renameLost, 'Session rename loss fixture did not drop its reply');
    recoveredSession = MobileOperations(ops.storage, ops.hostId);
    final renameReceipt = await recoveredSession.verify(second);
    require(
      renameReceipt['action'] == 'rename' &&
          await recoveredSession.pending() == null,
      'Original rename receipt unavailable after restart',
    );
    forkTask = Map<String, dynamic>.from(
      ((await second.call('bootstrap', null))['tasks'] as List).singleWhere(
            (t) => t['taskId'] == target,
          )
          as Map,
    );
    require(
      forkTask['title'] == 'Recovered phone fork',
      'Frozen session title not applied',
    );

    // A delete that never arrived: no longer waiting clears only the phone
    // record, and the session is untouched.
    var unsentLost = false;
    try {
      await recoveredSession.deleteSession(
        LostWorkspaceReply(second, 'execute', before: true),
        forkTask,
      );
    } on RemoteOutcomeUnknown {
      unsentLost = true;
    }
    require(unsentLost, 'Unsent delete fixture did not become uncertain');
    final unfired = (await recoveredSession.pending())!;
    final abandoned = await recoveredSession.finishSessionCommandTracking(
      second,
      unfired,
    );
    require(
      abandoned['state'] == 'abandoned' &&
          await recoveredSession.pending() == null,
      'Not waiting did not clear the phone record',
    );
    require(
      ((await second.call('bootstrap', null))['tasks'] as List).any(
        (t) => t['taskId'] == target,
      ),
      'Not waiting unexpectedly deleted the task',
    );
    stdout.writeln('PASS session_unsent_delete_not_waited');
    var deleteLost = false;
    try {
      await recoveredSession.deleteSession(
        LostWorkspaceReply(second, 'execute'),
        forkTask,
      );
    } on RemoteOutcomeUnknown {
      deleteLost = true;
    }
    require(deleteLost, 'Session deletion loss fixture did not drop its reply');
    recoveredSession = MobileOperations(ops.storage, ops.hostId);
    final deleteReceipt = await recoveredSession.verify(second);
    require(
      deleteReceipt['action'] == 'delete' &&
          await recoveredSession.pending() == null,
      'Deletion receipt disappeared with deleted task',
    );
    require(
      !((await second.call('bootstrap', null))['tasks'] as List).any(
        (t) => t['taskId'] == target,
      ),
      'Deleted fork remains visible',
    );
    stdout.writeln('PASS session_rename_delete_original_receipt_recovery');
    final recipe = await second.call('project_runs', taskId) as Map;
    var editLost = false;
    try {
      await ops.runEdit(
        LostWorkspaceReply(second, 'project_run_edit'),
        taskId: taskId,
        generation: recipe['generation'],
        directoryIndex: 0,
        commandId: 'fixture-run',
        edit: {'action': 'rename', 'label': 'Mobile fixture run'},
      );
    } on RemoteOutcomeUnknown {
      editLost = true;
    }
    require(
      editLost &&
          (await MobileOperations(
                ops.storage,
                second.hostId,
              ).verify(second))['state'] ==
              'succeeded',
      'Frozen run rename did not recover from a lost reply',
    );
    final renamed = await second.call('project_runs', taskId) as Map;
    require(
      renamed['directories'][0]['commands'][0]['label'] == 'Mobile fixture run',
      'Run configuration rename was not persisted',
    );
    var launchLost = false;
    try {
      await ops.runStart(
        LostWorkspaceReply(second, 'project_run_start'),
        projectId: project,
        taskId: taskId,
        generation: renamed['generation'],
        directoryIndex: 0,
        commandId: 'fixture-run',
      );
    } on RemoteOutcomeUnknown {
      launchLost = true;
    }
    final launch = await MobileOperations(
      ops.storage,
      second.hostId,
    ).retry(second);
    require(
      launchLost && launch['state'] == 'confirmed',
      'Original project launch was not recovered',
    );
    final launchedId = launch['terminal']['id'] as String;
    require(
      (await second.call('terminal_list', project) as List)
              .where((r) => r['id'] == launchedId)
              .length ==
          1,
      'Project launch was duplicated',
    );
    await until(() async {
      final batch =
          await second!.call('terminal_read', [launchedId, '0']) as Map;
      return utf8
          .decode((batch['bytes'] as List).cast<int>(), allowMalformed: true)
          .contains('fixture-project-run');
    });
    var beforeLaunchLost = false;
    try {
      await ops.terminalStart(
        LostWorkspaceReply(second, 'terminal_start', before: true),
        projectId: project,
        cwd: directory.path,
      );
    } on RemoteOutcomeUnknown {
      beforeLaunchLost = true;
    }
    final unaccepted = await ops.sidePending();
    require(
      beforeLaunchLost && unaccepted != null && await ops.pending() == null,
      'Uncertain terminal launch was not isolated from message tracking',
    );
    await ops.finishLaunchTracking(second, unaccepted!);
    var fenced = false;
    try {
      await second.call('terminal_start', unaccepted['request']);
    } on ProtocolException {
      fenced = true;
    }
    require(
      fenced && await ops.sidePending() == null,
      'Late terminal launch was not fenced',
    );

    // Real isolated Git repository + local bare receiver. No user repository,
    // signing keys or external Git hosting is involved.
    final receiver = '${directory.parent.path}/fixture-git-receiver.git';
    await fixtureGit(directory, ['init', '-q', '-b', 'main']);
    await File(
      '${directory.path}/.git/info/exclude',
    ).writeAsString('*\n!fixture-git.txt\n');
    await Directory('${directory.path}/.git/empty-hooks').create();
    await fixtureGit(directory, [
      'config',
      'core.hooksPath',
      '${directory.path}/.git/empty-hooks',
    ]);
    await fixtureGit(directory, ['config', 'user.name', 'Gateway fixture']);
    await fixtureGit(directory, [
      'config',
      'user.email',
      'fixture@example.invalid',
    ]);
    await fixtureGit(directory, ['config', 'commit.gpgsign', 'false']);
    await fixtureGit(directory, ['config', 'tag.gpgsign', 'false']);
    await File('${directory.path}/fixture-git.txt').writeAsString('before\n');
    await fixtureGit(directory, ['add', '--', 'fixture-git.txt']);
    await fixtureGit(directory, ['commit', '-qm', 'fixture initial']);
    await fixtureGit(directory, ['init', '-q', '--bare', receiver]);
    await fixtureGit(directory, [
      '--git-dir',
      receiver,
      'config',
      'core.hooksPath',
      '${directory.path}/.git/empty-hooks',
    ]);
    await fixtureGit(directory, ['remote', 'add', 'origin', receiver]);
    await fixtureGit(directory, ['push', '-q', '-u', 'origin', 'main']);
    final originalHead = await fixtureGit(directory, ['rev-parse', 'HEAD']);
    await File('${directory.path}/fixture-git.txt').writeAsString('after\n');
    final diff =
        await second.call('review', {
              'operation': 'query',
              'arguments': {
                'taskId': taskId,
                'mode': 'uncommitted',
                'reference': null,
                'parent': null,
              },
            })
            as Map;
    final gitRoot =
        (diff['roots'] as List).firstWhere(
              (r) => r['root']['git'] == true,
            )['root']['id']
            as String;
    await ops.indexWrite(
      second,
      taskId: taskId,
      snapshotId: diff['id'],
      rootId: gitRoot,
      paths: ['fixture-git.txt'],
    );
    final staged =
        await second.call('review', {
              'operation': 'query',
              'arguments': {
                'taskId': taskId,
                'mode': 'staged',
                'reference': null,
                'parent': null,
              },
            })
            as Map;
    var lost = false;
    try {
      await ops.gitWrite(
        LostGitReply(second),
        taskId: taskId,
        rootId: gitRoot,
        action: 'commit',
        snapshotId: staged['id'],
        message: 'fixture mobile change',
        push: true,
      );
    } on RemoteOutcomeUnknown {
      lost = true;
    }
    require(
      lost && await ops.sidePending() != null && await ops.pending() == null,
      'Lost commit reply did not retain its identity',
    );
    final reopened = MobileOperations(ops.storage, second.hostId);
    require(
      (await reopened.verify(second))['state'] == 'awaiting_next',
      'Commit was not recovered read-only',
    );
    require(
      await fixtureGit(directory, [
            '--git-dir',
            receiver,
            'rev-parse',
            'refs/heads/main',
          ]) ==
          originalHead,
      'Merely verifying the commit started its push',
    );
    require(
      (await reopened.retry(second))['state'] == 'succeeded',
      'Original Git workflow did not finish',
    );
    require(
      await fixtureGit(directory, ['rev-list', '--count', 'HEAD']) == '2',
      'Commit was duplicated',
    );
    require(
      await fixtureGit(directory, [
            '--git-dir',
            receiver,
            'rev-parse',
            'refs/heads/main',
          ]) ==
          await fixtureGit(directory, ['rev-parse', 'HEAD']),
      'Original workflow did not push the confirmed commit',
    );
    require(
      await reopened.sidePending() == null,
      'Confirmed Git workflow remained pending',
    );

    // Review uses the same encrypted business gateway and the selected turn.
    // Only the isolated synthetic driver runs; cancellation needs no approval.
    final reviewers = await second.call('review_executors', []) as List;
    require(reviewers.isNotEmpty, 'Review Agent discovery unavailable');
    final review = await ops.startReview(
      second,
      taskId: taskId,
      turnId: turn,
      kind: 'code',
      executor: Map<String, dynamic>.from(reviewers.first as Map),
    );
    final reviewId = review['request']['runId'] as String;
    final replay = await second.call('start_turn_review', [review['request']]);
    require(
      replay['request']['runId'] == reviewId && await ops.pending() == null,
      'Review identity was not retained',
    );
    await second.call('cancel_turn_review', [taskId, reviewId]);
    await until<bool>(() async {
      final records = await second!.call('turn_reviews', [taskId]) as List;
      final matches = records
          .where((r) => r['request']['runId'] == reviewId)
          .toList();
      require(matches.length == 1, 'Review request was duplicated');
      return [
            'queued',
            'running',
            'cancelling',
          ].contains(matches.single['status'])
          ? null
          : true;
    });
    // Add only an isolated, empty fixture directory. The PC canonicalizes it,
    // and repeated registration must reuse the same shared project.
    final folder = await Directory('${directory.path}/mobile-project').create();
    final roots = await second.call('host_directories', {
      'path': null,
      'offset': 0,
    });
    require(roots['entries'] is List, 'PC start locations unavailable');
    final listing = await second.call('host_directories', {
      'path': folder.path,
      'offset': 0,
    });
    final canonical = listing['path'] as String;
    require(
      (listing['entries'] as List).isEmpty,
      'Fixture directory is not empty',
    );
    final added = await ops.addProject(
      second,
      path: canonical,
      displayName: 'Mobile project fixture',
    );
    require(added?['created'] == true, 'Project was not registered');
    final reused = await ops.addProject(
      second,
      path: canonical,
      displayName: 'Mobile project fixture',
    );
    require(
      reused?['projectId'] == added?['projectId'] &&
          reused?['created'] == false,
      'Duplicate project created',
    );
    final projects = (await second.call('bootstrap', null))['projects'] as List;
    require(
      projects.where((p) => p['path'] == canonical).length == 1,
      'Registered project not shared',
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
      evidence['requests'] >= 2 &&
          evidence['requests'] <= 3 &&
          evidence['tasks'] == 1,
      'Task or review duplicated after deleting the fixture fork',
    );
  } finally {
    await client.close();
    await second?.close();
  }
  stdout.writeln(
    'PASS: real Core gateway pairing/ACK loss/original identity recovery, send, stream, approval, stop, quota, reconnect, pin/archive, history search, Fork, turn review/replay/cancel, attachment upload/resume/receipt/send/read, run configuration/launch reply loss/recovery/late-launch fence, frozen index/commit reply loss/recovery/read-only verification/original push continuation, project registration/reuse and revocation (isolated synthetic agent).',
  );
}
