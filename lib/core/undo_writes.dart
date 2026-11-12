part of 'mobile_operations.dart';

/// Undoing a whole turn's file changes (same as the desktop's turn summary).
/// The computer restores every file the turn changed, or none of them when a
/// file changed again afterwards. Each request carries an operation id, so an
/// interrupted undo is looked up on the computer instead of being sent twice.
extension UndoWrites on MobileOperations {
  /// Whether this turn's changes were already undone.
  Future<bool> undoStatus(
    HostApi client,
    String taskId,
    Map<String, dynamic> meta,
  ) async =>
      await _gitCall(client, 'undo_status', {
        'taskId': taskId,
        'artifactId': meta['artifactId'],
      }) ==
      true;

  Future<Map<String, dynamic>> undoTurn(
    HostApi client,
    String taskId,
    Map<String, dynamic> meta,
  ) async {
    final saved = <String, dynamic>{
      'kind': 'undo',
      'request': {
        'operationId': uuid(),
        'taskId': taskId,
        'artifactId': meta['artifactId'],
        'expectedPayloadSha256': meta['payloadSha256'],
        'confirmed': true,
      },
    };
    await _storeNew(saved);
    return sendUndo(client, saved);
  }

  Future<Map<String, dynamic>> sendUndo(
    HostApi client,
    Map<String, dynamic> saved,
  ) async {
    final request = Map<String, dynamic>.from(saved['request'] as Map);
    Object? sendError;
    try {
      await _gitWrite(client, 'undo', {
        'operationId': request.remove('operationId'),
        'request': request,
      }, saved);
    } catch (e) {
      // Refused or interrupted: the computer's receipt says which.
      sendError = e;
    }
    final found = await verifyUndo(client, saved);
    if (found == null) {
      if (sendError != null) throw sendError;
      throw ProtocolException(tr("还不确定本轮是否已撤销，可以稍后再核实。"));
    }
    if (found['state'] == 'failed') {
      throw ProtocolException(
        '${found['receipt']?['outcome']?['message'] ?? tr("撤销没有完成。")}',
      );
    }
    if (found['state'] != 'succeeded') {
      throw ProtocolException(tr("电脑正在撤销本轮修改，稍后再核实。"));
    }
    return found;
  }

  /// The computer's receipt for [saved], or null when it has none.
  Future<Map<String, dynamic>?> verifyUndo(
    HostApi client,
    Map<String, dynamic> saved,
  ) async {
    final request = saved['request'] as Map;
    final receipt = await _gitCall(client, 'file_operation', {
      'taskId': request['taskId'],
      'operationId': request['operationId'],
    });
    if (receipt == null) return null;
    final sent = receipt is Map ? receipt['request'] : null;
    if (sent is! Map ||
        sent['command'] != 'core_turn_undo' ||
        sent['arguments']?['request']?['artifactId'] != request['artifactId']) {
      throw ProtocolException(tr("撤销回执与这一轮不一致，未重新执行。"));
    }
    final state = receipt['closed'] == true
        ? 'closed'
        : receipt['outcome']?['status'];
    if (['succeeded', 'failed', 'closed'].contains(state)) {
      if (state != 'closed') {
        // The receipt has been read; the computer may forget it.
        await _gitCall(client, 'file_close', {
          'taskId': request['taskId'],
          'operationId': request['operationId'],
        }).catchError((Object _) => null);
      }
      await _clearIfCurrent(saved);
    }
    return {'state': state, 'receipt': receipt};
  }
}
