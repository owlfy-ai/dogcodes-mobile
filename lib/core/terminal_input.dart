import 'package:dogcodes_app/l10n/strings.dart';
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'host_api.dart';
import 'pc_api.dart' show uuid;
import 'protocol.dart';

/// Serial input for one physical terminal attachment. Unknown writes are only
/// inspected, never replayed. No keystrokes are saved to disk.
class TerminalInput extends ChangeNotifier {
  TerminalInput(this.api, this.terminalId);
  final HostApi api;
  final String terminalId;
  final _queue = Queue<_Input>();
  Map<String, dynamic>? _lease, _unknown;
  bool _closed = false, _working = false, paused = false, canResume = true;
  String? message;
  int _bytes = 0;
  String _sequence = '0';
  bool get hasUnknown => _unknown != null;
  bool get attached => _lease?['state'] == 'ready' && !paused && !_closed;
  bool get busy => _working;
  Future<bool> send(List<int> bytes) {
    if (_closed || paused) return Future.value(false);
    if (bytes.isEmpty) return Future.value(true);
    if (bytes.length > 16384 || _bytes + bytes.length > 65536) {
      message = tr("待发送的输入过多，本次未发送，请缩短输入后再试。");
      notifyListeners();
      return Future.value(false);
    }
    final item = _Input(List.of(bytes));
    _queue.add(item);
    _bytes += bytes.length;
    if (!_working) unawaited(_run());
    return item.done.future;
  }

  Future<dynamic> _raw(String method, dynamic args) async {
    if (_closed) throw ProtocolException(tr("终端页面已离开，未继续发送输入。"));
    final value = await api.call(method, args);
    if (_closed) throw ProtocolException(tr("终端页面已离开，未继续发送输入。"));
    return value;
  }

  Future<Map<String, dynamic>> _call(Map<String, dynamic> args) async {
    final value = await _raw('terminal_input', args);
    if (value is! Map ||
        value['terminalId'] != terminalId ||
        value['epoch'] is! String ||
        value['revision'] is! String ||
        value['sequence'] is! String) {
      throw ProtocolException(tr("终端输入回执不匹配"));
    }
    parseSequence(value['revision'] as String);
    parseSequence(value['sequence'] as String);
    return Map<String, dynamic>.from(value);
  }

  Future<void> _open({required bool acknowledge}) async {
    final caps = await _raw('remote_capabilities', null);
    if (caps is! Map || caps['terminalInputStreams'] != true) {
      canResume = false;
      throw ProtocolException(tr("请更新电脑端后输入；终端输出仍可查看。"));
    }
    final info = await _raw('terminal_get', terminalId);
    if (info is! Map ||
        info['id'] != terminalId ||
        info['epoch'] is! String ||
        info['status'] != 'running') {
      canResume =
          info is Map &&
          info['id'] == terminalId &&
          info['epoch'] is String &&
          info['status'] == 'starting';
      throw ProtocolException(
        canResume ? tr("终端正在启动，请稍后继续输入。") : tr("原终端当前不可输入，请刷新查看状态。"),
      );
    }
    final original = await _call({
      'type': 'inspect',
      'terminalId': terminalId,
      'expectedEpoch': info['epoch'],
    });
    final stream = uuid();
    final opened = await _call({
      'type': 'open',
      'terminalId': terminalId,
      'expectedEpoch': info['epoch'],
      'streamId': stream,
      'expectedRevision': original['revision'],
      'acknowledgeUncertain': acknowledge,
    });
    if (opened['streamId'] != stream ||
        opened['epoch'] != info['epoch'] ||
        opened['owned'] != true ||
        parseSequence(opened['revision'] as String) !=
            parseSequence(original['revision'] as String) + BigInt.one) {
      throw ProtocolException(tr("终端输入连接已改变，请检查后继续。"));
    }
    _lease = opened;
    _sequence = opened['sequence'] as String;
    if (opened['state'] != 'ready' || opened['uncertain'] == true) {
      throw ProtocolException(
        opened['state'] == 'opening'
            ? tr("输入连接仍在切换，请稍后检查并继续。")
            : tr("上次输入结果待核实，请检查终端输出后再继续。"),
      );
    }
  }

