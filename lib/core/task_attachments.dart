import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mime/mime.dart';
import '../data/local_workspace.dart';
import 'host_api.dart';
import 'pc_api.dart' show uuid;
import 'protocol.dart';

class TaskAttachment {
  TaskAttachment({
    required this.request,
    this.blobId,
    this.source,
    this.reference,
  });
  final Map<String, dynamic> request;
  final String? blobId;
  final Map<String, dynamic>? source;
  Map<String, dynamic>? reference;
  int offset = 0;
  String? error;
  String get id => request['uploadId'] as String;
  String get name => request['name'] as String;
  int get size => (request['byteLength'] as num).toInt();
  Map<String, dynamic> toJson() => {
    'request': request,
    'blobId': blobId,
    'source': source,
    'reference': reference,
  };
  factory TaskAttachment.fromJson(Map value) => TaskAttachment(
    request: Map<String, dynamic>.from(value['request'] as Map),
    blobId: value['blobId'] as String?,
    source: value['source'] is Map
        ? Map<String, dynamic>.from(value['source'] as Map)
        : null,
    reference: value['reference'] is Map
        ? Map<String, dynamic>.from(value['reference'] as Map)
        : null,
  );

  static Future<TaskAttachment> local(
    LocalWorkspace store,
    XFile file, {
    String? owner,
  }) async {
    if (await file.length() > LocalWorkspace.maxAttachmentBytes) {
      throw const ProtocolException('附件总大小不能超过 25 MB。');
    }
    final bytes = await file.readAsBytes();
    final name = file.name
        .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '')
        .split(RegExp(r'[/\\]'))
        .last;
    final mime =
        lookupMimeType(name, headerBytes: bytes.take(32).toList()) ??
        'application/octet-stream';
    if (name.isEmpty || utf8.encode(name).length > 512) {
      throw const ProtocolException('附件文件名过长或无效。');
    }
    if (mime.startsWith('image/') &&
        ![
          'image/png',
          'image/jpeg',
          'image/webp',
          'image/gif',
        ].contains(mime)) {
      throw const ProtocolException('图片请使用 PNG、JPEG、GIF 或 WebP 格式。');
    }
    final id = uuid();
    await store.saveBlob(id, bytes, owner: owner);
    return TaskAttachment(
      blobId: id,
      request: {
        'uploadId': id,
        'name': name,
        'mimeType': mime,
        'byteLength': bytes.length,
        'sha256': sha256.convert(bytes).toString(),
      },
    );
  }
}

void validateAttachmentSelection(List<TaskAttachment> items) {
  if (items.length > 16) throw const ProtocolException('一次最多发送 16 个附件。');
  if (items.fold<int>(0, (total, a) => total + a.size) >
      LocalWorkspace.maxAttachmentBytes) {
    throw const ProtocolException('附件总大小不能超过 25 MB。');
  }
}

/// Durable identity + verified bytes make begin/chunk/commit explicitly resumable.
class AttachmentTransfer {
  AttachmentTransfer(this.store, {this.uploadChunkBytes = defaultChunkBytes});
  final LocalWorkspace store;

  /// 256 KiB raw (about 350 KB as base64) per round trip: a 25 MB file takes
  /// about 100 calls instead of 400, well inside the 8 MB request limit.
  static const defaultChunkBytes = 256 * 1024;
  final int uploadChunkBytes;
  Future<Map<String, dynamic>> upload(
    HostApi link,
    TaskAttachment item, {
    required bool Function() cancelled,
    required Future<void> Function() checkpoint,
  }) async {
    void check() {
      if (cancelled()) throw const ProtocolException('附件上传已暂停，可继续原上传。');
    }

    void accept(dynamic value) {
      if (value is! Map ||
          value['name'] != item.request['name'] ||
          value['mimeType'] != item.request['mimeType'] ||
          value['path'] is! String ||
          value['integrity']?['sha256'] != item.request['sha256'] ||
          value['integrity']?['byteLength'] != item.size) {
        throw const ProtocolException('附件回执与原文件不一致，未发送任务。');
      }
      item.reference = Map<String, dynamic>.from(value);
      item.offset = item.size;
    }

    check();
    final receipt = await link.call('attachment_receipt', item.request);
    check();
    if (receipt != null) {
      accept(receipt);
      await checkpoint();
      return item.reference!;
    }
    if (item.source != null) {
      final imported = await link.call('workspace_attachment_import', {
        'source': item.source,
        'uploadId': item.id,
        'request': item.request,
      });
      check();
      accept(imported);
      await checkpoint();
      return item.reference!;
    }
    final bytes = await store.blob(item.blobId!);
    if (bytes.length != item.size ||
        sha256.convert(bytes).toString() != item.request['sha256']) {
      throw const ProtocolException('本机附件内容已变化，请重新添加；未上传变化后的文件。');
    }
    final state = await link.call('attachment_upload_begin', item.request);
    check();
    if (state is! Map) throw const ProtocolException('电脑端暂不支持附件上传，请更新电脑端。');
    if (state['state'] == 'completed') {
      accept(state['attachment']);
      await checkpoint();
      return item.reference!;
    }
    var offset = int.tryParse('${state['offset']}');
    if (offset == null || offset < 0 || offset > bytes.length) {
      throw const ProtocolException('电脑返回的附件位置无效。');
    }
    item.offset = offset;
    await checkpoint();
    // The PC reports the resume offset on begin, so the local checkpoint only
    // needs to be roughly current: at most one draft write per second.
    var saved = DateTime.now();
    while (offset! < bytes.length) {
      check();
      final end = (offset + uploadChunkBytes).clamp(0, bytes.length);
      final result = await link.call('attachment_upload_chunk', [
        item.request,
        '$offset',
        base64.encode(Uint8List.sublistView(bytes, offset, end)),
      ]);
      check();
      if (result is! Map || int.tryParse('${result['offset']}') != end) {
        throw const ProtocolException('附件分块位置未确认，请继续原上传。');
      }
      offset = end;
      item.offset = end;
      if (end == bytes.length ||
          DateTime.now().difference(saved) >= const Duration(seconds: 1)) {
        await checkpoint();
        saved = DateTime.now();
      }
    }
    final result = await link.call('attachment_upload_commit', item.request);
    check();
    accept(result);
    await checkpoint();
    return item.reference!;
  }
}

