import 'package:flutter/widgets.dart';
import '../../app.dart';
import '../../core/host_hub.dart';

/// Open tool pages follow physical reconnections too. Old readers are detached;
/// this never replays terminal input or launches a project automatically.
mixin WorkspaceConnection<T extends StatefulWidget> on State<T> {
  HostState get workspaceHost;
  HostHub? workspaceHub;
  Object? _link;
  int? _epoch;
  bool? _online;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final hub = AppScope.of(context).hub;
    if (workspaceHub != hub) {
      workspaceHub?.removeListener(_connectionChanged);
      workspaceHub = hub;
      hub.addListener(_connectionChanged);
      _link = workspaceHost.link;
      _epoch = workspaceHost.connectionEpoch;
      _online = workspaceHost.online;
    }
  }

  void _connectionChanged() {
    if (!mounted) return;
    final host = workspaceHost;
    if (identical(_link, host.link) &&
        _epoch == host.connectionEpoch &&
        _online == host.online) {
      return;
    }
    _link = host.link;
    _epoch = host.connectionEpoch;
    _online = host.online;
    onWorkspaceConnectionChanged();
    setState(() {});
  }

  void onWorkspaceConnectionChanged();
  @override
  void dispose() {
    workspaceHub?.removeListener(_connectionChanged);
    super.dispose();
  }
}
