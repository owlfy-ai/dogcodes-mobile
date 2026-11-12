import 'package:dogcodes_app/l10n/strings.dart';
import 'package:flutter/material.dart';
import '../../core/host_hub.dart';

/// One PC and one of its projects. Workspace calls on the PC are task scoped,
/// so the project's most recent session anchors them.
class ToolContext {
  ToolContext(this.host, this.project);
  final HostState host;
  final Map<String, dynamic> project;
  String get projectId => project['projectId'] as String;
  String get projectName => projectLabel(project) ?? tr("未命名项目");
  String get path => project['path'] as String? ?? '';
  String? get taskId => host.latestTask(projectId)?['taskId'] as String?;
  HostLink? get link => host.link;
  String get subtitle => '$projectName · ${host.placeName(project)}';
}

/// Shows a PC-side error without hiding the screen behind it.
void showError(BuildContext context, Object error) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('$error'.replaceFirst('Exception: ', ''))),
  );
}

/// Placeholder when a tool cannot work yet (offline or no session).
class ToolUnavailable extends StatelessWidget {
  const ToolUnavailable({super.key, required this.tool});
  final ToolContext tool;
  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final offline = !tool.host.online;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          offline
              ? tr("电脑离线，重新连接后再试。")
              : tr("这个项目还没有会话。电脑以会话为单位授权工作区访问，请先在项目中开始一个会话。"),
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    );
  }
}
