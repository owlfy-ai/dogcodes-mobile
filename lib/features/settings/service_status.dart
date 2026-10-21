import 'package:flutter/material.dart';
import '../../core/access_client.dart';
import '../../core/protocol.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

class ServiceStatus extends StatefulWidget {
  const ServiceStatus({super.key, required this.client});
  final AccessClient? client;
  @override
  State<ServiceStatus> createState() => _ServiceStatusState();
}

class _ServiceStatusState extends State<ServiceStatus> {
  bool _checking = false;
  String? _message;
  ServiceInfo? _info;
  Future<void> _check() async {
    setState(() {
      _checking = true;
      _message = null;
      _info = null;
    });
    try {
      final info = await widget.client!.info();
      if (!mounted) return;
      setState(() {
        _info = info;
        _message = '服务连接正常';
      });
    } catch (error) {
      if (!mounted) return;
      setState(
        () =>
            _message = error is ProtocolException ? error.message : '连接失败，请重试。',
      );
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(DcSpace.page),
    children: [
      Text(
        '接入服务只转发加密数据，会话和任务保存在你的电脑上。',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: 16),
      Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.client == null ? '尚未配置服务地址' : widget.client!.origin.origin,
            ),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _message!,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            if (_info != null && _info!.capabilities['pairing'] != true)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '此服务尚未开放电脑配对。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        onPressed: widget.client == null || _checking ? null : _check,
        icon: _checking
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.network_check),
        label: Text(_checking ? '正在检查' : '检查连接'),
      ),
    ],
  );
}
