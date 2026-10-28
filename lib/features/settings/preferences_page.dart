import 'package:flutter/material.dart';
import '../../app.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'service_status.dart';
import 'offline_cache.dart';

/// 12 偏好设置. Appearance swatches are fixed white / black and do not invert
/// with the current theme.
class PreferencesPage extends StatelessWidget {
  const PreferencesPage({super.key});
  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final prefs = scope.preferences;
    return Scaffold(
      appBar: const DetailBar(title: '偏好设置'),
      body: ListenableBuilder(
        listenable: prefs,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            const SectionLabel('外观', top: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: DcSpace.page),
              child: Row(
                children: [
                  for (final (mode, label) in const [
                    (ThemeMode.system, '跟随系统'),
                    (ThemeMode.light, '亮色'),
                    (ThemeMode.dark, '暗色'),
                  ])
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: _ThemeTile(
                          mode: mode,
                          label: label,
                          selected: prefs.themeMode == mode,
                          onTap: () => prefs.setThemeMode(mode),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SectionLabel('连接'),
            _Row(
              icon: Icons.cloud_outlined,
              title: '接入服务',
              detail: scope.client?.origin.host ?? '未配置',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => Scaffold(
                    appBar: const DetailBar(title: '接入服务'),
                    body: ServiceStatus(client: scope.client),
                  ),
                ),
              ),
            ),
            const SectionLabel('电脑'),
            _Row(
              icon: Icons.devices_outlined,
              title: '管理已绑定设备',
              detail: '${scope.hub.hosts.length} 台',
              onTap: () => Navigator.of(context).maybePop(),
            ),
            const SizedBox(height: 16),
            const SectionLabel('本机数据'),
            OfflineCacheSettings(hub: scope.hub),
            const InlineNotice(
              '无需注册账号：通过电脑上的配对二维码建立信任，可随时在电脑上撤销。'
              '草稿和离线缓存保存在这部手机；提醒偏好可在电脑或会话菜单中设置。',
            ),
          ],
        ),
      ),
    );
  }
}

class _ThemeTile extends StatelessWidget {
  const _ThemeTile({
    required this.mode,
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final ThemeMode mode;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    const white = Color(0xFFFFFFFF), black = Color(0xFF000000);
    final border = Border.all(color: const Color(0xFFBDBDBD));
    final swatch = switch (mode) {
      ThemeMode.light => Container(
        decoration: BoxDecoration(color: white, border: border),
      ),
      ThemeMode.dark => Container(
        decoration: BoxDecoration(color: black, border: border),
      ),
      ThemeMode.system => Container(
        decoration: BoxDecoration(
          border: border,
          gradient: const LinearGradient(
            colors: [white, white, black, black],
            stops: [0, 0.5, 0.5, 1],
          ),
        ),
      ),
    };
    return Semantics(
      selected: selected,
      button: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(DcSpace.control),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(DcSpace.control),
            border: Border.all(
              color: selected ? c.accent : c.line,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Column(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(width: 44, height: 30, child: swatch),
              ),
              const SizedBox(height: 8),
              Text(label, style: const TextStyle(fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.title,
    this.detail,
    this.onTap,
  });
  final IconData icon;
  final String title;
  final String? detail;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: Container(
      constraints: const BoxConstraints(minHeight: 52),
      padding: const EdgeInsets.symmetric(horizontal: DcSpace.page),
      child: Row(
        children: [
          Icon(icon, size: 22),
          const SizedBox(width: 14),
          Expanded(child: Text(title)),
          if (detail != null)
            Text(detail!, style: Theme.of(context).textTheme.bodySmall),
          const Icon(Icons.chevron_right),
        ],
      ),
    ),
  );
}