  bool _applied(Map reply, Map expected) =>
      reply['epoch'] == expected['epoch'] &&
      reply['streamId'] == expected['streamId'] &&
      reply['revision'] == expected['revision'] &&
      reply['sequence'] == expected['sequence'] &&
      reply['digest'] == expected['digest'] &&
      reply['owned'] == true &&
      reply['state'] == 'applied' &&
      reply['uncertain'] == false;
  Future<Map<String, dynamic>> _inspect(Map expected) => _call({
    'type': 'inspect',
    'terminalId': terminalId,
    'expectedEpoch': expected['epoch'],
  });
  Future<void> _run() async {
    _working = true;
    while (_queue.isNotEmpty && !_closed && !paused) {
      final item = _queue.removeFirst();
      try {
        if (_lease == null) await _open(acknowledge: false);
        if (_closed) {
          item.done.complete(false);
          break;
        }
        final lease = _lease!,
            next = (parseSequence(_sequence) + BigInt.one).toString(),
            digest = sha256.convert(item.bytes).toString();
        final expected = {
          'epoch': lease['epoch'],
          'streamId': lease['streamId'],
          'revision': lease['revision'],
          'sequence': next,
          'digest': digest,
        };
        _unknown = expected;
        Map<String, dynamic> result;
        try {
          result = await _call({
            'type': 'write',
            'terminalId': terminalId,
            'expectedEpoch': lease['epoch'],
            'streamId': lease['streamId'],
            'revision': lease['revision'],
            'sequence': next,
            'data': base64Encode(item.bytes),
          });
        } catch (_) {
          result = await _inspect(expected);
        }
        if (!_applied(result, expected)) {
          throw ProtocolException(tr("输入结果尚未确认，请核实或检查终端后继续；不会重发原输入。"));
        }
        _sequence = next;
        _unknown = null;
        message = null;
        item.done.complete(true);
      } catch (e) {
        paused = true;
        message = e is ProtocolException
            ? e.message
            : tr("终端连接中断，输入结果待核实；未发送的队列已丢弃，不会自动重发。");
        item.done.complete(false);
      } finally {
        _bytes -= item.bytes.length;
      }
    }
    if (_closed || paused) _discard();
    _working = false;
    if (!_closed) notifyListeners();
  }

  void _discard() {
    while (_queue.isNotEmpty) {
      final item = _queue.removeFirst();
      _bytes -= item.bytes.length;
      item.done.complete(false);
    }
  }

  Future<bool> verify() async {
    final expected = _unknown;
    if (_closed || expected == null || _working) return false;
    try {
      final reply = await _inspect(expected);
      if (_closed) return false;
      if (_applied(reply, expected)) {
        _sequence = expected['sequence'] as String;
        _unknown = null;
        paused = false;
        message = null;
        notifyListeners();
        return true;
      }
      message = tr("原输入仍未确认或通道已改变，请检查终端输出后继续；不会重发。");
    } catch (_) {
      message = tr("暂时无法核实输入，请连接后再试；不会重发原输入。");
    }
    if (!_closed) notifyListeners();
    return false;
  }

  Future<bool> resume() async {
    if (_closed || _working || !canResume) return false;
    _lease = null;
    try {
      await _open(acknowledge: true);
      if (_closed) return false;
      paused = false;
      _unknown = null;
      message = null;
      notifyListeners();
      return true;
    } catch (e) {
      message = e is ProtocolException ? e.message : tr("输入连接尚未恢复，请稍后再试。");
      if (!_closed) notifyListeners();
      return false;
    }
  }

  @override
  void dispose() {
    _closed = true;
    _discard();
    super.dispose();
  }
}

class _Input {
  _Input(this.bytes);
  final List<int> bytes;
  final done = Completer<bool>();
}
