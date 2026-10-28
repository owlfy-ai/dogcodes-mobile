import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:dogcodes_app/app.dart';
import 'widget_test.dart' show FakeLink;
import 'package:file_selector/file_selector.dart';
import 'package:image_picker/image_picker.dart' show LostDataResponse;
import 'package:dogcodes_app/core/task_attachments.dart';
import 'package:dogcodes_app/core/protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/core/host_hub.dart';
import 'package:dogcodes_app/core/security/identity_store.dart';
import 'package:dogcodes_app/data/local_workspace.dart';
import 'package:dogcodes_app/features/conversation/composer_state.dart';
import 'binding_lifecycle_test.dart' as fixture;

void main() {
  test(
    'a fresh binding cannot load the previous binding host cache after a crash',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'dogcodes-binding-cache-',
      );
      final secrets = fixture.RestartableSecrets(),
          trusted = TrustedHostStore(secrets);
      final first = await trusted.beginPairing(fixture.pc);
      await fixture.confirm(trusted, first);
      final local = LocalWorkspace.directory(folder);
      HostHub? hub;
      try {
        await local.cacheHost(fixture.pc, {
          'snapshot': {
            'tasks': [
              {'taskId': 'private-old-task'},
            ],
          },
          'syncedAt': DateTime.now().toUtc().toIso8601String(),
        }, local.cacheEpoch);
        await trusted.forget(fixture.pc, first);
        final next = await trusted.beginPairing(fixture.pc);
        await fixture.confirm(trusted, next);
        hub = HostHub(
          storage: secrets,
          lister: trusted.list,
          local: LocalWorkspace.directory(folder),
        );
        await hub.load(connect: false);
        expect(hub.hosts.single.snapshot, isNull);
      } finally {
        hub?.dispose();
        local.dispose();
        await folder.delete(recursive: true);
      }
    },
  );

  test(
    'cold rebind cannot restore the old draft or attachment references',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'dogcodes-binding-draft-',
      );
      final secrets = fixture.RestartableSecrets(),
          trusted = TrustedHostStore(secrets);
      final first = await trusted.beginPairing(fixture.pc);
      await fixture.confirm(trusted, first);
      final original = HostHub(
        storage: secrets,
        lister: trusted.list,
        local: LocalWorkspace.directory(folder),
      );
      HostHub? fresh;
      ComposerState? oldDraft, freshDraft;
      try {
        await original.load(connect: false);
        oldDraft = ComposerState(original);
        await oldDraft.bind(original.hosts.single, 'p', 't');
        oldDraft.prompt.text = 'old private task';
        await oldDraft.flush();
        await trusted.forget(fixture.pc, first);
        final next = await trusted.beginPairing(fixture.pc);
        await fixture.confirm(trusted, next);
        fresh = HostHub(
          storage: secrets,
          lister: trusted.list,
          local: LocalWorkspace.directory(folder),
        );
        await fresh.load(connect: false);
        freshDraft = ComposerState(fresh);
        await freshDraft.bind(fresh.hosts.single, 'p', 't');
        expect(freshDraft.prompt.text, isEmpty);
        expect(freshDraft.attachments, isEmpty);
      } finally {
        oldDraft?.dispose();
        freshDraft?.dispose();
        original.dispose();
        fresh?.dispose();
        await Future<void>.delayed(Duration.zero);
        await folder.delete(recursive: true);
      }
    },
  );

  test(
    'a host list captured before forget cannot recreate the removed row',
    () async {
      final secrets = fixture.RestartableSecrets(),
          trusted = TrustedHostStore(secrets);
      final first = await trusted.beginPairing(fixture.pc);
      await fixture.confirm(trusted, first);
      Completer<List<Map<String, dynamic>>>? held;
      final hub = HostHub(
        storage: secrets,
        lister: () => held?.future ?? trusted.list(),
        forgetter: trusted.forget,
      );
      try {
        await hub.load(connect: false);
        final oldRecords = await trusted.list();
        held = Completer<List<Map<String, dynamic>>>();
        final loading = hub.load(connect: false);
        await hub.forget(hub.hosts.single);
        held.complete(oldRecords);
        await loading;
        expect(hub.hosts, isEmpty);
      } finally {
        hub.dispose();
      }
    },
  );
  test(
    'retired writes and late targeted cleanup cannot erase the replacement draft, picker or bytes',
    () async {
      final f = await ScopeFixture.create();
      try {
        f.local.attachBindings(f.secrets);
        final old = f.epoch, oldKey = f.key();
        await f.local.saveDraft(oldKey, {'text': 'old'});
        await f.rebind();
        final key = f.key();
        await f.local.saveBlob(
          'new-bytes',
          Uint8List.fromList([7]),
          owner: key,
        );
        await f.local.saveDraft(key, {
          'text': 'fresh',
          'attachments': [
            {'blobId': 'new-bytes'},
          ],
        });
        final selection = await f.local.savePicker({'key': key});
        await expectLater(
          f.local.saveDraft(oldKey, {'text': 'late'}),
          throwsA(isA<ProtocolException>()),
        );
        await f.local.cacheTimeline(
          fixture.pc,
          't',
          {
            'items': [
              {'itemId': 'old'},
            ],
          },
          DateTime.now(),
          f.local.cacheEpoch,
          bindingEpoch: old,
        );
        await f.local.forgetHost(fixture.pc, bindingEpoch: old);
        expect((await f.local.draft(key))!['text'], 'fresh');
        expect((await f.local.picker())!['pickerId'], selection!['pickerId']);
        expect(await f.local.blob('new-bytes'), [7]);
        expect(
          await f.local.cachedTimeline(fixture.pc, 't', bindingEpoch: f.epoch),
          isNull,
        );
      } finally {
        await f.dispose();
      }
    },
  );

  test(
    'late submitted acknowledgement for an old binding cannot clear a new identical draft',
    () async {
      final f = await ScopeFixture.create();
      try {
        f.local.attachBindings(f.secrets);
        final old = f.key();
        final data = <String, dynamic>{'text': 'same', 'attachments': []};
        await f.local.saveDraft(old, data);
        final receipt = {'key': old, 'fingerprint': draftFingerprint(data)};
        await f.rebind();
        await f.local.saveDraft(f.key(), data);
        await f.local.clearSubmittedDraft(receipt);
        expect((await f.local.draft(f.key()))!['text'], 'same');
      } finally {
        await f.dispose();
      }
    },
  );

  test(
    'replacement disk stores share cache-clear epochs and pending blob reservations',
    () async {
      final f = await ScopeFixture.create();
      LocalWorkspace? second;
      try {
        f.local.attachBindings(f.secrets);
        await f.local.prepareBinding(fixture.pc, f.epoch);
        second = LocalWorkspace.directory(f.folder!)..attachBindings(f.secrets);
        await second.prepareBinding(fixture.pc, f.epoch);
        final token = f.local.cacheEpoch, key = f.key();
        await f.local.saveBlob('pending', Uint8List.fromList([3]), owner: key);
        await second.forgetHost('another-pc');
        expect(await f.local.blob('pending'), [3]);
        await f.local.saveDraft(key, {
          'text': 'keep',
          'attachments': [
            {'blobId': 'pending'},
          ],
        });
        await f.local.cacheTimeline(
          fixture.pc,
          't',
          {
            'items': [
              {'itemId': 'first'},
            ],
          },
          DateTime.now(),
          token,
          bindingEpoch: f.epoch,
        );
        await second.clearCache();
        await f.local.cacheTimeline(
          fixture.pc,
          't',
          {
            'items': [
              {'itemId': 'stale'},
            ],
          },
          DateTime.now(),
          token,
          bindingEpoch: f.epoch,
        );
        expect(
          await f.local.cachedTimeline(fixture.pc, 't', bindingEpoch: f.epoch),
          isNull,
        );
        expect(await f.local.blob('pending'), [3]);
        expect((await f.local.draft(key))!['text'], 'keep');
        await f.local.cacheTimeline(
          fixture.pc,
          't',
          {
            'items': [
              {'itemId': 'fresh'},
            ],
          },
          DateTime.now(),
          f.local.cacheEpoch,
          bindingEpoch: f.epoch,
        );
        expect(
          (await second.cachedTimeline(
            fixture.pc,
            't',
            bindingEpoch: f.epoch,
          ))!['snapshot']['items'],
          [
            {'itemId': 'fresh'},
          ],
        );
      } finally {
        second?.dispose();
        await f.dispose();
      }
    },
  );

  test(
    'stale lost picker result cannot append to or clear the new binding selection',
    () async {
      final f = await ScopeFixture.create();
      try {
        f.local.attachBindings(f.secrets);
        await f.local.saveDraft(f.key(), {'text': 'old', 'attachments': []});
        await f.local.savePicker({'key': f.key()});
        final entered = Completer<void>(),
            reply = Completer<LostDataResponse>();
        final restoring = TaskAttachmentPicker.recover(
          f.local,
          retrieve: () {
            entered.complete();
            return reply.future;
          },
        );
        await entered.future;
        await f.rebind();
        await f.local.saveDraft(f.key(), {'text': 'fresh', 'attachments': []});
        final current = await f.local.savePicker({'key': f.key()});
        reply.complete(
          LostDataResponse(
            files: [
              XFile.fromData(Uint8List.fromList([1]), path: 'old.txt'),
            ],
          ),
        );
        await restoring;
        expect((await f.local.picker())!['pickerId'], current!['pickerId']);
        expect((await f.local.draft(f.key()))!['attachments'], isEmpty);
        expect((await f.local.draft(f.key()))!['text'], 'fresh');
      } finally {
        await f.dispose();
      }
    },
  );

  test(
    'a newer completed registry load wins over an older delayed load',
    () async {
      final f = await ScopeFixture.create(disk: false);
      final held = Completer<List<Map<String, dynamic>>>();
      var calls = 0;
      final hub = HostHub(
        storage: f.secrets,
        lister: () => calls++ == 0 ? held.future : f.trusted.list(),
      );
      try {
        final old = hub.load(connect: false);
        await f.rebind();
        final fresh = hub.load(connect: false);
        await fresh;
        final record = Map<String, dynamic>.from(
          (await f.trusted.list()).single,
        )..['bindingEpoch'] = 'obsolete';
        held.complete([record]);
        await old;
        expect(hub.hosts.single.bindingEpoch, f.epoch);
      } finally {
        hub.dispose();
        await f.dispose();
      }
    },
  );
  testWidgets(
    'late timeline and old draft never cross into a replacement binding',
    (t) async {
      final f = await ScopeFixture.create(disk: false);
      final hub = HostHub(
        storage: f.secrets,
        lister: f.trusted.list,
        local: f.local,
      );
      final old = Completer<dynamic>();
      final first = BindingTimelineLink('old private answer')..held = old;
      try {
        await hub.load(connect: false);
        await hub.attach(hub.hosts.single, first);
        await f.local.saveDraft(
          draftKey(fixture.pc, 'p1', 't2', bindingEpoch: f.epoch),
          {
            'hostId': fixture.pc,
            'text': 'old private draft',
            'attachments': [],
          },
        );
        await t.pumpWidget(DogCodesApp(hub: hub));
        await t.pumpAndSettle();
        await t.tap(find.text('修复移动端布局'));
        await t.pump(const Duration(milliseconds: 400));
        await t.pump();
        expect(
          (await f.local.draft(
            draftKey(fixture.pc, 'p1', 't2', bindingEpoch: f.epoch),
          ))!['text'],
          'old private draft',
        );
        expect(find.text('old private draft'), findsOneWidget);
        await f.rebind();
        await hub.load(connect: false);
        await hub.attach(
          hub.hosts.single,
          BindingTimelineLink('fresh binding answer'),
        );
        await t.pump(const Duration(milliseconds: 100));
        old.complete({
          'items': [
            {
              'itemId': 'old',
              'kind': 'assistant_message',
              'text': 'old private answer',
            },
          ],
          'lastSequence': 999,
        });
        await t.pumpAndSettle();
        expect(find.text('fresh binding answer'), findsOneWidget);
        expect(find.text('old private answer'), findsNothing);
        expect(find.text('old private draft'), findsNothing);
        expect(t.takeException(), isNull);
      } finally {
        if (!old.isCompleted) old.complete({'items': [], 'lastSequence': 0});
        await t.pumpWidget(const SizedBox());
        hub.dispose();
        await t.pump();
        await f.dispose();
      }
    },
  );
  test('a retired state cannot attach a new binding transport', () async {
    final f = await ScopeFixture.create(disk: false);
    final hub = HostHub(
      storage: f.secrets,
      lister: f.trusted.list,
      local: f.local,
    );
    final link = fixture.ClosingLink()..release.complete();
    try {
      await hub.load(connect: false);
      final old = hub.hosts.single;
      await f.rebind();
      await expectLater(
        hub.attach(old, link),
        throwsA(isA<ProtocolException>()),
      );
      expect(link.closed, isTrue);
      expect(old.online, isFalse);
    } finally {
      hub.dispose();
      await f.dispose();
    }
  });
}

