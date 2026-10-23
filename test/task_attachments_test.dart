import 'dart:convert';
import 'dart:typed_data';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart' show LostDataResponse;
import 'package:dogcodes_app/core/task_attachments.dart';
import 'package:dogcodes_app/data/local_workspace.dart';
import 'attachment_fixture.dart';

void main() {
  test(
    'Android lost picker result restores attachments into its original draft only',
    () async {
      final store = LocalWorkspace.memory(), key = draftKey('pc', 'p', 't');
      await store.saveDraft(key, {
        'hostId': 'pc',
        'text': 'keep',
        'attachments': [],
      });
      await store.savePicker({'key': key});
      await TaskAttachmentPicker.recover(
        store,
        retrieve: () async => LostDataResponse(
          files: [
            XFile.fromData(Uint8List.fromList([1, 2]), path: 'recovered.txt'),
          ],
        ),
      );
      final saved = (await store.draft(key))!;
      expect(saved['text'], 'keep');
      expect(saved['attachments'].single['request']['name'], 'recovered.txt');
      expect(await store.picker(), isNull);
      expect(await store.draft(draftKey('other', 'p', 't')), isNull);
    },
  );
  test(
    'lost chunk resumes at PC-confirmed offset with original identity',
    () async {
      final store = LocalWorkspace.memory(),
          link = AttachmentLink()..loseChunk = true;
      final item = await TaskAttachment.local(
        store,
        XFile.fromData(
          Uint8List.fromList(List.generate(150000, (i) => i % 256)),
          path: 'data.bin',
        ),
      );
      final transfer = AttachmentTransfer(store, uploadChunkBytes: 65536);
      Future<void> checkpoint() async {}
      await expectLater(
        transfer.upload(
          link,
          item,
          cancelled: () => false,
          checkpoint: checkpoint,
        ),
        throwsException,
      );
      final restored = TaskAttachment.fromJson(item.toJson());
      final result = await transfer.upload(
        link,
        restored,
        cancelled: () => false,
        checkpoint: checkpoint,
      );
      expect(link.chunks, [0, 65536, 131072]);
      expect(result['integrity']['byteLength'], 150000);
      expect(link.requests.keys.single, item.id);
      expect(link.commits, 1);
      await link.close();
    },
  );

  test(
    'lost commit is recovered by read-only receipt without publishing twice',
    () async {
      final store = LocalWorkspace.memory(),
          link = AttachmentLink()..loseCommit = true;
      final item = await TaskAttachment.local(
        store,
        XFile.fromData(Uint8List.fromList(utf8.encode('hello')), path: 'a.txt'),
      );
      final transfer = AttachmentTransfer(store, uploadChunkBytes: 65536);
      await expectLater(
        transfer.upload(
          link,
          item,
          cancelled: () => false,
          checkpoint: () async {},
        ),
        throwsException,
      );
      await transfer.upload(
        link,
        item,
        cancelled: () => false,
        checkpoint: () async {},
      );
      expect(link.commits, 1);
      expect(link.chunks, [0]);
      await link.close();
    },
  );

  test(
    'changed local bytes and mismatched receipts are rejected before submission',
    () async {
      final store = LocalWorkspace.memory(), link = AttachmentLink();
      final item = await TaskAttachment.local(
        store,
        XFile.fromData(Uint8List.fromList([1, 2]), path: 'a.txt'),
      );
      await store.saveBlob(item.blobId!, Uint8List.fromList([9, 9]));
      await expectLater(
        AttachmentTransfer(
          store,
        ).upload(link, item, cancelled: () => false, checkpoint: () async {}),
        throwsException,
      );
      expect(link.requests, isEmpty);
      link.receipts[item.id] = {
        'name': item.name,
        'mimeType': item.request['mimeType'],
        'path': '/managed/other',
        'integrity': {'sha256': 'other', 'byteLength': item.size},
      };
      await expectLater(
        AttachmentTransfer(
          store,
        ).upload(link, item, cancelled: () => false, checkpoint: () async {}),
        throwsException,
      );
      await link.close();
    },
  );

  test(
    'pause never advances another chunk and explicit resume uses original upload',
    () async {
      final store = LocalWorkspace.memory(), link = AttachmentLink();
      final item = await TaskAttachment.local(
        store,
        XFile.fromData(Uint8List(100000), path: 'a.bin'),
      );
      await expectLater(
        AttachmentTransfer(store, uploadChunkBytes: 65536).upload(
          link,
          item,
          cancelled: () => link.chunks.isNotEmpty,
          checkpoint: () async {},
        ),
        throwsException,
      );
      expect(link.chunks, [0]);
      await AttachmentTransfer(
        store,
        uploadChunkBytes: 65536,
      ).upload(link, item, cancelled: () => false, checkpoint: () async {});
      expect(link.chunks, [0, 65536]);
      await link.close();
    },
  );

  test('PC project attachment imports only its frozen file identity', () async {
    final store = LocalWorkspace.memory(), link = AttachmentLink();
    final item = TaskAttachment(
      request: {
        'uploadId': 'original-id',
        'name': 'a.txt',
        'mimeType': 'text/plain',
        'byteLength': 1,
        'sha256': 'original-hash',
      },
      source: {'taskId': 't2', 'root': 0, 'path': 'a.txt'},
    );
    await AttachmentTransfer(
      store,
    ).upload(link, item, cancelled: () => false, checkpoint: () async {});
    expect(link.sourceRequest!['request'], item.request);
    expect(link.sourceRequest!['source'], item.source);
    expect(link.chunks, isEmpty);
    await link.close();
  });

  test('attachment count and aggregate size match PC limits', () {
    TaskAttachment file(int size) => TaskAttachment(
      request: {'uploadId': 'id', 'name': 'a', 'byteLength': size},
    );
    expect(
      () => validateAttachmentSelection(List.generate(17, (_) => file(1))),
      throwsException,
    );
    expect(
      () => validateAttachmentSelection([
        file(13 * 1024 * 1024),
        file(13 * 1024 * 1024),
      ]),
      throwsException,
    );
    validateAttachmentSelection([file(0), file(25 * 1024 * 1024)]);
  });

  test(
    'a fast upload writes the draft once at the start and once at the end',
    () async {
      final store = LocalWorkspace.memory(), link = AttachmentLink();
      final item = await TaskAttachment.local(
        store,
        XFile.fromData(Uint8List(16 * 65536), path: 'big.bin'),
      );
      var checkpoints = 0;
      await AttachmentTransfer(store, uploadChunkBytes: 65536).upload(
        link,
        item,
        cancelled: () => false,
        checkpoint: () async => checkpoints++,
      );
      expect(link.chunks.length, 16);
      // begin offset, last chunk, commit
      expect(checkpoints, 3);
      await link.close();
    },
  );
}
