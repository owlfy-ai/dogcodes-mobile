import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../../core/host_api.dart';
import '../../core/pc_api.dart';
import '../../ui/widgets.dart';
import 'preview_proxy.dart';

/// In-app preview of a dev server running on the PC (localhost only there).
class PreviewPage extends StatefulWidget {
  const PreviewPage({
    super.key,
    required this.link,
    required this.taskId,
    required this.port,
  });
  final HostLink link;
  final String taskId;
  final int port;
  @override
  State<PreviewPage> createState() => _PreviewPageState();
}

class _PreviewPageState extends State<PreviewPage> {
  PreviewProxy? proxy;
  WebViewController? web;
  String? error, path;
  int progress = 0;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    PreviewProxy? opening;
    try {
      final opened = await widget.link.previewOpen(widget.taskId, widget.port);
      final p = PreviewProxy(widget.link, opened['previewId'] as String);
      opening = p;
      if (!mounted) return;
      await p.start();
      if (!mounted) return;
      final origin = Uri(
        scheme: 'http',
        host: '127.0.0.1',
        port: p.port,
        path: '/',
      );
      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setNavigationDelegate(
          NavigationDelegate(
            onProgress: (v) => mounted ? setState(() => progress = v) : null,
            onUrlChange: (c) => mounted
                ? setState(() => path = Uri.tryParse(c.url ?? '')?.path)
                : null,
            // Stay inside the preview; external links are not followed.
            onNavigationRequest: (r) {
              final target = Uri.tryParse(r.url);
              return target?.scheme == origin.scheme &&
                      target?.host == origin.host &&
                      target?.port == origin.port
                  ? NavigationDecision.navigate
                  : NavigationDecision.prevent;
            },
          ),
        )
        ..loadRequest(origin);
      setState(() {
        proxy = p;
        web = controller;
      });
      opening = null; // The mounted page now owns this proxy.
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      await opening?.stop();
    }
  }

  @override
  void dispose() {
    proxy?.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: DetailBar(
      title: '预览',
      subtitle: 'localhost:${widget.port}${path ?? ''}',
      actions: [
        IconButton(
          tooltip: '后退',
          onPressed: web == null ? null : () => web!.goBack(),
          icon: const Icon(Icons.arrow_back),
        ),
        IconButton(
          tooltip: '刷新',
          onPressed: web == null ? null : () => web!.reload(),
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: error != null
        ? Center(child: InlineNotice(error!, danger: true))
        : web == null
        ? const Center(child: CircularProgressIndicator())
        : Column(
            children: [
              if (progress < 100)
                LinearProgressIndicator(value: progress / 100, minHeight: 2),
              Expanded(child: WebViewWidget(controller: web!)),
            ],
          ),
  );
}
