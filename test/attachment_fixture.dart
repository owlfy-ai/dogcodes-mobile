import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:dogcodes_app/core/secure_host_client.dart';
import 'widget_test.dart' show FakeLink;

class AttachmentLink extends FakeLink {
  AttachmentLink() : super('macbook-pro-host');
  final requests = <String, Map>{},
      bytes = <String, List<int>>{},
      receipts = <String, Map<String, dynamic>>{};
  final chunks = <int>[];
  final sends = <Map<String, dynamic>>[];
  bool loseChunk = false, loseCommit = false, loseSend = false;
  int commits = 0;
  Map<String, dynamic>? sourceRequest;
  @override
  Future<dynamic> call(String method, dynamic params) async {
    if (method == 'attachment_receipt') return receipts[params['uploadId']];
    if (method == 'attachment_upload_begin') {
      final id = params['uploadId'] as String;
      final old = requests[id];
      if (old != null && jsonEncode(old) != jsonEncode(params)) {
        throw StateError('changed metadata');
      }
      requests[id] = Map.from(params as Map);
      if (receipts[id] != null) {
        return {
          'state': 'completed',
          'offset': '${bytes[id]!.length}',
          'attachment': receipts[id],
        };
      }
      bytes.putIfAbsent(id, () => []);
      return {'state': 'uploading', 'offset': '${bytes[id]!.length}'};
    }
    if (method == 'attachment_upload_chunk') {
      final id = params[0]['uploadId'] as String,
          offset = int.parse(params[1] as String);
      final content = base64.decode(params[2] as String);
      if (offset != bytes[id]!.length) throw StateError('duplicate/gap');
      chunks.add(offset);
      bytes[id]!.addAll(content);
      if (loseChunk) {
        loseChunk = false;
        throw const RemoteOutcomeUnknown();
      }
      return {'offset': '${bytes[id]!.length}'};
    }
    if (method == 'attachment_upload_commit') {
      commits++;
      final id = params['uploadId'] as String;
      if (sha256.convert(bytes[id]!).toString() != params['sha256']) {
        throw StateError('bad digest');
      }
      final receipt = <String, dynamic>{
        'name': params['name'],
        'mimeType': params['mimeType'],
        'path': '/managed/$id/payload',
        'integrity': {
          'sha256': params['sha256'],
          'byteLength': params['byteLength'],
        },
      };
      receipts[id] = receipt;
      if (loseCommit) {
        loseCommit = false;
        throw const RemoteOutcomeUnknown();
      }
      return receipt;
    }
    if (method == 'attachment_upload_abort') {
      bytes.remove(params['uploadId']);
      return null;
    }
    if (method == 'workspace_attachment_info') return sourceRequest;
    if (method == 'workspace_attachment_import') {
      sourceRequest = Map<String, dynamic>.from(params as Map);
      return {
        'name': params['request']['name'],
        'mimeType': params['request']['mimeType'],
        'path': '/managed/import.txt',
        'integrity': {
          'sha256': params['request']['sha256'],
          'byteLength': params['request']['byteLength'],
        },
      };
    }
    if (method == 'submission_intents') {
      if (params['type'] == 'start') {
        sends.add(Map<String, dynamic>.from(params as Map));
        if (loseSend) throw const RemoteOutcomeUnknown();
      }
      return {
        'state': 'closed',
        'resolution': {'status': 'submitted', 'taskId': 't2'},
      };
    }
    return super.call(method, params);
  }
}
