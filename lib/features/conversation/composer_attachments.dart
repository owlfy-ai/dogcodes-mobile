import 'package:dogcodes_app/l10n/strings.dart';
import 'package:flutter/material.dart';
import '../../core/task_attachments.dart';
import '../../core/pc_api.dart' show uuid;
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../tools/files_page.dart';
import '../tools/tool_context.dart';
import 'composer_state.dart';

String attachmentSize(int bytes) => bytes < 1024
    ? '$bytes B'
    : bytes < 1024 * 1024
    ? '${(bytes / 1024).toStringAsFixed(0)} KB'
    : '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';

class ComposerAttachments extends StatefulWidget {
  const ComposerAttachments({
    super.key,
    required this.draft,
    this.enabled = true,
  });
  final ComposerState draft;
  final bool enabled;
  @override
  State<ComposerAttachments> createState() => _ComposerAttachmentsState();
}

class _ComposerAttachmentsState extends State<ComposerAttachments> {
  String? error;
  Future<void> _pick() async {
    final draft = widget.draft;
    FocusScope.of(context).unfocus();
    final selected = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheet) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (value, title, icon) in [
            ('photos', tr("照片"), Icons.photo_outlined),
            ('camera', tr("拍照"), Icons.camera_alt_outlined),
            ('files', tr("手机文件"), Icons.attach_file),
            ('pc', tr("电脑项目文件"), Icons.computer_outlined),
          ])
            ListTile(
              leading: Icon(icon),
              title: Text(title),
              enabled:
                  value != 'pc' ||
                  draft.host?.online == true &&
                      draft.host!.latestTask(draft.projectId) != null,
              subtitle:
                  value == 'pc' &&
                      draft.host?.latestTask(draft.projectId) == null
                  ? Text(tr("需先在此项目创建一个会话"))
                  : null,
              onTap: () => Navigator.pop(sheet, value),
            ),
          Padding(
            padding: EdgeInsets.all(16),
            child: Text(tr("最多 16 个附件，总大小不超过 25 MB。")),
          ),
        ],
      ),
    );
    if (selected == null || !mounted || draft.key == null) return;
    final key = draft.key;
    draft.setPicking(true);
    setState(() => error = null);
    try {
      await draft.flush();
      if (!mounted) return;
      if (selected == 'pc') {
        final h = draft.host!, project = draft.host!.project(draft.projectId)!;
        final source = await Navigator.of(context).push<Map<String, dynamic>>(
          MaterialPageRoute(
            builder: (_) => FilesPage(
              tool: ToolContext(h, project),
              selectAttachment: true,
            ),
          ),
        );
        if (source == null || !mounted) return;
        final id = uuid();
        final identity = await h.link!.call('workspace_attachment_info', {
          'source': source,
          'uploadId': id,
          'request': null,
        });
        if (draft.key != key) throw StateError(tr("草稿目标已变化，请回到原项目重新选择附件。"));
        await draft.add([
          TaskAttachment(
            request: Map<String, dynamic>.from(identity as Map),
            source: source,
          ),
        ]);
      } else {
        final items = await TaskAttachmentPicker.pick(
          draft.store,
          key!,
          selected,
        );
        if (draft.key != key) throw StateError(tr("草稿目标已变化，请回到原项目重新选择附件。"));
        await draft.add(items);
      }
    } catch (e) {
      if (mounted) setState(() => error = tr("无法添加附件：{0}", [e]));
    } finally {
      draft.setPicking(false);
      if (mounted) setState(() {});
    }
  }

  Future<void> _upload() async {
    try {
      await widget.draft.prepareAttachments();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<void> _remove(TaskAttachment item) async {
    try {
      await widget.draft.remove(item);
      if (mounted) setState(() => error = null);
    } catch (e) {
      if (mounted) setState(() => error = tr("未能移除附件：{0}", [e]));
    }
  }

  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final d = widget.draft;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            TextButton.icon(
              onPressed:
                  !widget.enabled ||
                      d.restoring ||
                      d.restoreFailed ||
                      d.uploading ||
                      d.picking ||
                      d.key == null
                  ? null
                  : _pick,
              icon: const Icon(Icons.attach_file, size: 19),
              label: Text(d.picking ? tr("正在添加…") : tr("添加附件")),
            ),
            if (d.attachments.isNotEmpty)
              InkWell(
                onTap: () => FocusScope.of(context).unfocus(),
                child: Text(
                  tr("{0} 个 · {1}", [
                    d.attachments.length,
                    attachmentSize(
                      d.attachments.fold<int>(0, (s, a) => s + a.size),
                    ),
                  ]),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            if (d.uploading)
              TextButton(onPressed: d.pauseUploads, child: Text(tr("暂停上传")))
            else if (d.attachments.any(
              (a) => a.reference == null || a.error != null,
            ))
              TextButton(
                onPressed: widget.enabled && d.host?.online == true
                    ? _upload
                    : null,
                child: Text(tr("上传／继续上传")),
              ),
          ],
        ),
        if (d.attachments.isNotEmpty &&
            MediaQuery.viewInsetsOf(context).bottom == 0)
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 150),
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final a in d.attachments)
                  Row(
                    children: [
                      const Icon(Icons.description_outlined, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              a.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              a.error ??
                                  (d.activeAttachment == a.id
                                      ? tr("上传 {0}%", [
                                          (a.offset /
                                                  (a.size == 0 ? 1 : a.size) *
                                                  100)
                                              .round(),
                                        ])
                                      : a.reference != null
                                      ? tr("已上传 · {0}", [
                                          attachmentSize(a.size),
                                        ])
                                      : tr("已保存在手机 · {0}", [
                                          attachmentSize(a.size),
                                        ])),
                              style: TextStyle(
                                fontSize: 12,
                                color: a.error == null
                                    ? context.dc.secondary
                                    : context.dc.removed,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: tr("移除附件 {0}", [a.name]),
                        onPressed: widget.enabled && !d.uploading
                            ? () => _remove(a)
                            : null,
                        icon: const Icon(Icons.close, size: 18),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        if (error != null) InlineNotice(error!, danger: true),
        if (d.restoreFailed)
          TextButton(onPressed: d.retryRestore, child: Text(tr("重试恢复草稿"))),
      ],
    );
  }
}
