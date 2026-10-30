import 'package:dogcodes_app/l10n/strings.dart';
import 'package:flutter/material.dart';
import '../../core/host_hub.dart';
import '../../core/pc_api.dart';
import '../../core/mobile_operations.dart';
import '../../ui/widgets.dart';
import '../tools/workspace_connection.dart';

/// PC idle-sleep policy; locking and explicit sleep remain system choices.
class KeepAwake extends StatefulWidget {
  const KeepAwake({super.key, required this.host});
  final HostState host;
  @override
  State<KeepAwake> createState() => _KeepAwakeState();
}

class _KeepAwakeState extends State<KeepAwake>
    with WorkspaceConnection<KeepAwake> {
  @override
  HostState get workspaceHost => widget.host;
  Map<String, dynamic>? policy;
  bool busy = false, loading = false;
  int _order = 0, _generation = 0;
  String? error, note;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void onWorkspaceConnectionChanged() {
    _generation++;
    _order++;
    policy = null;
    busy = false;
    error = null;
    note = null;
    if (widget.host.online) _load();
  }

  Future<void> _load() async {
    final link = widget.host.link,
        epoch = widget.host.connectionEpoch,
        order = ++_order;
    if (link == null || !widget.host.online) return;
    setState(() => loading = true);
    try {
      final value = await link.powerPreferences();
      if (!mounted ||
          order != _order ||
          link != widget.host.link ||
          epoch != widget.host.connectionEpoch) {
        return;
      }
      setState(() {
        policy = value;
        error = null;
      });
    } catch (e) {
      if (mounted && order == _order) setState(() => error = '$e');
    } finally {
      if (mounted && order == _order) setState(() => loading = false);
    }
  }

  Future<void> _set(bool enabled) async {
    final link = widget.host.link,
        epoch = widget.host.connectionEpoch,
        generation = _generation;
    if (link == null || policy == null || busy || !widget.host.online) return;
    // A read started before this write must not overwrite its confirmed value.
    _order++;
    setState(() {
      busy = true;
      note = null;
      error = null;
    });
    try {
      final result = await widget.host.operations.setKeepAwake(link, enabled);
      if (!mounted ||
          generation != _generation ||
          link != widget.host.link ||
          epoch != widget.host.connectionEpoch) {
        return;
      }
      setState(() {
        policy = result;
        error = null;
      });
    } catch (e) {
      if (mounted && generation == _generation) setState(() => error = '$e');
    } finally {
      if (mounted && generation == _generation) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final online = widget.host.online;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(tr("任务或远控期间保持唤醒")),
          subtitle: Text(
            !online ? tr("电脑离线，重连后刷新设置") : tr("阻止空闲睡眠，仍可锁屏或手动睡眠"),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          value: policy?['enabled'] == true,
          onChanged: online && !busy && !loading && policy != null
              ? _set
              : null,
        ),
        if (note != null) InlineNotice(note!),
        if (policy?['error'] is String)
          InlineNotice(tr("电脑暂未能保持唤醒：{0}", [policy!['error']])),
        if (error != null)
          Row(
            children: [
              Expanded(child: InlineNotice(error!, danger: true)),
              IconButton(
                tooltip: tr("刷新保持唤醒设置"),
                onPressed: online && !loading && !busy ? _load : null,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
      ],
    );
  }
}
