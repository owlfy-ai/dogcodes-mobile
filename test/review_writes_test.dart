import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/core/mobile_operations.dart';
import 'package:dogcodes_app/core/security/secret_storage.dart';
import 'review_fixture.dart';
import 'widget_test.dart' show FakeLink;

Future<dynamic> start(MobileOperations ops, ReviewLink link) => ops.startReview(
  link,
  taskId: 't2',
  turnId: 'turn2',
  kind: 'code',
  executor: FakeLink.executor,
);

void main() {
  test(
    'lost review acknowledgement is recovered after restart without a duplicate',
    () async {
      final storage = MemorySecretStorage(),
          link = ReviewLink()..loseStart = true;
      final ops = MobileOperations(storage, 'pc');
      await expectLater(start(ops, link), throwsException);
      final original = await ops.pending();
      final restarted = MobileOperations(storage, 'pc');
      final result = await restarted.verify(link);
      expect(result['request'], original!['request']);
      expect(await restarted.pending(), isNull);
      expect(link.starts.length, 1);
    },
  );

  test(
    'explicit review retry freezes Agent, kind, turn, and run identity',
    () async {
      final ops = MobileOperations(MemorySecretStorage(), 'pc'),
          link = ReviewLink()..dropStart = true;
      await expectLater(start(ops, link), throwsException);
      expect(await ops.verify(link), isNull);
      expect(link.starts.length, 1);
      await expectLater(
        ops.startReview(
          link,
          taskId: 'other',
          turnId: 'other',
          kind: 'security',
          executor: FakeLink.executor,
        ),
        throwsException,
      );
      link.dropStart = false;
      await ops.retry(link);
      expect(link.starts.length, 2);
      expect(link.starts.first, link.starts.last);
      expect(await ops.pending(), isNull);
    },
  );

  test(
    'a mismatched review receipt cannot clear the pending operation',
    () async {
      final ops = MobileOperations(MemorySecretStorage(), 'pc'),
          link = ReviewLink()..loseStart = true;
      await expectLater(start(ops, link), throwsException);
      link.runs.first['request']['turnId'] = 'wrong-turn';
      await expectLater(ops.verify(link), throwsException);
      expect(await ops.pending(), isNotNull);
    },
  );

  test(
    'repair uses primary Agent and frozen context, then recovers lost reply',
    () async {
      final storage = MemorySecretStorage(),
          ops = MobileOperations(storage, 'pc'),
          link = ReviewLink();
      final run = await start(ops, link);
      link.loseRepair = true;
      await expectLater(
        ops.startRepair(
          link,
          taskId: 't2',
          run: Map<String, dynamic>.from(run as Map),
          findings: [0, 0],
        ),
        throwsException,
      );
      final request = link.repairs.single;
      expect(request['target'], isNull);
      expect(request['reference'], {
        'runId': run['request']['runId'],
        'inputSha256': 'sha-123',
        'findingIndices': [0],
      });
      final recovered = MobileOperations(storage, 'pc');
      expect((await recovered.retry(link))['state'], 'submitted');
      expect(link.repairs.length, 1);
      expect(await recovered.pending(), isNull);
    },
  );

  test(
    'pending repair resumes the same PC workflow instead of starting a new one',
    () async {
      final ops = MobileOperations(MemorySecretStorage(), 'pc'),
          link = ReviewLink();
      final run = await start(ops, link);
      link.loseRepair = true;
      await expectLater(
        ops.startRepair(
          link,
          taskId: 't2',
          run: Map<String, dynamic>.from(run as Map),
          findings: [0],
        ),
        throwsException,
      );
      link.entry!['state'] = 'pending';
      expect((await ops.verify(link))['state'], 'pending');
      final saved = await ops.pending();
      expect(saved, isNotNull);
      await ops.retry(link);
      expect(link.repairs.last['action'], 'resume');
      expect(
        link.repairs.last['operationId'],
        saved!['request']['operationId'],
      );
      expect(await ops.pending(), isNull);
    },
  );
}
