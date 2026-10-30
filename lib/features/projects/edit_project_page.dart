import 'package:dogcodes_app/l10n/strings.dart';
import 'package:flutter/material.dart';
import '../../app.dart';
import '../../core/host_directory_browser.dart';
import '../../core/host_hub.dart';
import '../../core/pc_api.dart';
import '../../core/secure_host_client.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

/// Rename a project and change its directories, as the desktop's project
/// dialog does. The first directory is the main one; the PC validates all of
/// them and refuses the edit if the project changed in the meantime.
class EditProjectPage extends StatefulWidget {
  const EditProjectPage({
    super.key,
    required this.hostId,
    required this.projectId,
  });
  final String hostId, projectId;
  @override
  State<EditProjectPage> createState() => _EditProjectPageState();
}

class _EditProjectPageState extends State<EditProjectPage> {
  final name = TextEditingController();
  List<String> dirs = [];
  Map<String, dynamic>? original;
  bool saving = false;
  String? error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (original != null) return;
    final p = AppScope.of(
      context,
    ).hub.host(widget.hostId)?.project(widget.projectId);
    if (p == null) return;
    original = p;
    name.text = '${p['displayName'] ?? ''}';
    dirs = [
      '${p['path']}',
      for (final d in (p['additionalDirectories'] as List? ?? const [])) '$d',
    ];
  }

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  bool get _dirty {
    final p = original;
    if (p == null) return false;
    return name.text.trim() != '${p['displayName'] ?? ''}' ||
        dirs.first != p['path'] ||
        dirs.skip(1).join('\n') !=
            (p['additionalDirectories'] as List? ?? const []).join('\n');
  }

  bool _matches(Map<String, dynamic>? p) =>
      p != null &&
      p['displayName'] == name.text.trim() &&
      p['path'] == dirs.first &&
      (p['additionalDirectories'] as List? ?? const []).join('\n') ==
          dirs.skip(1).join('\n');

  Future<void> _add(HostState h) async {
    final path = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => DirectoryPickerPage(host: h)),
    );
    if (path == null || !mounted) return;
    if (dirs.contains(path)) {
      setState(() => error = tr("这个目录已经在项目中。"));
      return;
    }
    setState(() {
      dirs = [...dirs, path];
      error = null;
    });
  }

  Future<void> _save(HostState h) async {
    final link = h.link, p = original;
    if (link == null || p == null || saving) return;
    if (name.text.trim().isEmpty) {
      setState(() => error = tr("请填写项目名称。"));
      return;
    }
    setState(() {
      saving = true;
      error = null;
    });
    final hub = AppScope.of(context).hub;
    try {
      await link.updateProject(
        p,
        name: name.text,
        path: dirs.first,
        additionalDirectories: dirs.sublist(1),
      );
      await hub.refresh(h);
      if (mounted) Navigator.of(context).pop();
    } on RemoteOutcomeUnknown {
      // The edit may have reached the PC; look before offering a retry.
      await hub.refresh(h);
      if (!mounted) return;
      if (_matches(h.project(widget.projectId))) {
        Navigator.of(context).pop();
      } else {
        setState(() => error = tr("保存结果待核实，请刷新后查看项目，不要重复保存。"));
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e'.replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final hub = AppScope.of(context).hub;
    final c = context.dc;
    return ListenableBuilder(
      listenable: Listenable.merge([hub, name]),
      builder: (context, _) {
        final h = hub.host(widget.hostId);
        final ready = h != null && original != null;
        return Scaffold(
          appBar: DetailBar(
            title: tr("编辑项目"),
            actions: [
              TextButton(
                onPressed: ready && h.online && _dirty && !saving
                    ? () => _save(h)
                    : null,
                child: Text(saving ? tr("正在保存…") : tr("保存")),
              ),
            ],
          ),
          body: !ready
              ? EmptyNote(
                  icon: Icons.folder_off_outlined,
                  title: tr("项目不存在"),
                  body: tr("这个项目可能已在电脑上被移除。"),
                )
              : ListView(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  children: [
                    if (!h.online) InlineNotice(tr("电脑离线，重新连接后才能保存。")),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: DcSpace.page,
                      ),
                      child: TextField(
                        controller: name,
                        enabled: !saving,
                        maxLength: 120,
                        decoration: InputDecoration(labelText: tr("项目名称")),
                      ),
                    ),
                    SectionLabel(tr("目录")),
                    for (var i = 0; i < dirs.length; i++)
                      ListTile(
                        contentPadding: const EdgeInsets.only(
                          left: DcSpace.page,
                          right: 4,
                        ),
                        leading: Icon(
                          Icons.folder_outlined,
                          color: i == 0 ? c.accent : c.secondary,
                        ),
                        title: Text(
                          dirs[i],
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 14),
                        ),
                        subtitle: i == 0 ? Text(tr("主目录")) : null,
                        trailing: PopupMenuButton<String>(
                          tooltip: tr("目录操作"),
                          enabled: !saving,
                          onSelected: (v) => setState(() {
                            error = null;
                            final d = dirs[i];
                            final next = [...dirs]..removeAt(i);
                            dirs = v == 'main' ? [d, ...next] : next;
                          }),
                          itemBuilder: (_) => [
                            if (i > 0)
                              PopupMenuItem(
                                value: 'main',
                                child: Text(tr("设为主目录")),
                              ),
                            PopupMenuItem(
                              value: 'remove',
                              enabled: dirs.length > 1,
                              child: Text(tr("从项目中移除")),
                            ),
                          ],
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        DcSpace.page,
                        4,
                        DcSpace.page,
                        0,
                      ),
                      child: OutlinedButton.icon(
                        onPressed: h.online && !saving ? () => _add(h) : null,
                        icon: const Icon(Icons.create_new_folder_outlined),
                        label: Text(tr("添加目录")),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(DcSpace.page),
                      child: Text(
                        tr(
                          "主目录是会话默认的工作目录；附加目录同样对 Agent 可见。从项目中移除目录不会删除电脑上的文件。",
                        ),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    if (error != null) InlineNotice(error!, danger: true),
                  ],
                ),
        );
      },
    );
  }
}

/// Picks an existing directory on the computer and returns its path.
class DirectoryPickerPage extends StatefulWidget {
  const DirectoryPickerPage({super.key, required this.host});
  final HostState host;
  @override
  State<DirectoryPickerPage> createState() => _DirectoryPickerPageState();
}

class _DirectoryPickerPageState extends State<DirectoryPickerPage> {
  late final HostDirectoryBrowser b = HostDirectoryBrowser(widget.host)
    ..addListener(_changed);
  final address = TextEditingController();

  @override
  void initState() {
    super.initState();
    b.open(null);
  }

  void _changed() {
    if (!mounted) return;
    if (!b.loading && !b.loadingMore && b.error == null) {
      address.text = b.path ?? '';
    }
    setState(() {});
  }

  @override
  void dispose() {
    b.removeListener(_changed);
    b.dispose();
    address.dispose();
    super.dispose();
  }

  void _go() {
    final v = address.text.trim();
    b.open(v.isEmpty ? null : v);
  }

  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final online = widget.host.online;
    return Scaffold(
      appBar: DetailBar(title: tr("选择目录")),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(DcSpace.page),
                children: [
                  TextField(
                    controller: address,
                    enabled: online && !b.loading,
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.go,
                    onSubmitted: (_) => _go(),
                    decoration: InputDecoration(
                      labelText: tr("电脑目录路径"),
                      hintText: tr("输入完整路径，或在下方逐层选择"),
                      suffixIcon: IconButton(
                        tooltip: tr("前往目录"),
                        onPressed: online ? _go : null,
                        icon: const Icon(Icons.arrow_forward),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      TextButton.icon(
                        onPressed: online ? () => b.open(null) : null,
                        icon: const Icon(Icons.home_outlined, size: 18),
                        label: Text(tr("起始位置")),
                      ),
                      TextButton.icon(
                        onPressed: online && b.path != null && !b.loading
                            ? () => b.open(b.parent)
                            : null,
                        icon: const Icon(Icons.arrow_upward, size: 18),
                        label: Text(tr("上一级")),
                      ),
                    ],
                  ),
                  if (!online) InlineNotice(tr("电脑离线，请重新连接后浏览目录。")),
                  if (b.loading) const LinearProgressIndicator(minHeight: 2),
                  if (b.error != null) InlineNotice(b.error!, danger: true),
                  for (final d in b.entries)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.folder_outlined),
                      title: Text('${d['name']}'),
                      trailing: const Icon(Icons.chevron_right),
                      enabled: online && !b.loading,
                      onTap: () => b.open(d['path'] as String),
                    ),
                  if (b.next != null && !b.loading)
                    TextButton(
                      onPressed: b.loadingMore ? null : b.more,
                      child: Text(b.loadingMore ? tr("加载中…") : tr("加载更多目录")),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                DcSpace.page,
                8,
                DcSpace.page,
                12,
              ),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed:
                      online && b.selectable && address.text.trim() == b.path
                      ? () => Navigator.of(context).pop(b.path)
                      : null,
                  child: Text(tr("选择此目录")),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
