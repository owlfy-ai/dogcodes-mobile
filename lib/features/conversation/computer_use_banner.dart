import 'dart:async';

import 'package:dogcodes_app/l10n/strings.dart';
import 'package:flutter/material.dart';

import '../../core/host_hub.dart';
import '../../core/protocol.dart';
import '../../ui/theme.dart';

/// Shown while an Agent in this conversation is using the computer's screen,
/// keyboard or mouse (电脑操作), with a way to stop it from the phone.
/// The computer reports only the current step; nothing is streamed.
class ComputerUseBanner extends StatefulWidget {
  const ComputerUseBanner({
    super.key,
    required this.host,
    required this.taskId,
    required this.running,
    this.interval = const Duration(seconds: 2),
  });
  final HostState host;
  final String taskId;

  /// Only a running turn can use the computer, so nothing is asked otherwise.
  final bool running;
  final Duration interval;
  @override
  State<ComputerUseBanner> createState() => _ComputerUseBannerState();
}

class _ComputerUseBannerState extends State<ComputerUseBanner> {
  Timer? _timer;
  Map<String, dynamic>? activity;
  bool stopping = false;

  /// Per link: computers from before this feature answer "unavailable".
  static final _unsupported = Expando<bool>();

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(ComputerUseBanner old) {
    super.didUpdateWidget(old);
    if (old.running != widget.running || old.taskId != widget.taskId) _sync();
  }

  void _sync() {
    final watch =
        widget.running &&
        widget.host.link != null &&
        _unsupported[widget.host.link!] != true;
    if (!watch) {
      _timer?.cancel();
      _timer = null;
      if (activity != null) setState(() => activity = null);
      return;
    }
    if (_timer != null) return;
    unawaited(_read());
    _timer = Timer.periodic(widget.interval, (_) => _read());
  }

  Future<void> _read() async {
    final link = widget.host.link;
    if (link == null) return;
    try {
      final value = await link.call('computer_use_status', null);
      if (!mounted) return;
      final next = value is Map ? Map<String, dynamic>.from(value) : null;
      final mine =
          next != null &&
          next['taskId'] == widget.taskId &&
          next['operationId'] != null &&
          next['mode'] != 'idle';
      final shown = mine ? next : null;
      if (shown?['operationId'] == activity?['operationId'] &&
          shown?['tool'] == activity?['tool'] &&
          shown?['mode'] == activity?['mode']) {
        return;
      }
      setState(() => activity = shown);
    } on ProtocolException catch (e) {
      if (e.rawMessage.contains('remote method unavailable')) {
        _unsupported[link] = true;
        _timer?.cancel();
        _timer = null;
      }
    } catch (_) {
      // A dropped request is retried on the next tick.
    }
  }

  Future<void> _stop() async {
    final link = widget.host.link, current = activity;
    if (link == null || current == null) return;
    setState(() => stopping = true);
    try {
      final result = await link.call(
        'computer_use_stop',
        '${current['operationId']}',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result is Map && result['accepted'] == true
                ? tr("已停止电脑操作")
                : tr("这一步已经结束，没有需要停止的电脑操作。"),
          ),
        ),
      );
      setState(() => activity = null);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => stopping = false);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final a = activity;
    if (a == null) return const SizedBox.shrink();
    final c = context.dc;
    final detail = [
      computerUseMode(a['mode'] as String?),
      ?computerUseTool(a['tool'] as String?),
    ].join(' · ');
    return Container(
      margin: const EdgeInsets.fromLTRB(DcSpace.page, 0, DcSpace.page, 8),
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.warning),
        borderRadius: BorderRadius.circular(DcSpace.control),
      ),
      child: Row(
        children: [
          Icon(Icons.mouse_outlined, size: 20, color: c.warning),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  tr("电脑操作"),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Text(
                  detail,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: c.secondary),
                ),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: stopping ? null : _stop,
            icon: stopping
                ? const SizedBox.square(
                    dimension: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.stop_circle_outlined, size: 18),
            label: Text(tr("停止电脑操作")),
          ),
        ],
      ),
    );
  }
}

String computerUseMode(String? mode) => switch (mode) {
  'observing' => tr("观察"),
  'background' => tr("后台"),
  'foreground' => tr("前台"),
  _ => tr("模式未知"),
};

/// The step's name as the desktop shows it; tools arrive possibly namespaced
/// (`mcp__computer__click`).
String? computerUseTool(String? tool) {
  if (tool == null || tool.isEmpty) return null;
  final name = tool.split('__').last;
  return switch (name) {
    'list_apps' => tr("查看应用"),
    'list_windows' => tr("查看窗口"),
    'launch_app' => tr("打开应用"),
    'get_window_state' => tr("读取窗口"),
    'get_desktop_state' => tr("查看桌面"),
    'zoom' => tr("放大截图"),
    'click' => tr("点击"),
    'double_click' => tr("双击"),
    'right_click' => tr("右键点击"),
    'type_text' => tr("输入文字"),
    'set_value' => tr("填写字段"),
    'press_key' => tr("按键"),
    'hotkey' => tr("快捷键"),
    'scroll' => tr("滚动"),
    'drag' => tr("拖动"),
    'move_cursor' => tr("移动指针"),
    'invoke_menu' => tr("操作菜单"),
    'set_window_frame' => tr("调整窗口"),
    'verify_state' => tr("验证结果"),
    'run_steps' => tr("执行步骤"),
    _ => null,
  };
}
