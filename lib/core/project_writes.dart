part of 'mobile_operations.dart';

/// The PC registration API deduplicates by canonical roots and optional name.
/// Keep those exact inputs, and query shared projects before an explicit retry.
extension ProjectWrites on MobileOperations {
  Future<Map<String, dynamic>?> addProject(
    HostApi client, {
    required String path,
    String displayName = '',
  }) async {
    if (path.isEmpty) throw const ProtocolException('请先选择电脑上的目录。');
    final saved = <String, dynamic>{
      'kind': 'project',
      'request': {
        'path': path,
        'displayName': displayName.trim(),
        'additionalDirectories': <String>[],
      },
    };
    await _storeNew(saved);
    return sendProject(client, saved);
  }

  Future<Map<String, dynamic>?> sendProject(
    HostApi client,
    Map<String, dynamic> saved,
  ) async {
    final request = saved['request'] as Map;
    // A replaced symlink must not silently redirect a recovered registration.
    final directory = await client.call('host_directories', {
      'path': request['path'],
      'offset': 0,
    });
    if (directory is! Map || directory['path'] != request['path']) {
      throw const ProtocolException('原项目目录已变化，请核实原结果后重新选择。');
    }
    final registered = await client.call('register_project', [request]);
    if (registered is! Map || registered['projectId'] is! String) {
      throw const ProtocolException('添加项目结果尚未确认，请核实原操作。');
    }
    final found = await verifyProject(
      client,
      saved,
      expectedId: registered['projectId'] as String,
    );
    return found == null
        ? null
        : {...found, 'created': registered['created'] == true};
  }

  Future<Map<String, dynamic>?> verifyProject(
    HostApi client,
    Map<String, dynamic> saved, {
    String? expectedId,
  }) async {
    final request = saved['request'] as Map;
    final snapshot = await client.call('bootstrap', null);
    if (snapshot is! Map || snapshot['projects'] is! List) {
      throw const ProtocolException('无法核实电脑上的项目，请重新连接后再试。');
    }
    for (final project in snapshot['projects'] as List) {
      if (project is! Map || project['projectId'] is! String) continue;
      if (expectedId != null && project['projectId'] != expectedId) continue;
      if (project['path'] != request['path'] ||
          (request['displayName'] != '' &&
              project['displayName'] != request['displayName']) ||
          jsonEncode(project['additionalDirectories'] ?? []) !=
              jsonEncode(request['additionalDirectories'])) {
        continue;
      }
      await _clearIfCurrent(saved);
      return {'projectId': project['projectId'], 'created': false};
    }
    return null;
  }
}
