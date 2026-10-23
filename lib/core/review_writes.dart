part of 'mobile_operations.dart';

/// Freeze review identities before sending, including when the phone restarts.
extension ReviewWrites on MobileOperations {
  Future<dynamic> startReview(
    HostApi client, {
    required String taskId,
    required String turnId,
    required String kind,
    required Map<String, dynamic> executor,
    String? retryOf,
    Map<String, dynamic>? recheckOf,
  }) async {
    final saved = {
      'kind': 'review',
      'request': {
        'taskId': taskId,
        'turnId': turnId,
        'runId': operationId().replaceFirst('cmd_', 'run_'),
        'kind': kind,
        'executor': executor,
        'retryOf': retryOf,
        'recheckOf': recheckOf,
      },
    };
    await _storeNew(saved);
    return sendReviewWrite(client, saved);
  }

  Future<dynamic> startRepair(
    HostApi client, {
    required String taskId,
    required Map<String, dynamic> run,
    required List<int> findings,
  }) async {
    final indices = findings.toSet().toList()..sort();
    if (indices.isEmpty || run['inputSha256'] is! String) {
      throw const ProtocolException('请选择有效的审查问题。');
    }
    final saved = {
      'kind': 'repair',
      'request': {
        'action': 'start',
        'operationId': operationId(),
        'taskId': taskId,
        'reference': {
          'runId': run['request']['runId'],
          'inputSha256': run['inputSha256'],
          'findingIndices': indices,
        },
        // The PC resolves the primary Agent and assembles the review context.
        'target': null,
      },
    };
    await _storeNew(saved);
    return sendReviewWrite(client, saved);
  }

  void _validateReview(Map request, dynamic run) {
    final actual = run is Map ? run['request'] : null;
    if (actual is! Map ||
        [
          'taskId',
          'turnId',
          'runId',
          'kind',
          'retryOf',
        ].any((k) => actual[k] != request[k]) ||
        [
          'providerId',
          'installationId',
        ].any((k) => actual['executor']?[k] != request['executor']?[k]) ||
        [
          'runId',
          'repairTurnId',
        ].any((k) => actual['recheckOf']?[k] != request['recheckOf']?[k])) {
      throw const ProtocolException('审查回执与原请求不匹配，请保留原操作并核实。');
    }
  }

  Future<dynamic> _acceptRepair(
    Map<String, dynamic> saved,
    dynamic value,
  ) async {
    if (value == null) return null;
    final request = saved['request'] as Map;
    final intent = value is Map ? value['intent'] : null;
    if (intent is! Map ||
        intent['operationId'] != request['operationId'] ||
        intent['taskId'] != request['taskId'] ||
        intent['reference']?['runId'] != request['reference']['runId'] ||
        intent['reference']?['inputSha256'] !=
            request['reference']['inputSha256'] ||
        jsonEncode(intent['reference']?['findingIndices']) !=
            jsonEncode(request['reference']['findingIndices'])) {
      throw const ProtocolException('修复回执与原请求不匹配，请先核实电脑上的原修复。');
    }
    if (['submitted', 'abandoned'].contains(value['state'])) {
      await _clearIfCurrent(saved);
    }
    return value;
  }

  Future<dynamic> verifyReviewWrite(
    HostApi client,
    Map<String, dynamic> saved,
  ) async {
    final request = saved['request'] as Map;
    if (saved['kind'] == 'repair') {
      return _acceptRepair(
        saved,
        await client.call('review_repair', [
          {
            'action': 'get',
            'taskId': request['taskId'],
            'runId': request['reference']['runId'],
          },
        ]),
      );
    }
    final runs = await client.call('turn_reviews', [request['taskId']]);
    if (runs is! List) throw const ProtocolException('无法读取审查记录，请更新电脑端后重试。');
    for (final run in runs) {
      if (run is Map && run['request']?['runId'] == request['runId']) {
        _validateReview(request, run);
        await _clearIfCurrent(saved);
        return run;
      }
    }
    return null;
  }

  Future<dynamic> sendReviewWrite(
    HostApi client,
    Map<String, dynamic> saved,
  ) async {
    final request = saved['request'] as Map;
    final result = await client.call(
      saved['kind'] == 'repair' ? 'review_repair' : 'start_turn_review',
      [request],
    );
    if (saved['kind'] == 'repair') return _acceptRepair(saved, result);
    _validateReview(request, result);
    await _clearIfCurrent(saved);
    return result;
  }

  Future<dynamic> retryReviewWrite(
    HostApi client,
    Map<String, dynamic> saved,
  ) async {
    final found = await verifyReviewWrite(client, saved);
    if (found == null) return sendReviewWrite(client, saved);
    if (saved['kind'] == 'repair' && found['state'] == 'pending') {
      final request = saved['request'] as Map;
      return _acceptRepair(
        saved,
        await client.call('review_repair', [
          {
            'action': 'resume',
            'taskId': request['taskId'],
            'runId': request['reference']['runId'],
            'operationId': request['operationId'],
          },
        ]),
      );
    }
    return found;
  }
}
