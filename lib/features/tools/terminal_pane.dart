import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';
import '../../core/host_api.dart';
import '../../core/pc_api.dart';
import '../../ui/theme.dart';

/// Attaches to one PC terminal: reads its output by offset (the PC keeps the
/// buffer, so reopening resumes), forwards keystrokes as bytes, and shares
/// one PTY size with every other attached client.
class TerminalSession {
  TerminalSession(this.link, this.id) {
    terminal.onOutput = (data) => send(data);
    terminal.onResize = (w, h, _, _) {
      _resize?.cancel();
      _resize = Timer(const Duration(milliseconds: 300), () {
        link.terminalResize(id, w, h).catchError((Object _) => null);
      });
    };
  }
  final HostLink link;
  final String id;
  final terminal = Terminal(maxLines: 5000);
  final info = ValueNotifier<Map<String, dynamic>?>(null);
  final error = ValueNotifier<String?>(null);
  String _after = '0';
  bool _closed = false, _reading = false;
  Timer? _poll, _resize;
  final _decoder = const Utf8Decoder(allowMalformed: true);
  final _pending = <int>[];

  bool ctrl = false;

  void start() {
    _poll = Timer.periodic(const Duration(milliseconds: 250), (_) => _read());
    _read();
  }

  Future<void> _read() async {
    if (_closed || _reading) return;
    _reading = true;
    try {
      final batch = await link.terminalRead(id, _after);
      if (_closed) return;
      final bytes = [
        for (final b in (batch['bytes'] as List? ?? const []))
          (b as num).toInt(),
      ];
      if (batch['gap'] == true) {
        terminal.write(
          _after == '0'
              ? '\x1b[2m（较早的输出已被电脑释放）\x1b[0m\r\n'
              : '\r\n\x1b[2m… 部分较早的输出已被电脑丢弃 …\x1b[0m\r\n',
        );
      }
      if (bytes.isNotEmpty) {
        // Keep an incomplete UTF-8 sequence for the next batch.
        _pending.addAll(bytes);
        var end = _pending.length;
        var back = 0;
        while (back < 3 &&
            end - back - 1 >= 0 &&
            (_pending[end - back - 1] & 0xC0) == 0x80) {
          back++;
        }
        if (end - back - 1 >= 0) {
          final lead = _pending[end - back - 1];
          final need = lead >= 0xF0
              ? 3
              : lead >= 0xE0
              ? 2
              : lead >= 0xC0
              ? 1
              : 0;
          if (need > back) end = end - back - 1;
        }
        terminal.write(_decoder.convert(_pending.sublist(0, end)));
        _pending.removeRange(0, end);
      }
      _after = '${batch['next'] ?? _after}';
      info.value = Map<String, dynamic>.from(batch['info'] as Map? ?? {});
      error.value = null;
    } catch (e) {
      error.value = '$e';
    } finally {
      _reading = false;
    }
  }

  Future<void> send(String data) async {
    if (data.isEmpty) return;
    var text = data;
    if (ctrl && text.length == 1) {
      final code = text.toUpperCase().codeUnitAt(0);
      if (code >= 64 && code < 96) text = String.fromCharCode(code - 64);
      ctrl = false;
    }
    try {
      await link.terminalWrite(id, utf8.encode(text));
    } catch (e) {
      error.value = '$e';
    }
  }

  void dispose() {
    _closed = true;
    _poll?.cancel();
    _resize?.cancel();
    info.dispose();
    error.dispose();
  }
}

bool terminalActive(Map? info) =>
    ['starting', 'running', 'stopping'].contains(info?['status']);

String terminalStatus(Map? info) => switch (info?['status']) {
  'starting' => '启动中',
  'running' => '运行中',
  'stopping' => '停止中',
  'exited' => info?['exitCode'] == null ? '已结束' : '已退出（${info?['exitCode']}）',
  'failed' => '启动失败',
  _ => '状态未知',
};

