import 'package:flutter/material.dart';
import '../../core/host_hub.dart';
import '../../ui/widgets.dart';

class OfflineCacheSettings extends StatefulWidget {
  const OfflineCacheSettings({super.key, required this.hub});
  final HostHub hub;
  @override
  State<OfflineCacheSettings> createState() => _OfflineCacheSettingsState();
}

class _OfflineCacheSettingsState extends State<OfflineCacheSettings> {
  late var usage = widget.hub.local.cacheUsage();
  bool busy = false;
  String? error;
  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('清除离线缓存？'),
        content: const Text(
          '只清除此手机保存的会话缓存，保留草稿、未发送附件和电脑配对。电脑上的会话不受影响，联网后会重新缓存。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(d, true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.hub.clearOfflineCache();
    } catch (e) {
      error = '未能清除缓存：$e';
    }
    if (mounted) {
      setState(() {
        busy = false;
        usage = widget.hub.local.cacheUsage();
      });
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      FutureBuilder(
        future: usage,
        builder: (context, snap) => ListTile(
          leading: const Icon(Icons.offline_pin_outlined),
          title: const Text('最近会话离线缓存'),
          subtitle: Text(
            snap.hasData
                ? '${snap.data!.sessions} 个会话 · ${(snap.data!.bytes / 1024 / 1024).toStringAsFixed(1)} MB\n最多 30 个会话、32 MB；保存文字和附件信息。'
                : '正在读取缓存大小…',
          ),
          trailing: TextButton(
            onPressed: busy ? null : _clear,
            child: Text(busy ? '正在清除…' : '清除缓存'),
          ),
        ),
      ),
      if (error != null) InlineNotice(error!, danger: true),
      if (widget.hub.local.cacheError != null)
        InlineNotice(widget.hub.local.cacheError!, danger: true),
    ],
  );
}