class ScopeFixture {
  ScopeFixture(this.secrets, this.trusted, this.local, this.folder, this.epoch);
  final fixture.RestartableSecrets secrets;
  final TrustedHostStore trusted;
  final LocalWorkspace local;
  final Directory? folder;
  String epoch;
  static Future<ScopeFixture> create({bool disk = true}) async {
    final secrets = fixture.RestartableSecrets(),
        trusted = TrustedHostStore(secrets);
    final epoch = await trusted.beginPairing(fixture.pc);
    await fixture.confirm(trusted, epoch);
    final folder = disk
        ? await Directory.systemTemp.createTemp('dogcodes-scope-contract-')
        : null;
    return ScopeFixture(
      secrets,
      trusted,
      folder == null
          ? LocalWorkspace.memory()
          : LocalWorkspace.directory(folder),
      folder,
      epoch,
    );
  }

  String key() => draftKey(fixture.pc, 'p', 't', bindingEpoch: epoch);
  Future<void> rebind() async {
    await trusted.forget(fixture.pc, epoch);
    epoch = await trusted.beginPairing(fixture.pc);
    await fixture.confirm(trusted, epoch);
  }

  Future<void> dispose() async {
    local.dispose();
    if (folder != null) await folder!.delete(recursive: true);
  }
}

class BindingTimelineLink extends FakeLink {
  BindingTimelineLink(this.answer) : super(fixture.pc);
  final String answer;
  Completer<dynamic>? held;
  @override
  Future<dynamic> call(String method, dynamic args) async {
    if (method == 'timeline_snapshot') {
      final pending = held;
      held = null;
      if (pending != null) return pending.future;
      return {
        'items': [
          {'itemId': 'fresh', 'kind': 'assistant_message', 'text': answer},
        ],
        'lastSequence': 9,
      };
    }
    return super.call(method, args);
  }
}
