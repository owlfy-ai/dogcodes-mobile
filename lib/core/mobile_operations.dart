import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'host_api.dart';
import 'security/secret_storage.dart';
import 'security/host_lifecycle.dart';
import 'protocol.dart';
import 'pc_api.dart' show uuid;

import 'package:dogcodes_app/l10n/strings.dart';

part 'session_writes.dart';
part 'project_writes.dart';
part 'review_writes.dart';
part 'git_writes.dart';
part 'workspace_writes.dart';
part 'terminal_stop_writes.dart';
part 'power_writes.dart';
part 'cancel_writes.dart';
part 'recovery_journals.dart';

String operationId() {
  var value = BigInt.from(DateTime.now().millisecondsSinceEpoch) << 80;
  final random = Random.secure();
  for (var i = 0; i < 10; i++) {
    value |= BigInt.from(random.nextInt(256)) << (8 * i);
  }
  const chars = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  var result = '';
  for (var i = 0; i < 26; i++) {
    result = chars[(value & BigInt.from(31)).toInt()] + result;
    value >>= 5;
  }
  return 'cmd_$result';
}

class MobileOperations {
  MobileOperations(
    this.storage,
    this.hostId, {
    this.onDraftSubmitted,
    this.bindingEpoch,
  }) : _scope = HostRegistry(storage).host(hostId) {
    _scopeGeneration = _scope.generation;
  }
  final Future<void> Function(Map<String, dynamic> identity)? onDraftSubmitted;
  final SecretStorage storage;
  final String hostId;
  final HostLifecycle _scope;
  final String? bindingEpoch;
  late final int _scopeGeneration;
  bool get _journalsForgotten => _scopeGeneration != _scope.generation;
  bool get retired => _journalsForgotten;
  String get key => 'dogcodes.pending.v1.$hostId';

  /// Workspace writes wait in their own slot, so an unconfirmed Git step,
  /// terminal start or pin never blocks sending a message or answering an
  /// approval (the main slot).
  static const sideKinds = {
    'git',
    'index',
    'terminal',
    'run_config',
    'history',
  };
  String _laneKey(Object? kind) => sideKinds.contains(kind) ? '$key.side' : key;

  Future<void> _storeNew(Map<String, dynamic> value) =>
      _journalSerial(() async {
        await _requireBindingActive();
        final lane = _laneKey(value['kind']);
        if (await _read(lane) != null) {
          throw ProtocolException(
            lane == key ? tr("请先确认上一条消息或审批的结果。") : tr("请先确认上一项设置或工作区操作的结果。"),
          );
        }
        _requireJournalActive();
        value['localTrackingId'] ??= operationId();
        if (bindingEpoch != null) value['localBindingEpoch'] = bindingEpoch;
        await storage.write(lane, jsonEncode(value));
        _requireJournalActive();
      });

  Future<Map<String, dynamic>?> _read(String lane) async {
    if (_journalsForgotten || _scope.cleanupPending) return null;
    if (!await _scope.matches(bindingEpoch)) return null;
    final value = await storage.read(lane);
    if (_journalsForgotten || _scope.cleanupPending) return null;
    if (!await _scope.matches(bindingEpoch)) return null;
    if (value == null || value == 'null') return null;
    final record = jsonDecode(value) as Map<String, dynamic>;
    return bindingEpoch == null || record['localBindingEpoch'] == bindingEpoch
        ? record
        : null;
  }

  /// The unconfirmed message, approval or conversation operation.
  Future<Map<String, dynamic>?> pending() => _read(key);

  /// The unconfirmed setting or workspace operation.
  Future<Map<String, dynamic>?> sidePending() => _read('$key.side');

  /// What is stored now in the slot [saved] belongs to.
  Future<Map<String, dynamic>?> _current(Map<String, dynamic> saved) =>
      _read(_laneKey(saved['kind']));

