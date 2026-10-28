import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/data/local_workspace.dart';

void main() {
  test(
    'unsupported draft key cannot be adopted or overwrite current data',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'dogcodes-current-draft-',
      );
      var local = LocalWorkspace.directory(folder);
      final current = draftKey('pc', 'p', null);
      try {
        await local.saveDraft(current, {'text': 'current draft'});
        await expectLater(
          local.saveDraft('["pc","p",null]', {'text': 'unsupported draft'}),
          throwsFormatException,
        );
        local.dispose();
        local = LocalWorkspace.directory(folder);
        expect((await local.draft(current))!['text'], 'current draft');
      } finally {
        local.dispose();
        await folder.delete(recursive: true);
      }
    },
  );
  test(
    'replacement disk stores serialize concurrent draft writes in admission order',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'dogcodes-shared-draft-',
      );
      final a = LocalWorkspace.directory(folder),
          b = LocalWorkspace.directory(folder),
          key = draftKey('pc', 'p', 't');
      try {
        await Future.wait([
          for (var i = 0; i < 40; i++)
            (i.isEven ? a : b).saveDraft(key, {
              'text': 'draft-$i',
              'padding': 'x' * 8192,
            }),
        ]);
        expect((await a.draft(key))!['text'], 'draft-39');
        expect((await b.draft(key))!['text'], 'draft-39');
        expect(
          await folder
              .list()
              .where((e) => e is Directory && e.path.contains('.record-'))
              .toList(),
          isEmpty,
        );
      } finally {
        a.dispose();
        b.dispose();
        await folder.delete(recursive: true);
      }
    },
  );
  test(
    'a submitted clear through another disk store cannot be undone by an earlier flush',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'dogcodes-shared-clear-',
      );
      final a = LocalWorkspace.directory(folder),
          b = LocalWorkspace.directory(folder),
          key = draftKey('pc', 'p', 't');
      final original = <String, dynamic>{
        'text': 'already sent',
        'attachments': <dynamic>[],
      };
      try {
        await a.saveDraft(key, original);
        await Future.wait([
          a.saveDraft(key, original),
          b.clearSubmittedDraft({
            'key': key,
            'fingerprint': draftFingerprint(original),
          }),
        ]);
        expect((await a.draft(key))!['text'], '');
      } finally {
        a.dispose();
        b.dispose();
        await folder.delete(recursive: true);
      }
    },
  );

  test(
    'catalog refresh and upload progress do not change a draft content identity',
    () async {
      final store = LocalWorkspace.memory(), key = draftKey('pc', 'p', 't');
      final original = {
        'text': 'task',
        'choice': {
          'model': 'm',
          'thinking': 'high',
          'catalog': {'checkedAt': 'old'},
        },
        'attachments': [
          {
            'blobId': 'b',
            'request': {'uploadId': 'id'},
            'reference': null,
          },
        ],
      };
      final refreshed = {
        ...original,
        'choice': {
          ...original['choice'] as Map,
          'catalog': {'checkedAt': 'new'},
        },
        'attachments': [
          {
            'blobId': 'b',
            'request': {'uploadId': 'id'},
            'reference': {'path': '/managed/file'},
          },
        ],
      };
      expect(draftFingerprint(refreshed), draftFingerprint(original));
      await store.saveDraft(key, refreshed);
      await store.clearSubmittedDraft({
        'key': key,
        'fingerprint': draftFingerprint(original),
      });
      expect((await store.draft(key))!['text'], '');
    },
  );
  test(
    'drafts and managed attachment bytes survive cold restart and cache clear',
    () async {
      final folder = await Directory.systemTemp.createTemp('dogcodes-local-');
      try {
        final first = LocalWorkspace.directory(folder),
            key = draftKey('pc', 'p', 't');
        final draft = {
          'hostId': 'pc',
          'text': '未发送任务',
          'choice': {'model': 'm', 'thinking': 'high'},
          'attachments': [
            {'blobId': 'b1'},
          ],
        };
        await first.saveBlob('b1', Uint8List.fromList([1, 2, 3]));
        await first.saveDraft(key, draft);
        await first.cacheTimeline(
          'pc',
          't',
          {'items': [], 'lastSequence': 1},
          DateTime.now(),
          first.cacheEpoch,
        );
        final restarted = LocalWorkspace.directory(folder);
        expect(await restarted.draft(key), draft);
        expect(await restarted.blob('b1'), [1, 2, 3]);
        await restarted.clearCache();
        expect(await restarted.cachedTimeline('pc', 't'), isNull);
        expect(await restarted.draft(key), draft);
        expect(await restarted.blob('b1'), [1, 2, 3]);
        expect(await restarted.draft(draftKey('other', 'p', 't')), isNull);
        expect(await restarted.draft(draftKey('pc', 'p', 'other')), isNull);
      } finally {
        await folder.delete(recursive: true);
      }
    },
  );

  test(
    'late submission confirmation cannot erase newer draft text or options',
    () async {
      final store = LocalWorkspace.memory(), key = draftKey('pc', 'p', 't');
      final original = {
        'text': 'old',
        'choice': {'model': 'm'},
        'attachments': [],
      };
      await store.saveDraft(key, original);
      final identity = {'key': key, 'fingerprint': draftFingerprint(original)};
      final newer = {
        ...original,
        'text': 'new',
        'choice': {'model': 'other'},
      };
      await store.saveDraft(key, newer);
      await store.clearSubmittedDraft(identity);
      expect(await store.draft(key), newer);
      await store.clearSubmittedDraft({
        'key': key,
        'fingerprint': draftFingerprint(newer),
      });
      expect((await store.draft(key))!['text'], '');
      expect((await store.draft(key))!['choice'], {'model': 'other'});
    },
  );

  test(
    'recent cache evicts oldest sessions and rejects writes from before clear',
    () async {
      final store = LocalWorkspace.memory();
      for (var i = 0; i < 31; i++) {
        await store.cacheTimeline(
          'pc',
          '$i',
          {
            'items': [
              {'text': '$i'},
            ],
            'lastSequence': i,
          },
          DateTime.utc(2026, 10, 21).add(Duration(seconds: i)),
          store.cacheEpoch,
        );
      }
      expect((await store.cacheUsage()).sessions, 30);
      expect(await store.cachedTimeline('pc', '0'), isNull);
      expect(await store.cachedTimeline('pc', '30'), isNotNull);
      final oldEpoch = store.cacheEpoch;
      final clear = store.clearCache();
      final late = store.cacheTimeline(
        'pc',
        'late',
        {'items': [], 'lastSequence': 1},
        DateTime.now(),
        oldEpoch,
      );
      await Future.wait([clear, late]);
      expect((await store.cacheUsage()).sessions, 0);
    },
  );

  test(
    'long cached timelines are bounded and explicitly marked as partial',
    () async {
      final store = LocalWorkspace.memory();
      await store.cacheTimeline(
        'pc',
        't',
        {
          'items': List.generate(3000, (i) => {'text': '$i'}),
          'lastSequence': 3000,
        },
        DateTime.now(),
        store.cacheEpoch,
      );
      final saved = (await store.cachedTimeline('pc', 't'))!;
      expect(saved['truncated'], isTrue);
      expect(
        (saved['snapshot']['items'] as List).length,
        lessThanOrEqualTo(2000),
      );
      expect((saved['snapshot']['items'] as List).last['text'], '2999');
    },
  );

  test(
    'attachment garbage collection preserves shared draft references',
    () async {
      final store = LocalWorkspace.memory(),
          one = draftKey('pc', 'p', 'one'),
          two = draftKey('pc', 'p', 'two');
      await store.saveBlob('shared', Uint8List.fromList([1]));
      final data = {
        'text': '',
        'attachments': [
          {'blobId': 'shared'},
        ],
      };
      await store.saveDraft(one, data);
      await store.saveDraft(two, data);
      await store.saveDraft(one, {'text': '', 'attachments': []});
      expect(await store.blob('shared'), [1]);
      await store.saveDraft(two, {'text': '', 'attachments': []});
      await expectLater(store.blob('shared'), throwsStateError);
    },
  );

  test('forget removes only this PC local drafts and caches', () async {
    final store = LocalWorkspace.memory();
    for (final id in ['one', 'two']) {
      await store.saveDraft(draftKey(id, 'p', 't'), {'hostId': id, 'text': id});
      await store.cacheTimeline(
        id,
        't',
        {'items': [], 'lastSequence': 1},
        DateTime.now(),
        store.cacheEpoch,
      );
    }
    await store.forgetHost('one');
    expect(await store.draft(draftKey('one', 'p', 't')), isNull);
    expect(await store.cachedTimeline('one', 't'), isNull);
    expect(await store.draft(draftKey('two', 'p', 't')), isNotNull);
  });
}
