import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../../core/pc_api.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'tool_context.dart';

/// 07 文件: read-only browsing of the PC project; edits go through an Agent
/// or remote desktop.
class FilesPage extends StatefulWidget {
  const FilesPage({super.key, required this.tool});
  final ToolContext tool;
  @override
  State<FilesPage> createState() => _FilesPageState();
}

class _FilesPageState extends State<FilesPage> {
  final search = TextEditingController();
  List<String> roots = [];
  int root = 0;
  String path = '';
  List<Map<String, dynamic>> entries = [];
  List<Map<String, dynamic>>? matches;
  bool loading = true, searching = false;
  String? error;
  Timer? _debounce;

  ToolContext get tool => widget.tool;

  @override
  void initState() {
    super.initState();
    search.addListener(_onSearch);
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final link = tool.link, task = tool.taskId;
    if (link == null || task == null) return setState(() => loading = false);
    setState(() {
      loading = true;
      error = null;
    });
    try {
      if (roots.isEmpty) roots = await link.workspaceRoots(task);
      final list = await link.directory(task, root, path);
      list.sort((a, b) {
        final d =
            (b['directory'] == true ? 1 : 0) - (a['directory'] == true ? 1 : 0);
        return d != 0
            ? d
            : '${a['name']}'.toLowerCase().compareTo(
                '${b['name']}'.toLowerCase(),
              );
      });
      if (mounted) setState(() => entries = list);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void _onSearch() {
    _debounce?.cancel();
    final q = search.text.trim();
    if (q.isEmpty) return setState(() => matches = null);
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      final link = tool.link, task = tool.taskId;
      if (link == null || task == null) return;
      try {
        final result = await link.findFiles(task, q);
        if (!mounted || search.text.trim() != q) return;
        setState(
          () => matches = [
            for (final f in (result['files'] as List? ?? const []))
              Map<String, dynamic>.from(f as Map),
          ],
        );
      } catch (e) {
        if (mounted) showError(context, e);
      }
    });
  }

  void _open(String p) => setState(() {
    path = p;
    _load();
  });

  void _preview(int r, String p) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => FilePreviewPage(tool: tool, root: r, path: p),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    return PopScope(
      canPop: path.isEmpty && matches == null,
      onPopInvokedWithResult: (popped, _) {
        if (popped) return;
        if (matches != null) {
          search.clear();
          FocusScope.of(context).unfocus();
        } else if (segments.isNotEmpty) {
          _open(segments.sublist(0, segments.length - 1).join('/'));
        }
      },
      child: Scaffold(
        appBar: DetailBar(
          title: segments.isEmpty ? tool.projectName : segments.last,
          subtitle: tool.subtitle,
          actions: [
            if (roots.length > 1)
              PopupMenuButton<int>(
                tooltip: '切换目录',
                icon: const Icon(Icons.folder_copy_outlined),
                onSelected: (r) => setState(() {
                  root = r;
                  path = '';
                  _load();
                }),
                itemBuilder: (_) => [
                  for (var i = 0; i < roots.length; i++)
                    PopupMenuItem(value: i, child: Text(roots[i])),
                ],
              ),
          ],
        ),
        body: tool.link == null || tool.taskId == null
            ? ToolUnavailable(tool: tool)
            : Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      DcSpace.page,
                      4,
                      DcSpace.page,
                      8,
                    ),
                    child: TextField(
                      controller: search,
                      decoration: const InputDecoration(
                        hintText: '搜索文件',
                        prefixIcon: Icon(Icons.search),
                      ),
                    ),
                  ),
                  if (matches == null)
                    SizedBox(
                      height: 36,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(
                          horizontal: DcSpace.page,
                        ),
                        children: [
                          _Crumb(
                            label: tool.projectName,
                            onTap: () => _open(''),
                          ),
                          for (var i = 0; i < segments.length; i++) ...[
                            Icon(
                              Icons.chevron_right,
                              size: 16,
                              color: c.secondary,
                            ),
                            _Crumb(
                              label: segments[i],
                              onTap: () =>
                                  _open(segments.sublist(0, i + 1).join('/')),
                            ),
                          ],
                        ],
                      ),
                    ),
                  if (error != null) InlineNotice(error!, danger: true),
                  Expanded(child: _list()),
                ],
              ),
      ),
    );
  }

  Widget _list() {
    if (matches != null) {
      if (matches!.isEmpty) {
        return const Center(child: Text('没有匹配的文件'));
      }
      return ListView.builder(
        itemCount: matches!.length,
        itemBuilder: (_, i) {
          final m = matches![i];
          final p = '${m['path']}';
          return _FileRow(
            name: p.split('/').last,
            detail: p,
            directory: false,
            onTap: () => _preview((m['root'] as num?)?.toInt() ?? 0, p),
          );
        },
      );
    }
    if (loading && entries.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        itemCount: entries.length,
        itemBuilder: (_, i) {
          final e = entries[i];
          final dir = e['directory'] == true;
          final p = '${e['path']}';
          return _FileRow(
            name: '${e['name']}',
            directory: dir,
            onTap: () => dir ? _open(p) : _preview(root, p),
          );
        },
      ),
    );
  }
}