class TerminalPane extends StatefulWidget {
  const TerminalPane({super.key, required this.session, this.keys = true});
  final TerminalSession session;
  final bool keys;
  @override
  State<TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<TerminalPane> {
  final focus = FocusNode();
  final line = TextEditingController();
  final _lineFocus = FocusNode();

  @override
  void dispose() {
    focus.dispose();
    line.dispose();
    _lineFocus.dispose();
    super.dispose();
  }

  /// Sends the typed line once, followed by Enter, and keeps the keyboard up.
  void _submit() {
    final text = line.text;
    line.clear();
    widget.session.send('$text\r');
    // Keep typing without re-opening the keyboard.
    FocusScope.of(context).requestFocus(_lineFocus);
  }

  TerminalTheme _theme(DcColors c, bool dark) => TerminalTheme(
    cursor: c.accent,
    selection: c.accent.withValues(alpha: 0.3),
    foreground: dark ? const Color(0xFFE6E6E6) : const Color(0xFFE6E6E6),
    background: dark ? const Color(0xFF0A0A0A) : const Color(0xFF141414),
    black: const Color(0xFF1E1E1E),
    red: const Color(0xFFE57B72),
    green: const Color(0xFF8FD16A),
    yellow: const Color(0xFFF0B45A),
    blue: const Color(0xFF6CA8F0),
    magenta: const Color(0xFFC792EA),
    cyan: const Color(0xFF6CD3D3),
    white: const Color(0xFFD0D0D0),
    brightBlack: const Color(0xFF707070),
    brightRed: const Color(0xFFFF8A80),
    brightGreen: const Color(0xFFB7F34C),
    brightYellow: const Color(0xFFFFD27A),
    brightBlue: const Color(0xFF8FC0FF),
    brightMagenta: const Color(0xFFDDB2FF),
    brightCyan: const Color(0xFF8FEFEF),
    brightWhite: const Color(0xFFFFFFFF),
    searchHitBackground: c.warning,
    searchHitBackgroundCurrent: c.accent,
    searchHitForeground: Colors.black,
  );

  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    final s = widget.session;
    return Column(
      children: [
        Expanded(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(DcSpace.control),
            ),
            clipBehavior: Clip.antiAlias,
            child: TerminalView(
              s.terminal,
              focusNode: focus,
              autofocus: false,
              // Mobile keyboards resend composing text (IME/predictions), which
              // would duplicate keystrokes; input goes through the line below.
              readOnly: true,
              theme: _theme(c, Theme.of(context).brightness == Brightness.dark),
              textStyle: const TerminalStyle(
                fontSize: 12.5,
                fontFamily: monoFamily,
              ),
              padding: const EdgeInsets.all(8),
            ),
          ),
        ),
        ValueListenableBuilder<String?>(
          valueListenable: s.error,
          builder: (_, e, _) => e == null
              ? const SizedBox.shrink()
              : Padding(
                  padding: const EdgeInsets.all(6),
                  child: Text(
                    e,
                    style: TextStyle(color: c.removed, fontSize: 12),
                  ),
                ),
        ),
        if (widget.keys)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
            child: TextField(
              controller: line,
              focusNode: _lineFocus,
              autocorrect: false,
              enableSuggestions: false,
              smartDashesType: SmartDashesType.disabled,
              smartQuotesType: SmartQuotesType.disabled,
              textInputAction: TextInputAction.send,
              style: const TextStyle(fontFamily: monoFamily, fontSize: 14),
              decoration: InputDecoration(
                hintText: '输入命令，回车发送',
                prefixText: '\$ ',
                isDense: true,
                suffixIcon: IconButton(
                  tooltip: '发送',
                  icon: const Icon(Icons.keyboard_return),
                  onPressed: _submit,
                ),
              ),
              onSubmitted: (_) => _submit(),
            ),
          ),
        if (widget.keys)
          SafeArea(
            top: false,
            child: SizedBox(
              height: 52,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                children: [
                  _Key('Esc', () => s.send('\x1b')),
                  _Key('Tab', () => s.send('\t')),
                  StatefulBuilder(
                    builder: (context, set) => _Key(
                      'Ctrl',
                      () => set(() => s.ctrl = !s.ctrl),
                      active: s.ctrl,
                    ),
                  ),
                  _Key('^C', () => s.send('\x03')),
                  _Key('←', () => s.send('\x1b[D')),
                  _Key('↑', () => s.send('\x1b[A')),
                  _Key('↓', () => s.send('\x1b[B')),
                  _Key('→', () => s.send('\x1b[C')),
                  _Key('↵', () => s.send('\r')),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _Key extends StatelessWidget {
  const _Key(this.label, this.onTap, {this.active = false});
  final String label;
  final VoidCallback onTap;
  final bool active;
  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Material(
        color: active ? c.accent : c.surface,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minWidth: 44),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: active ? c.onAccent : c.text,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