  Future<void> _clearIfCurrent(Map<String, dynamic> saved) =>
      _journalSerial(() async {
        if (_journalsForgotten) return;
        if (_sameRecoveryValue(await _current(saved), saved)) {
          if (_journalsForgotten) return;
          await storage.write(_laneKey(saved['kind']), 'null');
        }
      });

  Future<dynamic> send(
    HostApi client,
    Map<String, dynamic> original, {
    Map<String, dynamic>? draft,
  }) async {
    if (await pending() != null) {
      throw ProtocolException(tr("请先确认上一条消息或审批的结果。"));
    }
    final request = {...original, 'operationId': operationId()};
    final saved = {'kind': 'send', 'request': request, 'draft': ?draft};
    await _storeNew(saved);
    return _send(client, request, saved);
  }

  Future<void> _finishSend(Map<String, dynamic> saved, dynamic value) async {
    if (value is Map && value['state'] == 'closed') {
      if (!_sameRecoveryValue(await _current(saved), saved)) return;
      if (value['resolution']?['status'] == 'submitted' &&
          saved['draft'] is Map) {
        await onDraftSubmitted?.call(
          Map<String, dynamic>.from(saved['draft'] as Map),
        );
      }
      await _clearIfCurrent(saved);
    }
  }

  Future<dynamic> _send(
    HostApi client,
    Map<String, dynamic> request,
    Map<String, dynamic> saved,
  ) async {
    final value = await _write(client, 'submission_intents', {
      'type': 'start',
      ...request,
    }, saved: saved);
    await _finishSend(saved, value);
    return value;
  }

  /// Read-only check of [operation] (default: the main slot's, else the side's).
  Future<dynamic> verify(
    HostApi client, [
    Map<String, dynamic>? operation,
  ]) async {
    final saved = operation ?? await pending() ?? await sidePending();
    if (saved == null) return null;
    if (saved['kind'] == 'terminal_stop') {
      return verifyTerminalStop(client, saved);
    }
    if (['terminal', 'run_config'].contains(saved['kind'])) {
      return verifyWorkspace(client, saved);
    }
    if (saved['kind'] == 'git') return verifyGit(client, saved);
    if (saved['kind'] == 'index') return verifyIndex(client, saved);
    if (['review', 'repair'].contains(saved['kind'])) {
      return verifyReviewWrite(client, saved);
    }
    if (saved['kind'] == 'project') return verifyProject(client, saved);
    if (['history', 'fork', 'session'].contains(saved['kind'])) {
      return verifySession(client, saved);
    }
    if (saved['kind'] == 'approval') {
      final value = await client.call('approval_receipt', [saved['query']]);
      // A receipt means the computer recorded this decision once; handing it
      // to the agent is the computer's job from here, and resending would be
      // refused. Nothing is left for the user to confirm.
      if (value != null) await _clearIfCurrent(saved);
      if (value == null) {
        final envelope = Map<String, dynamic>.from(saved['envelope'] as Map);
        final fresh = await client.call('bootstrap', null);
        final task = (fresh['tasks'] as List).where(
          (t) => t['taskId'] == saved['query']['taskId'],
        );
        if (task.isEmpty ||
            parseSequence(task.first['streamVersion'].toString()) >
                parseSequence(envelope['expectedStreamVersion'].toString())) {
          final resolved = await _write(
            client,
            'invalidate_approval_response',
            [saved['query'], envelope['expectedStreamVersion']],
            saved: saved,
          );
          if (resolved['status'] == 'invalidated') {
            await _clearIfCurrent(saved);
          }
          return resolved;
        }
      }
      return value;
    }
    final request = Map<String, dynamic>.from(saved['request'] as Map);
    final value = await client.call('submission_intents', {
      'type': 'get_start',
      'operationId': request['operationId'],
      'request': request,
    });
    await _finishSend(saved, value);
    return value;
  }

