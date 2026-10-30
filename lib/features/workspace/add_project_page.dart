import 'package:dogcodes_app/l10n/strings.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import '../../app.dart';
import '../../core/host_directory_browser.dart';
import '../../core/host_hub.dart';
import '../../core/mobile_operations.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../inbox/pending_operation.dart';

typedef AddedProject = ({String hostId, String projectId});

Future<AddedProject?> showAddProject(BuildContext context, {String? hostId}) =>
    Navigator.of(context).push<AddedProject>(
      MaterialPageRoute(builder: (_) => AddProjectPage(hostId: hostId)),
    );

/// Browse a paired computer's existing directories. No phone file picker,
/// directory creation, repository cloning or new inbound port is involved.
class AddProjectPage extends StatefulWidget {
  const AddProjectPage({super.key, this.hostId});
  final String? hostId;
  @override
  State<AddProjectPage> createState() => _AddProjectPageState();
}

class _AddProjectPageState extends State<AddProjectPage> {
  late HostHub hub;
  bool _ready = false, adding = false;
  String? hostId, error, addedId;
  final address = TextEditingController(), name = TextEditingController();
  HostDirectoryBrowser? browser;
  HostState? get host => hub.host(hostId ?? '');

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ready) return;
    _ready = true;
    hub = AppScope.of(context).hub;
    hub.addListener(_hubChanged);
    final selected =
        hub.host(widget.hostId ?? '') ??
        hub.hosts.where((h) => h.online).firstOrNull ??
        hub.hosts.firstOrNull;
    if (selected != null) _selectHost(selected.id);
  }

  void _selectHost(String id) {
    browser?.removeListener(_changed);
    browser?.dispose();
    hostId = id;
    error = null;
    addedId = null;
    address.clear();
    name.clear();
    final h = host;
    browser = h == null
        ? null
        : (HostDirectoryBrowser(h)..addListener(_changed));
    _wasOnline = h?.online ?? false;
    browser?.open(null);
  }

  bool _wasOnline = false;

  /// A computer that was offline when the page opened lists its folders as
  /// soon as it connects, without the user hunting for 重试.
  void _hubChanged() {
    final online = host?.online ?? false, b = browser;
    if (online && !_wasOnline && b != null && !b.loaded && !b.loading) {
      unawaited(b.retry());
    }
    _wasOnline = online;
  }

  void _changed() {
    if (!mounted) return;
    final b = browser;
    if (b != null && !b.loading && !b.loadingMore && b.error == null) {
      address.text = b.path ?? '';
    }
    setState(() {});
  }

  Future<void> _registered(HostState h, String id) async {
    if (!mounted || hostId != h.id) return;
    setState(() {
      addedId = id;
      error = null;
    });
    await hub.refresh(h);
    if (!mounted || hostId != h.id) return;
    if (h.project(id) != null) {
      Navigator.of(context).pop<AddedProject>((hostId: h.id, projectId: id));
    } else {
      setState(() => error = tr("项目已添加，列表尚未同步。请重新连接后刷新结果。"));
    }
  }

  Future<void> _add() async {
    final h = host, b = browser;
    final link = h?.link;
    if (h == null ||
        link == null ||
        b == null ||
        !b.selectable ||
        address.text.trim() != b.path ||
        adding) {
      return;
    }
    setState(() {
      adding = true;
      error = null;
    });
    try {
      final value = await h.operations.addProject(
        link,
        path: b.path!,
        displayName: name.text,
      );
      if (value != null) await _registered(h, value['projectId'] as String);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      await hub.refreshOperation(h);
      if (mounted) setState(() => adding = false);
    }
  }

  @override
  void dispose() {
    hub.removeListener(_hubChanged);
    browser?.removeListener(_changed);
    browser?.dispose();
    address.dispose();
    name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    return ListenableBuilder(
      listenable: hub,
      builder: (context, _) {
        final h = host, b = browser;
        final existing = h?.projects
            .where(
              (p) =>
                  p['path'] == b?.path &&
                  ((p['additionalDirectories'] as List?)?.isEmpty ?? true) &&
                  (name.text.trim().isEmpty ||
                      p['displayName'] == name.text.trim()),
            )
            .firstOrNull;
        return Scaffold(
          appBar: DetailBar(title: tr("添加项目")),
          body: h == null || b == null
              ? EmptyNote(
                  icon: Icons.computer_outlined,
                  title: tr("还没有连接电脑"),
                  body: tr("请先绑定电脑，再选择电脑上的项目目录。"),
                )
              : SafeArea(
                  top: false,
                  child: Column(
                    children: [
                      Expanded(
                        child: ListView(
                          padding: const EdgeInsets.all(DcSpace.page),
                          children: [
                            PopupMenuButton<String>(
                              tooltip: tr("选择添加项目的电脑"),
                              enabled: !adding && addedId == null,
                              onSelected: (id) =>
                                  setState(() => _selectHost(id)),
                              itemBuilder: (_) => [
                                for (final computer in hub.hosts)
                                  PopupMenuItem(
                                    value: computer.id,
                                    child: Text(
                                      '${computer.name}${computer.online ? '' : tr(" · 离线")}',
                                    ),
                                  ),
                              ],
                              child: Panel(
                                child: Row(
                                  children: [
                                    const Icon(
                                      Icons.computer_outlined,
                                      size: 20,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(child: Text(h.name)),
                                    StatusLabel(
                                      h.online ? tr("在线") : tr("离线"),
                                      tone: h.online ? Tone.accent : Tone.muted,
                                    ),
                                    const Icon(Icons.expand_more),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              tr("选择这台电脑上已有的目录"),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              controller: address,
                              enabled:
                                  !adding &&
                                  addedId == null &&
                                  h.online &&
                                  !b.loading &&
                                  !b.loadingMore,
                              autocorrect: false,
                              enableSuggestions: false,
                              textInputAction: TextInputAction.go,
                              onChanged: (_) => setState(() {}),
                              onSubmitted: (value) => b.open(
                                value.trim().isEmpty ? null : value.trim(),
                              ),
                              decoration: InputDecoration(
                                labelText: tr("电脑目录路径"),
                                hintText: tr("输入完整路径，或在下方逐层选择"),
                                suffixIcon: IconButton(
                                  tooltip: tr("前往目录"),
                                  onPressed:
                                      adding || !h.online || addedId != null
                                      ? null
                                      : () => b.open(
                                          address.text.trim().isEmpty
                                              ? null
                                              : address.text.trim(),
                                        ),
                                  icon: const Icon(Icons.arrow_forward),
                                ),
                              ),
                            ),
                            Row(
                              children: [
                                TextButton.icon(
                                  onPressed:
                                      adding || addedId != null || !h.online
                                      ? null
                                      : () => b.open(null),
                                  icon: const Icon(
                                    Icons.home_outlined,
                                    size: 18,
                                  ),
                                  label: Text(tr("起始位置")),
                                ),
                                TextButton.icon(
                                  onPressed:
                                      adding ||
                                          addedId != null ||
                                          !h.online ||
                                          b.path == null ||
                                          b.loading
                                      ? null
                                      : () => b.open(b.parent),
                                  icon: const Icon(
                                    Icons.arrow_upward,
                                    size: 18,
                                  ),
                                  label: Text(tr("上一级")),
                                ),
                                const Spacer(),
                                TextButton.icon(
                                  onPressed:
                                      adding ||
                                          addedId != null ||
                                          !h.online ||
                                          b.loading
                                      ? null
                                      : () => b.setShowHidden(!b.showHidden),
                                  icon: Icon(
                                    b.showHidden
                                        ? Icons.visibility_off_outlined
                                        : Icons.visibility_outlined,
                                    size: 18,
                                  ),
                                  label: Text(
                                    b.showHidden ? tr("不显示隐藏") : tr("显示隐藏"),
                                  ),
                                ),
                              ],
                            ),
                            if (!h.online) InlineNotice(tr("电脑离线，请重新连接后浏览目录。")),
                            if (b.path != null && address.text.trim() != b.path)
                              InlineNotice(tr("目录路径已修改，请点箭头或回车确认后再添加。")),
                            if (b.loading)
                              const LinearProgressIndicator(minHeight: 2),
                            if (b.error != null) ...[
                              InlineNotice(b.error!, danger: true),
                              Align(
                                alignment: Alignment.centerLeft,
                                child: TextButton(
                                  onPressed: adding || !h.online
                                      ? null
                                      : b.retry,
                                  child: Text(tr("重试读取目录")),
                                ),
                              ),
                            ],
                            if (!b.loading &&
                                b.loaded &&
                                b.error == null &&
                                b.entries.isEmpty)
                              Padding(
                                padding: EdgeInsets.all(24),
                                child: Text(tr("当前目录没有子目录，可直接添加此目录。")),
                              ),
                            for (final directory in b.entries)
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: const Icon(Icons.folder_outlined),
                                title: Text(directory['name'] as String),
                                trailing: const Icon(Icons.chevron_right),
                                enabled:
                                    h.online &&
                                    !adding &&
                                    !b.loading &&
                                    addedId == null,
                                onTap: () =>
                                    b.open(directory['path'] as String),
                              ),
                            if (b.next != null && !b.loading)
                              TextButton(
                                onPressed: b.loadingMore || adding || !h.online
                                    ? null
                                    : b.more,
                                child: Text(
                                  b.loadingMore ? tr("加载中…") : tr("加载更多目录"),
                                ),
                              ),
                            const SizedBox(height: 12),
                            if (b.path != null) ...[
                              TextField(
                                controller: name,
                                enabled: !adding && addedId == null,
                                onChanged: (_) => setState(() {}),
                                maxLength: 120,
                                decoration: InputDecoration(
                                  labelText: tr("项目名称（可选）"),
                                  hintText: tr("留空使用目录名；已有项目会直接复用"),
                                ),
                              ),
                              SelectableText(
                                b.path!,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                            if (existing != null)
                              InlineNotice(
                                tr("该目录已添加为「{0}」，将打开已有项目。", [
                                  projectLabel(existing),
                                ]),
                              ),
                            if (error != null)
                              InlineNotice(error!, danger: true),
                            if (h.pendingOperation != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: PendingOperationCard(
                                  key: ValueKey(h.id),
                                  host: h,
                                  onProjectRegistered: (id) =>
                                      _registered(h, id),
                                ),
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
                            onPressed: addedId != null
                                ? (adding || !h.online
                                      ? null
                                      : () => _registered(h, addedId!))
                                : (adding ||
                                          !h.online ||
                                          h.pendingOperation != null ||
                                          !b.selectable ||
                                          address.text.trim() != b.path
                                      ? null
                                      : _add),
                            child: Text(
                              addedId != null
                                  ? tr("刷新添加结果")
                                  : adding
                                  ? tr("正在添加…")
                                  : existing != null
                                  ? tr("打开已有项目")
                                  : tr("添加此目录"),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
        );
      },
    );
  }
}