/// Save the destination before opening native pickers (Android may kill us).
class TaskAttachmentPicker {
  static Future<List<TaskAttachment>> pick(
    LocalWorkspace store,
    String key,
    String source,
  ) async {
    final selection = await store.savePicker({'key': key});
    final created = <TaskAttachment>[];
    try {
      final List<XFile> files;
      if (source == 'files') {
        files = await openFiles();
      } else if (source == 'camera') {
        final file = await ImagePicker().pickImage(
          source: ImageSource.camera,
          imageQuality: 90,
          maxWidth: 4096,
          requestFullMetadata: false,
        );
        files = file == null ? [] : [file];
      } else {
        files = await ImagePicker().pickMultiImage(
          imageQuality: 90,
          maxWidth: 4096,
          requestFullMetadata: false,
        );
      }
      final saved = await store.draft(key);
      if (saved == null) throw const ProtocolException('原草稿不可读取，请重新选择附件。');
      final previous = [
        for (final a in saved['attachments'] as List? ?? [])
          TaskAttachment.fromJson(a as Map),
      ];
      for (final file in files) {
        final item = await TaskAttachment.local(store, file, owner: key);
        created.add(item);
        validateAttachmentSelection([...previous, ...created]);
      }
      await store.saveDraft(key, {
        ...saved,
        'attachments': [
          ...previous,
          ...created,
        ].map((a) => a.toJson()).toList(),
      });
      return created;
    } catch (_) {
      await store.releaseUnusedAttachments(
        created.map((a) => a.blobId).whereType<String>(),
      );
      rethrow;
    } finally {
      if (selection != null) await store.clearPicker(selection);
    }
  }

  static Future<void> recover(
    LocalWorkspace store, {
    Future<LostDataResponse> Function()? retrieve,
  }) async {
    final pending = await store.picker();
    if (!Platform.isAndroid && retrieve == null) {
      if (pending != null) await store.clearPicker(pending);
      return;
    }
    final lost = await (retrieve?.call() ?? ImagePicker().retrieveLostData());
    if (pending?['key'] is! String) return;
    final key = pending!['key'] as String;
    final saved = await store.draft(key);
    if (saved == null) {
      await store.clearPicker(pending);
      return;
    }
    final created = <TaskAttachment>[];
    try {
      if (lost.isEmpty) throw const ProtocolException('上次附件选择未完成，请重新选择。');
      if (lost.exception != null) throw lost.exception!;
      final items = [
        for (final a in saved['attachments'] as List? ?? [])
          TaskAttachment.fromJson(a as Map),
      ];
      for (final file in lost.files ?? <XFile>[]) {
        final item = await TaskAttachment.local(store, file, owner: key);
        created.add(item);
        validateAttachmentSelection([...items, item]);
        items.add(item);
      }
      await store.saveDraft(key, {
        ...saved,
        'attachments': items.map((a) => a.toJson()).toList(),
        'recoveryNote': '已恢复系统文件选择器返回的附件，请核对后发送。',
      });
    } catch (e) {
      await store.saveDraft(key, {
        ...saved,
        'recoveryNote': '附件选择未完成：$e，请重新选择。',
      });
    } finally {
      await store.releaseUnusedAttachments(
        created.map((a) => a.blobId).whereType<String>(),
      );
      await store.clearPicker(pending);
    }
  }
}
