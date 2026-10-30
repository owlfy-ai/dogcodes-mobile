import 'package:dogcodes_app/l10n/strings.dart';
import 'package:flutter/material.dart';
import '../../ui/theme.dart';

String workspaceDirectoryName(String path) =>
    path.split(RegExp(r'[\\/]')).where((part) => part.isNotEmpty).lastOrNull ??
    path;

/// A visible scope control shared by files, Git and run configurations.
/// Full paths distinguish sibling projects with identical folder names.
class WorkspaceDirectoryPicker<T> extends StatelessWidget {
  const WorkspaceDirectoryPicker({
    super.key,
    required this.directories,
    required this.value,
    required this.onChanged,
    this.tooltip = '切换目录',
  });

  final List<({T value, String path})> directories;
  final T? value;
  final ValueChanged<T>? onChanged;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    if (directories.isEmpty) return const SizedBox.shrink();
    final selected = directories.where((d) => d.value == value).firstOrNull;
    final changeable = directories.length > 1 && onChanged != null;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: DcSpace.page,
        vertical: 4,
      ),
      child: PopupMenuButton<T>(
        tooltip: tr(tooltip),
        enabled: changeable,
        initialValue: value,
        onSelected: onChanged,
        itemBuilder: (_) => [
          for (final directory in directories)
            CheckedPopupMenuItem<T>(
              value: directory.value,
              checked: directory.value == value,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(workspaceDirectoryName(directory.path)),
                  Text(
                    directory.path,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
        ],
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            border: Border.all(color: Theme.of(context).dividerColor),
            borderRadius: BorderRadius.circular(DcSpace.control),
          ),
          child: Row(
            children: [
              const Icon(Icons.folder_outlined, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      selected == null
                          ? tr("选择项目目录")
                          : tr("目录 · {0}", [
                              workspaceDirectoryName(selected.path),
                            ]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (selected != null)
                      Text(
                        selected.path,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
              if (directories.length > 1) ...[
                const SizedBox(width: 8),
                Text(
                  '${directories.indexWhere((d) => d.value == value) + 1}/${directories.length}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const Icon(Icons.expand_more, size: 20),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
