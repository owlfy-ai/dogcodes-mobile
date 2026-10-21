import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../core/host_hub.dart';
import '../../core/mobile_runtime.dart';
import '../../core/protocol.dart';
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
        _message = '正在验证电脑身份并建立配对…';
      });
      final runtime = widget.runtime;
      if (runtime == null) throw const ProtocolException('加密组件尚未准备好。');
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
          _message = '配对未完成，请检查电脑与接入服务后重试。${kDebugMode ? '\n$error' : ''}';
        });
      }
    }
    if (mounted) {
      setState(() => _working = false);
      _text.clear();
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    return Scaffold(
      appBar: const DetailBar(title: '连接电脑'),
      body: ListView(
        padding: const EdgeInsets.all(DcSpace.page),
        children: [
          Text(
            '在电脑端打开「连接手机」，扫描配对二维码。',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 6),
          Text(
            '配对后可访问这台电脑的 Agent 与项目会话。你可以随时在电脑上撤销授权。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 20),
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
                    child: const Text(
                      '无法使用相机，请检查相机权限，或在下方粘贴配对链接。',
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
              label: const Text('扫描二维码'),
            ),
          const SizedBox(height: 28),
          Text('或粘贴配对链接', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(
            controller: _text,
            maxLines: 3,
            minLines: 2,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(hintText: '粘贴从电脑获取的配对链接'),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: _working
                ? null
                : () {
                    _handled = false;
                    _accept(_text.text.trim());
                  },
            child: const Text('连接'),
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