class _Crumb extends StatelessWidget {
  const _Crumb({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Text(label, style: Theme.of(context).textTheme.bodySmall),
      ),
    ),
  );
}

IconData fileIcon(String name, {bool directory = false}) {
  if (directory) return Icons.folder_outlined;
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  return switch (ext) {
    'png' ||
    'jpg' ||
    'jpeg' ||
    'gif' ||
    'webp' ||
    'svg' => Icons.image_outlined,
    'md' || 'txt' => Icons.article_outlined,
    'json' || 'yaml' || 'yml' || 'toml' => Icons.data_object,
    _ => Icons.description_outlined,
  };
}

class _FileRow extends StatelessWidget {
  const _FileRow({
    required this.name,
    required this.directory,
    required this.onTap,
    this.detail,
  });
  final String name;
  final String? detail;
  final bool directory;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => ListTile(
    minTileHeight: DcSpace.touch + 4,
    contentPadding: const EdgeInsets.symmetric(horizontal: DcSpace.page),
    leading: Icon(fileIcon(name, directory: directory), size: 22),
    title: Text(name, overflow: TextOverflow.ellipsis),
    subtitle: detail == null
        ? null
        : Text(
            detail!,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
    trailing: directory ? const Icon(Icons.chevron_right, size: 20) : null,
    onTap: onTap,
  );
}

class FilePreviewPage extends StatefulWidget {
  const FilePreviewPage({
    super.key,
    required this.tool,
    required this.root,
    required this.path,
  });
  final ToolContext tool;
  final int root;
  final String path;
  @override
  State<FilePreviewPage> createState() => _FilePreviewPageState();
}

class _FilePreviewPageState extends State<FilePreviewPage> {
  Map<String, dynamic>? preview;
  String? error;

  @override
  void initState() {
    super.initState();
    final link = widget.tool.link, task = widget.tool.taskId;
    if (link == null || task == null) return;
    link
        .filePreview(task, widget.root, widget.path)
        .then((v) => mounted ? setState(() => preview = v) : null)
        .catchError(
          (Object e) => mounted ? setState(() => error = '$e') : null,
        );
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.path.split('/').last;
    final text = preview?['text'] as String?;
    final image = preview?['image'] as String?;
    Widget body;
    if (error != null) {
      body = Center(child: InlineNotice(error!, danger: true));
    } else if (preview == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (image != null) {
      final data = image.contains(',') ? image.split(',').last : image;
      body = InteractiveViewer(
        maxScale: 8,
        child: Center(child: Image.memory(base64.decode(data))),
      );
    } else if (text != null) {
      body = CodeView(text: text);
    } else {
      body = const Center(child: Text('此文件无法预览（二进制或过大）'));
    }
    return Scaffold(
      appBar: DetailBar(title: name, subtitle: '${widget.path} · 只读'),
      body: body,
    );
  }
}

/// Monospace source with line numbers; scrolls both ways, never shrinks.
class CodeView extends StatelessWidget {
  const CodeView({super.key, required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    final lines = text.split('\n');
    final gutter = '${lines.length}'.length;
    const style = TextStyle(
      fontFamily: monoFamily,
      fontFamilyFallback: monoFallback,
      fontSize: 13,
      height: 1.5,
    );
    return Scrollbar(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  [for (var i = 1; i <= lines.length; i++) '$i'.padLeft(gutter)]
                      .join('\n'),
                  style: style.copyWith(color: c.secondary),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: DcSpace.page),
                child: SelectableText(text, style: style),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
