import 'dart:io';
import 'dart:typed_data';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/core/host_hub.dart';
import 'package:dogcodes_app/core/security/secret_storage.dart';
import 'package:dogcodes_app/core/task_attachments.dart';
import 'package:dogcodes_app/data/local_workspace.dart';
import 'package:dogcodes_app/features/conversation/composer_state.dart';
import 'attachment_fixture.dart';

HostHub composerHub(LocalWorkspace store, MemorySecretStorage secrets) =>
    HostHub(
      storage: secrets,
      local: store,
      lister: () async => [
        {'hostId': 'macbook-pro-host', 'displayName': 'PC'},
      ],
    );

void main() {
  test(
    'cold offline restart restores text, model, thinking and attachments without sending',
    () async {
      final folder = await Directory.systemTemp.createTemp('dogcodes-draft-');
      final secrets = MemorySecretStorage(), link = AttachmentLink();
      final store = LocalWorkspace.directory(folder),
          hub = composerHub(LocalWorkspace.directory(folder), secrets);
      await hub.load(connect: false);
      await hub.attach(hub.hosts.single, link);
      final draft = ComposerState(hub);
      await draft.bind(hub.hosts.single, 'p1', 't2');
      draft.prompt.text = '离线继续编写';
      draft.choice = draft.choice!.withThinking('high');
      await draft.add([
        await TaskAttachment.local(
          hub.local,
          XFile.fromData(Uint8List.fromList([1, 2]), path: 'a.txt'),
        ),
      ]);
      await draft.flush();
      final key = draft.key!;
      draft.dispose();
      hub.dispose();
      final restarted = composerHub(store, secrets);
      await restarted.load(connect: false);
      expect(restarted.hosts.single.projects, isNotEmpty);
      expect(restarted.hosts.single.online, isFalse);
      final restored = ComposerState(restarted);
      await restored.bind(restarted.hosts.single, 'p1', 't2');
      expect(restored.prompt.text, '离线继续编写');
      expect(restored.choice!.thinking, 'high');
      expect(restored.attachments.single.name, 'a.txt');
      expect(await store.blob(restored.attachments.single.blobId!), [1, 2]);
      expect((await store.draft(key))!['text'], '离线继续编写');
      expect(link.sends, isEmpty);
      restored.dispose();
      restarted.dispose();
      // Drain asynchronous disposal saves before deleting the isolated directory.
      await store.draft(key);
      await hub.local.draft(key);
      await folder.delete(recursive: true);
    },
  );

  test(
    'switching drafts isolates scopes and retains selections when returning',
    () async {
      final hub = composerHub(LocalWorkspace.memory(), MemorySecretStorage()),
          link = AttachmentLink();
      await hub.load(connect: false);
      await hub.attach(hub.hosts.single, link);
      final d = ComposerState(hub), h = hub.hosts.single;
      await d.bind(h, 'p1', 't2');
      d.prompt.text = 'one';
      d.choice = d.choice!.withThinking('high');
      await d.bind(h, 'p1', 'other');
      expect(d.prompt.text, '');
      d.prompt.text = 'two';
      await d.bind(h, 'p1', 't2');
      expect(d.prompt.text, 'one');
      expect(d.choice!.thinking, 'high');
      d.dispose();
      hub.dispose();
    },
  );

  test(
    'unknown send keeps draft and original attachment; receipt clears exactly that draft',
    () async {
      final secrets = MemorySecretStorage(),
          store = LocalWorkspace.memory(),
          link = AttachmentLink()..loseSend = true;
      final hub = composerHub(store, secrets);
      await hub.load(connect: false);
      await hub.attach(hub.hosts.single, link);
      final h = hub.hosts.single, d = ComposerState(hub);
      await d.bind(h, 'p1', 't2');
      d.prompt.text = 'task';
      await d.add([
        await TaskAttachment.local(
          store,
          XFile.fromData(Uint8List.fromList([1]), path: 'a.txt'),
        ),
      ]);
      final refs = await d.prepareAttachments(), identity = d.identity;
      await expectLater(
        h.operations.send(link, {
          'taskId': 't2',
          'projectId': 'p1',
          'target': d.choice!.executor,
          'input': {'prompt': d.prompt.text, 'attachments': refs},
        }, draft: identity),
        throwsException,
      );
      expect((await store.draft(d.key!))!['attachments'], isNotEmpty);
      expect(await h.operations.pending(), isNotNull);
      await h.operations.verify(link);
      expect(link.sends.length, 1);
      expect((await store.draft(d.key!))!['text'], '');
      await d.submitted(identity);
      expect(d.prompt.text, '');
      expect(d.attachments, isEmpty);
      expect(d.choice, isNotNull);
      d.dispose();
      hub.dispose();
    },
  );

  test(
    'editing after send freezes a new draft that a late acknowledgement preserves',
    () async {
      final hub = composerHub(LocalWorkspace.memory(), MemorySecretStorage()),
          link = AttachmentLink();
      await hub.load(connect: false);
      await hub.attach(hub.hosts.single, link);
      final d = ComposerState(hub);
      await d.bind(hub.hosts.single, 'p1', 't2');
      d.prompt.text = 'first';
      await d.flush();
      final identity = d.identity;
      d.prompt.text = 'next';
      await d.flush();
      await d.submitted(identity);
      expect(d.prompt.text, 'next');
      expect((await hub.local.draft(d.key!))!['text'], 'next');
      d.dispose();
      hub.dispose();
    },
  );
}
