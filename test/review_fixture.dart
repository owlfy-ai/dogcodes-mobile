import 'dart:convert';
import 'package:dogcodes_app/core/secure_host_client.dart';
import 'session_features_widget_test.dart' show SessionLink;
import 'widget_test.dart' show FakeLink;

class ReviewLink extends SessionLink {
  final starts = <Map<String, dynamic>>[], repairs = <Map<String, dynamic>>[];
  final runs = <Map<String, dynamic>>[];
  final sources = <List<dynamic>>[];
  bool loseStart = false,
      loseRepair = false,
      dropStart = false,
      autoComplete = true;
  Map<String, dynamic>? entry;
  @override
  Future<dynamic> call(String method, dynamic params) async {
    if (method == 'review_executors') {
      return [
        FakeLink.executor,
        {'providerId': 'cursor', 'installationId': 'cursor-1'},
      ];
    }
    if (method == 'turn_reviews') return jsonDecode(jsonEncode(runs));
    if (method == 'start_turn_review') {
      final request = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(params[0])) as Map,
      );
      starts.add(request);
      if (!dropStart &&
          !runs.any((r) => r['request']['runId'] == request['runId'])) {
        runs.add({
          'request': request,
          'status': autoComplete ? 'completed' : 'running',
          'createdAt': FakeLink.now,
          'inputSha256': 'sha-123',
          'workspaceReview': true,
          'result': '',
          'error': null,
          'report': {
            'structured': true,
            'warnings': [],
            'files': [],
            'findings': [
              {
                'fileId': 'file-1',
                'path': 'src/auth.ts',
                'severity': 'high',
                'title': '权限判断缺失',
                'description': '入口需要验证权限',
                'suggestion': '校验当前用户',
                'evidence': 'allow();',
                'locationVerified': true,
                'side': 'after',
                'startLine': 4,
                'endLine': 5,
              },
            ],
          },
        });
      }
      if (loseStart || dropStart) throw const RemoteOutcomeUnknown();
      return jsonDecode(
        jsonEncode(
          runs.firstWhere((r) => r['request']['runId'] == request['runId']),
        ),
      );
    }
    if (method == 'cancel_turn_review') {
      runs.firstWhere((r) => r['request']['runId'] == params[1])['status'] =
          'cancelled';
      return null;
    }
    if (method == 'review_source') {
      sources.add(List<dynamic>.from(params as List));
      return {'before': 'allow();', 'after': 'check();\nallow();'};
    }
    if (method == 'review_repair') {
      final request = params[0] as Map;
      if (request['action'] == 'get') {
        return entry == null ? null : jsonDecode(jsonEncode(entry));
      }
      if (request['action'] == 'start') {
        repairs.add(Map<String, dynamic>.from(request));
        entry = {
          'state': 'submitted',
          'intent': {
            'operationId': request['operationId'],
            'taskId': request['taskId'],
            'reference': request['reference'],
            'target': FakeLink.executor,
          },
        };
        if (loseRepair) throw const RemoteOutcomeUnknown();
      } else {
        repairs.add(Map<String, dynamic>.from(request));
        if (entry!['intent']['operationId'] != request['operationId']) {
          throw StateError('wrong operation');
        }
        entry!['state'] = request['action'] == 'resume'
            ? 'submitted'
            : 'abandoned';
      }
      return jsonDecode(jsonEncode(entry));
    }
    return super.call(method, params);
  }
}
