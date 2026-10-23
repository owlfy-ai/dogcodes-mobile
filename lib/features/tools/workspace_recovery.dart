import 'package:flutter/material.dart';
import '../../core/host_hub.dart';
import '../inbox/pending_operation.dart';

/// Keep independent terminal stops accessible beside the affected workspace.
/// The bounded area leaves room for output and input on small phones.
class WorkspaceRecoveryCards extends StatelessWidget {
  const WorkspaceRecoveryCards({
    super.key,
    required this.host,
    required this.projectId,
    required this.onRecovered,
  });
  final HostState host;
  final String projectId;
  final VoidCallback onRecovered;
  @override
  Widget build(BuildContext context) {
    final stops = host.pendingTerminalStops
        .where((s) => s['projectId'] == projectId)
        .toList();
    if (stops.isEmpty &&
        host.pendingOperation == null &&
        host.sideOperation == null) {
      return const SizedBox.shrink();
    }
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: (MediaQuery.sizeOf(context).height * .34)
            .clamp(128, 260)
            .toDouble(),
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final stop in stops)
              PendingOperationCard(
                key: ValueKey('stop:${stop['request']['operationId']}'),
                host: host,
                operation: stop,
                onWorkspaceRecovered: onRecovered,
              ),
            if (host.sideOperation != null)
              PendingOperationCard(
                key: const ValueKey('side-pending-operation'),
                host: host,
                operation: host.sideOperation,
                onWorkspaceRecovered: onRecovered,
              ),
            if (host.pendingOperation != null)
              PendingOperationCard(
                key: const ValueKey('main-pending-operation'),
                host: host,
                onWorkspaceRecovered: onRecovered,
              ),
          ],
        ),
      ),
    );
  }
}
