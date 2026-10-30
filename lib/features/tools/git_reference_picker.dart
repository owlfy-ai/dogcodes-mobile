import 'package:dogcodes_app/l10n/strings.dart';
import 'package:flutter/material.dart';
import '../../core/host_api.dart';
import '../../core/host_hub.dart';
import '../../core/pc_api.dart';
import '../../ui/widgets.dart';
import 'workspace_connection.dart';

class GitReference {
  const GitReference(this.id, this.label, [this.parents = const []]);
  final String id, label;
  final List<String> parents;
}

String shortCommit(String id) => id.length > 8 ? id.substring(0, 8) : id;

/// Uses the PC's existing 50-commit pages; selecting a reference never checks
/// out a branch or changes the working tree.
class GitReferencePicker extends StatefulWidget {
  const GitReferencePicker({
    super.key,
    required this.api,
    required this.host,
    required this.taskId,
    required this.rootId,
    required this.commits,
  });
  final HostApi api;
  final HostState host;
  final String taskId, rootId;
  final bool commits;
  @override
  State<GitReferencePicker> createState() => _GitReferencePickerState();
}

class _GitReferencePickerState extends State<GitReferencePicker>
    with WorkspaceConnection<GitReferencePicker> {
  @override
  HostState get workspaceHost => widget.host;
  bool retired = false;
  @override
  void onWorkspaceConnectionChanged() {
    retired = true;
    entries.clear();
    if (ModalRoute.of(context)?.isCurrent == true) Navigator.pop(context);
  }

  final entries = <Map<String, dynamic>>[];
  bool loading = false, more = true;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (loading || retired) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final page = widget.commits
          ? await widget.api.gitHistory(
              widget.taskId,
              widget.rootId,
              skip: entries.length,
            )
          : await widget.api.gitBranches(widget.taskId, widget.rootId);
      if (!mounted || retired) return;
      setState(() {
        entries.addAll(page);
        more = widget.commits && page.length == 50;
      });
    } catch (e) {
      if (mounted && !retired) setState(() => error = '$e');
    } finally {
      if (mounted && !retired) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .7,
        child: Column(
          children: [
            ListTile(
              title: Text(widget.commits ? tr("选择历史提交") : tr("选择比较分支")),
              trailing: IconButton(
                tooltip: tr("关闭"),
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: entries.length,
                itemBuilder: (_, i) {
                  final entry = entries[i];
                  final id = widget.commits
                      ? '${entry['id']}'
                      : '${entry['name']}';
                  final label = widget.commits
                      ? shortCommit(id)
                      : id.replaceFirst(RegExp(r'^refs/(heads|remotes)/'), '');
                  return ListTile(
                    title: Text(
                      widget.commits ? '${entry['subject']}' : label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      widget.commits
                          ? '$label · ${entry['author']} · ${entry['date']}'
                          : shortCommit('${entry['commit']}'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => Navigator.pop(
                      context,
                      GitReference(id, label, [
                        for (final p in entry['parents'] as List? ?? []) '$p',
                      ]),
                    ),
                  );
                },
              ),
            ),
            if (error != null) InlineNotice(error!, danger: true),
            if (loading)
              const LinearProgressIndicator()
            else if (error != null || more)
              TextButton(
                onPressed: _load,
                child: Text(error != null ? tr("重试") : tr("加载更早的提交")),
              )
            else if (entries.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(widget.commits ? tr("没有提交记录") : tr("没有可比较的分支")),
              ),
          ],
        ),
      ),
    );
  }
}