  Future<dynamic> retry(
    HostApi client, [
    Map<String, dynamic>? operation,
  ]) async {
    final saved = operation ?? await pending() ?? await sidePending();
    if (saved == null) return null;
    if (saved['kind'] == 'terminal_stop') {
      return retryTerminalStop(client, saved);
    }
    if (['terminal', 'run_config'].contains(saved['kind'])) {
      return retryWorkspace(client, saved);
    }
    if (saved['kind'] == 'git') return retryGit(client, saved);
    if (saved['kind'] == 'index') {
      if (saved['phase'] == 'closing') {
        await finishGitTracking(client, saved);
        return {'state': 'closed'};
      }
      final found = await verifyIndex(client, saved);
      return found ?? sendIndex(client, saved);
    }
    if (['review', 'repair'].contains(saved['kind'])) {
      return retryReviewWrite(client, saved);
    }
    if (saved['kind'] == 'project') {
      final found = await verifyProject(client, saved);
      return found ?? sendProject(client, saved);
    }
    if (['history', 'fork', 'session'].contains(saved['kind'])) {
      final receipt = await verifySession(client, saved);
      if (await _current(saved) == null) return receipt;
      if (receipt is Map && receipt['status'] == 'running') {
        throw ProtocolException(tr("Fork 正在电脑上执行，请等待并核实。"));
      }
      return sendSession(client, saved);
    }
    if (saved['kind'] == 'approval') {
      final found = await verify(client, saved);
      if (await _current(saved) == null) return found;
      if (found != null) throw ProtocolException(tr("原决定已受理，正在核实交付结果。"));
      await _write(client, 'execute', [saved['envelope']], saved: saved);
      return verify(client, saved);
    }
    if (saved['phase'] == 'closing') return _retireSubmission(client, saved);
    final request = Map<String, dynamic>.from(saved['request'] as Map);
    final verified = await verify(client, saved);
    if (verified is Map && verified['state'] == 'closed') return verified;
    return _send(client, request, saved);
  }

  Future<dynamic> abandon(HostApi client) async {
    final saved = await pending();
    if (saved == null) return null;
    if (saved['kind'] != 'send') throw ProtocolException(tr("请先核实原审批决定。"));
    return _retireSubmission(client, await _beginClosing(saved));
  }

  Future<dynamic> _retireSubmission(
    HostApi client,
    Map<String, dynamic> saved,
  ) async {
    final result = await _write(
      client,
      'submission_intents',
      {'type': 'retire', 'operationId': saved['request']['operationId']},
      saved: saved,
      closing: true,
    );
    if (result is Map && result['state'] == 'closed') {
      await _clearIfCurrent(saved);
    }
    return result;
  }

  /// Returns the computer's receipt, or null while it is still unconfirmed.
  Future<dynamic> approval(
    HostApi client,
    Map<String, dynamic> task,
    Map<String, dynamic> approval,
    String optionId, {
    Map<String, dynamic>? answer,
  }) async {
    if (await pending() != null) {
      throw ProtocolException(tr("请先确认上一条消息或审批的结果。"));
    }
    final id = operationId();
    final envelope = {
      'schemaVersion': 1,
      'commandId': id,
      'idempotencyKey': id,
      'actor': {'kind': 'local_user'},
      'expectedStreamVersion': task['streamVersion'],
      'issuedAt': DateTime.now().toUtc().toIso8601String(),
      'payload': {
        'type': 'respond_to_approval',
        'data': {
          'taskId': task['taskId'],
          'turnId': approval['turnId'],
          'requestedAtSequence': approval['requestedAtSequence'],
          'approvalId': approval['approvalId'],
          'optionId': optionId,
          'answer': ?answer,
        },
      },
    };
    final query = await _write(client, 'prepare_approval_response', [envelope]);
    final saved = {'kind': 'approval', 'query': query, 'envelope': envelope};
    await _storeNew(saved);
    await _write(client, 'execute', [envelope], saved: saved);
    return verify(client, saved);
  }
}
