import 'dart:convert';
import 'package:dogcodes_app/l10n/strings.dart';
import 'package:flutter/material.dart';
import '../../core/clipboard_transfer.dart';
import '../../ui/theme.dart';

/// Text the user confirmed for the computer, and whether to paste it there.
typedef ClipboardDraft = ({String text, bool paste});

/// Edit what goes to the computer before anything leaves the phone. Starts
/// from the phone clipboard so the common case is one tap.
Future<ClipboardDraft?> showClipboardComposer(
  BuildContext context, {
  required String initial,
  required bool canPaste,
}) => showModalBottomSheet<ClipboardDraft>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => _Composer(initial: initial, canPaste: canPaste),
);

class _Composer extends StatefulWidget {
  const _Composer({required this.initial, required this.canPaste});
  final String initial;
  final bool canPaste;
  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  late final text = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final value = text.text;
    final tooLarge = utf8.encode(value).length > ClipboardKind.text.maxBytes;
    final ready = value.isNotEmpty && !tooLarge;
    void done(bool paste) =>
        Navigator.of(context).pop((text: value, paste: paste));
    return Padding(
      padding: EdgeInsets.fromLTRB(
        DcSpace.page,
        0,
        DcSpace.page,
        MediaQuery.viewInsetsOf(context).bottom + 12,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(tr("发送文字到电脑"), style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            TextField(
              controller: text,
              autofocus: widget.initial.isEmpty,
              minLines: 3,
              maxLines: 8,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: tr("粘贴或输入要发送到电脑的文字"),
                border: const OutlineInputBorder(),
                errorText: tooLarge ? tr("文字超过 1 MB，无法发送") : null,
                helperText: tooLarge
                    ? null
                    : tr("{0} 个字符", [value.characters.length]),
                suffixIcon: value.isEmpty
                    ? null
                    : IconButton(
                        tooltip: tr("清空"),
                        icon: const Icon(Icons.clear),
                        onPressed: () => setState(text.clear),
                      ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: ready ? () => done(false) : null,
                    child: Text(tr("仅发送")),
                  ),
                ),
                if (widget.canPaste) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: ready ? () => done(true) : null,
                      child: Text(tr("发送并粘贴")),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Shows what arrived, already on the phone clipboard, so the user can tell
/// they got the right thing without switching apps.
Future<void> showReceivedText(BuildContext context, String text) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        watchAppLanguage(context);
        final c = context.dc;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              DcSpace.page,
              0,
              DcSpace.page,
              12,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(Icons.check_circle, color: c.accent, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        tr("已复制到手机剪贴板"),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    Text(
                      tr("{0} 个字符", [text.characters.length]),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height * 0.45,
                  ),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      border: Border.all(color: c.line),
                      borderRadius: BorderRadius.circular(DcSpace.control),
                    ),
                    child: SingleChildScrollView(child: SelectableText(text)),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(tr("完成")),
                ),
              ],
            ),
          ),
        );
      },
    );
