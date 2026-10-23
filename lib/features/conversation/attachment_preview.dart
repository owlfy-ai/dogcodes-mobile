import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import '../../core/host_api.dart';
import '../../data/local_workspace.dart';
import '../../ui/widgets.dart';
import '../tools/files_page.dart' show CodeView;
import 'turn_files.dart' show TurnScope;

class AttachmentButton extends StatelessWidget {
  const AttachmentButton({super.key, required this.attachment});
  final Map attachment;
  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    icon: Icon(
      '${attachment['mimeType']}'.startsWith('image/')
          ? Icons.image_outlined
          : Icons.attach_file,
      size: 18,
    ),
    label: Text(
      '${attachment['name'] ?? '附件'}',
      overflow: TextOverflow.ellipsis,
    ),
    onPressed: () {
      final link = TurnScope.of(context)?.link;
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              AttachmentPreviewPage(link: link, attachment: attachment),
        ),
      );
    },
  );
}

class AttachmentPreviewPage extends StatefulWidget {
  const AttachmentPreviewPage({
    super.key,
    required this.link,
    required this.attachment,
  });
  final HostApi? link;
  final Map attachment;
  @override
  State<AttachmentPreviewPage> createState() => _AttachmentPreviewPageState();
}

class _AttachmentPreviewPageState extends State<AttachmentPreviewPage> {
  late Future<Uint8List> future = _read();
  Future<Uint8List> _read() async {
    final link = widget.link;
    if (link == null) throw StateError('电脑离线。已缓存附件信息，原文需连接电脑后查看。');
    final bytes = BytesBuilder(copy: false);
    while (true) {
      final value = await link.call('attachment_read_chunk', [
        widget.attachment['path'],
        '${bytes.length}',
        65536,
      ]);
      if (value is! Map || value['bytes'] is! String) {
        throw StateError('电脑端暂不支持附件预览。');
      }
      final chunk = base64.decode(value['bytes'] as String);
      if (int.tryParse('${value['next']}') != bytes.length + chunk.length ||
          chunk.isEmpty && value['eof'] != true) {
        throw StateError('附件读取位置未确认。');
      }
      bytes.add(chunk);
      if (bytes.length > LocalWorkspace.maxAttachmentBytes) {
        throw StateError('附件过大，请在电脑上查看。');
      }
      if (value['eof'] == true) break;
    }
    final data = bytes.takeBytes(), integrity = widget.attachment['integrity'];
    if (integrity is Map &&
        (integrity['byteLength'] != data.length ||
            integrity['sha256'] != sha256.convert(data).toString())) {
      throw StateError('附件内容校验失败，未展示变化后的文件。');
    }
    return data;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: DetailBar(
      title: '${widget.attachment['name'] ?? '附件'}',
      subtitle: '任务附件 · 只读',
    ),
    body: FutureBuilder<Uint8List>(
      future: future,
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  InlineNotice('${snap.error}', danger: true),
                  if (widget.link != null)
                    TextButton(
                      onPressed: () => setState(() => future = _read()),
                      child: const Text('重试读取'),
                    ),
                ],
              ),
            ),
          );
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final mime = '${widget.attachment['mimeType']}';
        if (mime.startsWith('image/')) {
          return InteractiveViewer(
            maxScale: 8,
            child: Center(
              child: Image.memory(
                snap.data!,
                errorBuilder: (_, _, _) => const Text('图片无法解码，请在电脑上查看。'),
              ),
            ),
          );
        }
        if (mime.startsWith('text/') ||
            [
              'application/json',
              'application/xml',
              'application/javascript',
            ].contains(mime)) {
          try {
            return CodeView(text: utf8.decode(snap.data!));
          } catch (_) {
            /* Binary attachments retain their metadata. */
          }
        }
        return const Center(child: Text('该附件格式请在电脑上查看。'));
      },
    ),
  );
}
