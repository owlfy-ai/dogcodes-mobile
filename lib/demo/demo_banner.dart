import 'package:dogcodes_app/l10n/strings.dart';
import 'package:flutter/material.dart';

import '../app.dart';
import '../ui/theme.dart';

/// Wraps every route while the example is open, so pages pushed on top of
/// the tabs still say that nothing here is real and offer the way out.
class DemoFrame extends StatelessWidget {
  const DemoFrame({super.key, required this.visible, required this.child});
  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!visible) return child;
    return Column(
      children: [
        const DemoBanner(),
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: child,
          ),
        ),
      ],
    );
  }
}

class DemoBanner extends StatelessWidget {
  const DemoBanner({super.key});

  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final c = context.dc;
    return Material(
      color: c.warning,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 6, 4),
          child: Row(
            children: [
              const Icon(Icons.visibility_outlined, size: 18, color: _ink),
              const SizedBox(width: 8),
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: tr("示例模式"),
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        TextSpan(text: '  ${tr("内容均为虚构，不会连接任何电脑")}'),
                      ],
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: _ink, fontSize: 13),
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: () => DogCodesApp.exitDemo(context),
                style: TextButton.styleFrom(
                  foregroundColor: _ink,
                  visualDensity: VisualDensity.compact,
                ),
                icon: const Icon(Icons.logout, size: 18),
                label: Text(
                  tr("退出示例"),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static const _ink = Color(0xFF1A1205);
}
