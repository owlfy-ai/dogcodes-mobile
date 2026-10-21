import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/host_hub.dart';
import '../../core/pc_api.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../tools/tool_context.dart';

/// 10 远程桌面: device-level screen and input for one PC, independent of any
/// Agent. Frames are pulled (≤5 fps); every input carries the next sequence so
/// a retried request can never replay a click.
class RemoteDesktopPage extends StatefulWidget {
  const RemoteDesktopPage({super.key, required this.host});
  final HostState host;
  @override
  State<RemoteDesktopPage> createState() => _RemoteDesktopPageState();
}

class _RemoteDesktopPageState extends State<RemoteDesktopPage> {
  List<Map<String, dynamic>> displays = [];
  int? monitor;
  String? lease, error;
  bool locked = false, busy = false;
  Uint8List? frame;
  Size? frameSize;
  int sequence = 0;
  Timer? _timer;
  bool _fetching = false;
  final keyboard = TextEditingController();
  final keyFocus = FocusNode();
  Offset? _dragStart;

  HostState get h => widget.host;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _timer?.cancel();
    final l = lease;
    if (l != null) h.link?.desktopClose(l).catchError((Object _) => null);
    keyboard.dispose();
    keyFocus.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final link = h.link;
    if (link == null) return;
    setState(() => busy = true);
    try {
      final status = await link.deviceStatus();
      locked = status['locked'] == true;
      if (locked) {
        setState(() => busy = false);
        return;
      }
      displays = await link.displays();
      monitor ??=
          (displays.firstWhere(
                    (d) => d['primary'] == true,
                    orElse: () => displays.first,
                  )['id']
                  as num)
              .toInt();
      final opened = await link.desktopOpen(monitor!);
      lease = opened['leaseId'] as String;
      sequence = int.tryParse('${opened['inputSequence']}') ?? 0;
      error = null;
      _timer = Timer.periodic(
        const Duration(milliseconds: 250),
        (_) => _frame(),
      );
    } catch (e) {
      error = '$e';
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> _frame() async {
    final link = h.link, l = lease;
    if (link == null || l == null || _fetching) return;
    _fetching = true;
    try {
      final f = await link.desktopFrame(l, maxWidth: 1600, quality: 60);
      if (!mounted) return;
      setState(() {
        frame = base64.decode(f['bytes'] as String);
        frameSize = Size(
          (f['width'] as num).toDouble(),
          (f['height'] as num).toDouble(),
        );
      });
    } catch (e) {
      final message = '$e';
      if (!message.contains('过于频繁') && mounted) {
        _timer?.cancel();
        setState(() {
          lease = null;
          error = message.contains('锁定') ? null : message;
          locked = message.contains('锁定');
        });
      }
    } finally {
      _fetching = false;
    }
  }

  Future<void> _input(Map<String, dynamic> event) async {
    final link = h.link, l = lease;
    if (link == null || l == null) return;
    sequence++;
    try {
      await link.desktopInput(l, sequence, event);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  /// Screen point → PC coordinates normalised to 0..65535.
  Map<String, dynamic>? _point(Offset local, Size box) {
    final f = frameSize;
    if (f == null) return null;
    final scale = (box.width / f.width).clamp(0, box.height / f.height);
    final w = f.width * scale, hgt = f.height * scale;
    final dx = (box.width - w) / 2, dy = (box.height - hgt) / 2;
    final x = ((local.dx - dx) / w).clamp(0.0, 1.0),
        y = ((local.dy - dy) / hgt).clamp(0.0, 1.0);
    return {'kind': 'move', 'x': (x * 65535).round(), 'y': (y * 65535).round()};
  }

  Future<void> _click(Offset p, Size box, {String button = 'left'}) async {
    final move = _point(p, box);
    if (move == null) return;
    await _input(move);
    await _input({'kind': 'button', 'button': button, 'direction': 'press'});
    await _input({'kind': 'button', 'button': button, 'direction': 'release'});
  }

  Future<void> _key(String key) async {
    await _input({'kind': 'key', 'key': key, 'direction': 'press'});
    await _input({'kind': 'key', 'key': key, 'direction': 'release'});
  }

  Future<void> _select(int id) async {
    final l = lease;
    if (l == null) return;
    try {
      await h.link?.desktopSelect(l, id);
      setState(() => monitor = id);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _clipboard() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (s) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.upload_outlined),
              title: const Text('发送到电脑'),
              subtitle: const Text('手机剪贴板中的文字'),
              onTap: () => Navigator.pop(s, 'send'),
            ),
            ListTile(
              leading: const Icon(Icons.download_outlined),
              title: const Text('从电脑获取'),
              subtitle: const Text('电脑剪贴板中的文字'),
              onTap: () => Navigator.pop(s, 'get'),
            ),
          ],
        ),
      ),
    );
    final link = h.link;
    if (action == null || link == null || !mounted) return;
    try {
      if (action == 'send') {
        final data = await Clipboard.getData(Clipboard.kTextPlain);
        if ((data?.text ?? '').isEmpty) throw '手机剪贴板没有文字';
        await link.clipboardSet({'kind': 'text', 'text': data!.text});
        if (mounted) showError(context, '已发送到电脑剪贴板');
      } else {
        final v = await link.clipboardGet('text');
        await Clipboard.setData(ClipboardData(text: '${v['text'] ?? ''}'));
        if (mounted) showError(context, '已复制电脑剪贴板到手机');
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    return Scaffold(
      backgroundColor: c.canvas,
      appBar: DetailBar(
        title: '远程桌面',
        subtitle:
            '${h.name} · ${lease != null
                ? '连接正常'
                : locked
                ? '电脑已锁定'
                : '未连接'}',
        actions: [
          if (displays.length > 1)
            PopupMenuButton<int>(
              tooltip: '切换屏幕',
              icon: const Icon(Icons.monitor_outlined),
              onSelected: _select,
              itemBuilder: (_) => [
                for (final (i, d) in displays.indexed)
                  PopupMenuItem(
                    value: (d['id'] as num).toInt(),
                    child: Text(
                      '屏幕 ${i + 1}${d['primary'] == true ? '（主）' : ''}',
                    ),
                  ),
              ],
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(child: _screen(c)),
            Offstage(
              offstage: true,
              child: TextField(
                controller: keyboard,
                focusNode: keyFocus,
                autocorrect: false,
                enableSuggestions: false,
                onChanged: (v) {
                  if (v.isEmpty) return;
                  _input({'kind': 'text', 'text': v});
                  keyboard.clear();
                },
                onSubmitted: (_) {
                  _key('enter');
                  keyFocus.requestFocus();
                },
              ),
            ),
            if (lease != null)
              SizedBox(
                height: 48,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  children: [
                    for (final (label, key) in const [
                      ('Esc', 'escape'),
                      ('Tab', 'tab'),
                      ('⌫', 'backspace'),
                      ('↵', 'enter'),
                      ('←', 'left'),
                      ('↑', 'up'),
                      ('↓', 'down'),
                      ('→', 'right'),
                    ])
                      Padding(
                        padding: const EdgeInsets.only(
                          right: 6,
                          top: 6,
                          bottom: 6,
                        ),
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(44, 36),
                          ),
                          onPressed: () => _key(key),
                          child: Text(label),
                        ),
                      ),
                  ],
                ),
              ),
            Container(
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: c.line)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _Tool(
                    icon: Icons.keyboard_outlined,
                    label: '键盘',
                    onTap: lease == null
                        ? null
                        : () => keyFocus.hasFocus
                              ? keyFocus.unfocus()
                              : keyFocus.requestFocus(),
                  ),
                  _Tool(
                    icon: Icons.content_paste,
                    label: '剪贴板',
                    onTap: lease == null ? null : _clipboard,
                  ),
                  _Tool(
                    icon: Icons.refresh,
                    label: '重新连接',
                    onTap: busy
                        ? null
                        : () {
                            _timer?.cancel();
                            final l = lease;
                            lease = null;
                            if (l != null) {
                              h.link
                                  ?.desktopClose(l)
                                  .catchError((Object _) => null);
                            }
                            _start();
                          },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _screen(DcColors c) {
    if (!h.online) {
      return const Center(child: Text('电脑离线'));
    }
    if (locked) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            '电脑已锁定，Agent 操作仍可用。\n解锁电脑后点「重新连接」。',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (error != null) {
      return Center(child: InlineNotice(error!, danger: true));
    }
    if (frame == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return LayoutBuilder(
      builder: (context, box) {
        final size = Size(box.maxWidth, box.maxHeight);
        return GestureDetector(
          onTapUp: (d) => _click(d.localPosition, size),
          onLongPressStart: (d) =>
              _click(d.localPosition, size, button: 'right'),
          onScaleStart: (d) => _dragStart = d.localFocalPoint,
          onScaleUpdate: (d) async {
            final start = _dragStart;
            if (start == null) return;
            if (d.pointerCount >= 2) {
              final dy = (d.localFocalPoint.dy - start.dy) / 12;
              if (dy.abs() >= 1) {
                _dragStart = d.localFocalPoint;
                await _input({
                  'kind': 'scroll',
                  'x': 0,
                  'y': (-dy).round().clamp(-20, 20),
                });
              }
            }
          },
          child: Container(
            color: Colors.black,
            alignment: Alignment.center,
            child: Image.memory(
              frame!,
              gaplessPlayback: true,
              fit: BoxFit.contain,
            ),
          ),
        );
      },
    );
  }
}

class _Tool extends StatelessWidget {
  const _Tool({required this.icon, required this.label, this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: onTap == null ? context.dc.secondary : null),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(fontSize: 11)),
        ],
      ),
    ),
  );
}
