import 'package:dogcodes_app/l10n/strings.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../core/host_hub.dart';
import '../../core/mobile_runtime.dart';
import '../../core/protocol.dart';
import '../../core/security/pairing_recovery.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

class PairingPage extends StatefulWidget {
  const PairingPage({
    super.key,
    required this.trustedService,
    this.runtime,
    this.hub,
    this.startScanning = false,
  });
  final Uri trustedService;
  final MobileRuntime? runtime;
  final HostHub? hub;
  final bool startScanning;
  @override
  State<PairingPage> createState() => _PairingPageState();
}

class _PairingPageState extends State<PairingPage> {
  final _text = TextEditingController();
  late bool _scanning = widget.startScanning;
  bool _handled = false;
  bool _working = false;
  String? _message;
  List<PairingRecovery> _pending = [];

  @override
  void initState() {
    super.initState();
    _loadPending();
  }

  Future<void> _loadPending() async {
    try {
      final pending =
          await widget.runtime?.pairingJournal.list() ?? <PairingRecovery>[];
      if (mounted) setState(() => _pending = pending);
    } catch (e) {
      if (mounted) setState(() => _message = '$e');
    }
  }

  Future<void> _recover(PairingRecovery original) async {
    final runtime = widget.runtime;
    if (_working || runtime == null) return;
    setState(() {
      _working = true;
      _scanning = false;
      _message = tr("正在核实原配对…");
    });
    try {
      final client = await runtime.recoverPairing(original);
      if (!mounted || widget.hub == null) {
        await client.close();
        return;
      }
      await widget.hub!.adopt(client);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() => _message = _connectionFailure(e, original.service));
      }
    } finally {
      await _loadPending();
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _forget(PairingRecovery original) async {
    if (_working) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(tr("移除本机配对记录？")),
        content: Text(tr("之后需要重新扫码。电脑上可能已允许这台手机；如需撤销授权，请在电脑的「连接手机」中操作。")),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: Text(tr("保留记录")),
          ),
          TextButton(
            onPressed: () => Navigator.pop(d, true),
            child: Text(tr("移除本机记录")),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    setState(() => _working = true);
    try {
      await widget.runtime?.pairingJournal.clear(original);
    } catch (e) {
      if (mounted) setState(() => _message = '$e');
    } finally {
      await _loadPending();
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _accept(String value) async {
    if (_handled) return;
    _handled = true;
    try {
      final invitation = PairingInvitation.parse(
        value,
        trustedService: widget.trustedService,
        now: DateTime.now().toUtc(),
        allowLocalDevelopment: !kReleaseMode,
      );
      setState(() {
        _scanning = false;
        _working = true;
        _message = tr("正在验证电脑身份并建立配对…");
      });
      final runtime = widget.runtime;
      if (runtime == null) throw ProtocolException(tr("加密组件尚未准备好。"));
      final client = await runtime.pair(invitation);
      if (widget.hub == null || !mounted) {
        await client.close();
        return;
      }
      await widget.hub!.adopt(client);
      if (mounted) Navigator.of(context).pop();
      return;
    } on ProtocolException catch (error) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _message = error.message;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _scanning = false;
          _message = _connectionFailure(error, widget.trustedService);
        });
      }
    }
    if (mounted) {
      setState(() => _working = false);
      _text.clear();
    }
    await _loadPending();
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final c = context.dc;
    return Scaffold(
      appBar: DetailBar(title: tr("连接电脑")),
      body: ListView(
        padding: const EdgeInsets.all(DcSpace.page),
        children: [
          Text(
            tr("在电脑端打开「连接手机」，扫描配对二维码。"),
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 6),
          Text(
            tr("配对后可操作这台电脑的 Agent、项目、Git 和终端，并查看、控制电脑屏幕。你可以随时在电脑上撤销授权。"),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 20),
          for (final original in _pending) ...[
            Panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr("配对结果待核实"),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    tr("电脑 {0}", [
                      original.hostId.length > 8
                          ? original.hostId.substring(0, 8)
                          : original.hostId,
                    ]),
                  ),
                  Text(tr("保留了原配对信息，可以继续核实电脑是否已允许连接。")),
                  if (!original.recoverUntil.isAfter(DateTime.now().toUtc()))
                    InlineNotice(tr("恢复期限已过，请在电脑核实授权后重新扫码。")),
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton(
                        onPressed:
                            _working ||
                                !original.recoverUntil.isAfter(
                                  DateTime.now().toUtc(),
                                )
                            ? null
                            : () => _recover(original),
                        child: Text(tr("核实原配对")),
                      ),
                      TextButton(
                        onPressed: _working ? null : () => _forget(original),
                        child: Text(tr("移除本机记录")),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],
          if (_scanning)
            ClipRRect(
              borderRadius: BorderRadius.circular(DcSpace.control),
              child: SizedBox(
                height: 280,
                child: MobileScanner(
                  onDetect: (capture) {
                    for (final barcode in capture.barcodes) {
                      if (barcode.rawValue != null) {
                        _accept(barcode.rawValue!);
                        break;
                      }
                    }
                  },
                  errorBuilder: (context, error) => Container(
                    color: c.surface,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      tr("无法使用相机，请检查相机权限，或在下方粘贴配对链接。"),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ),
            )
          else
            FilledButton.icon(
              onPressed: _working
                  ? null
                  : () => setState(() {
                      _handled = false;
                      _scanning = true;
                      _message = null;
                    }),
              icon: const Icon(Icons.qr_code_scanner),
              label: Text(tr("扫描二维码")),
            ),
          const SizedBox(height: 28),
          Text(tr("或粘贴配对链接"), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(
            controller: _text,
            maxLines: 3,
            minLines: 2,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(hintText: tr("粘贴从电脑获取的配对链接")),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: _working
                ? null
                : () {
                    _handled = false;
                    _accept(_text.text.trim());
                  },
            child: Text(tr("连接")),
          ),
          if (_working)
            const Padding(
              padding: EdgeInsets.only(top: 20),
              child: LinearProgressIndicator(),
            ),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(_message!),
            ),
        ],
      ),
    );
  }
}

String _connectionFailure(Object error, Uri service) {
  if (error is ProtocolException) return error.message;
  if (error is SocketException) {
    if (['localhost', '127.0.0.1', '::1'].contains(service.host)) {
      return tr("二维码使用了本机地址，手机无法访问。请在电脑端使用手机可访问的服务地址并重新生成二维码。");
    }
    return tr("无法连接接入服务，请确认手机与电脑的网络、服务地址及端口。局域网调试时需连接同一 Wi-Fi。");
  }
  if (error is TimeoutException) return tr("连接超时，请检查网络后重试。");
  if (error is HandshakeException) return tr("无法验证服务证书，请检查接入服务配置。");
  return tr("配对未完成，请检查电脑与接入服务后重试。");
}
