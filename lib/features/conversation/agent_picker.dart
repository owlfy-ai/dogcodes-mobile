import 'package:dogcodes_app/l10n/strings.dart';
import 'package:flutter/material.dart';
import 'permission_presentation.dart';
import '../../core/host_api.dart';
import '../../app.dart';
import '../../core/host_hub.dart';
import '../../ui/quota_ring.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

/// Agent / model / thinking choice for one send. Kept per page on this phone;
/// it never overwrites the PC's own pending selection.
class AgentChoice {
  const AgentChoice(
    this.executor, {
    this.catalog,
    this.model,
    this.thinking,
    this.permissions,
    this.permissionMode,
  });
  final Map<String, dynamic> executor;
  final Map<String, dynamic>? catalog;
  final String? model;
  final String? thinking;

  /// The agent's permission catalog (`modes`, `defaultModeId`); null when the
  /// computer could not provide one.
  final Map<String, dynamic>? permissions;

  /// Chosen permission mode; null keeps the agent's default.
  final String? permissionMode;

  List<PermissionModeView> get permissionModes => [
    for (final m in (permissions?['modes'] as List? ?? const []))
      if (m is Map)
        permissionPresentation(
          executor['providerId'] as String?,
          Map<String, dynamic>.from(m),
        ),
  ];

  /// The mode the next turn runs with, as the desktop sends it.
  String? get effectivePermission {
    final ids = permissionModes.map((m) => m.id);
    if (permissionMode != null && ids.contains(permissionMode)) {
      return permissionMode;
    }
    final fallback = permissions?['defaultModeId'] as String?;
    return ids.contains(fallback) ? fallback : null;
  }

  PermissionModeView? get permissionView {
    final id = effectivePermission;
    return permissionModes.where((m) => m.id == id).firstOrNull;
  }

  String get agentName => agentLabel(executor['providerId'] as String?);
  List<Map<String, dynamic>> get models => [
    for (final m in (catalog?['models'] as List? ?? const []))
      Map<String, dynamic>.from(m as Map),
  ];
  Map<String, dynamic>? get _model {
    for (final m in models) {
      if (m['id'] == model) return m;
    }
    return null;
  }

  String get modelName => _model?['label'] as String? ?? tr("默认模型");
  List<Map<String, dynamic>> get thinkingOptions => [
    for (final t in (_model?['thinkingOptions'] as List? ?? const []))
      Map<String, dynamic>.from(t as Map),
  ];
  String? get defaultThinking => _model?['defaultThinking'] as String?;

  String? labelOf(String? id) {
    for (final t in thinkingOptions) {
      if (t['id'] == id) return t['label'] as String;
    }
    return null;
  }

  /// Chosen level, or the model's default when the user kept it.
  String get thinkingName =>
      labelOf(thinking) ?? labelOf(defaultThinking) ?? tr("默认");

  AgentChoice withModel(String? id) => AgentChoice(
    executor,
    catalog: catalog,
    model: id,
    permissions: permissions,
    permissionMode: permissionMode,
  );
  AgentChoice withThinking(String? id) => AgentChoice(
    executor,
    catalog: catalog,
    model: model,
    thinking: id,
    permissions: permissions,
    permissionMode: permissionMode,
  );
  AgentChoice withPermission(String? id) => AgentChoice(
    executor,
    catalog: catalog,
    model: model,
    thinking: thinking,
    permissions: permissions,
    permissionMode: id,
  );
}

/// The agent's own "use my default" reasoning option, as opposed to a level.
bool isAgentDefaultThinking(Object? id) => '$id'.toLowerCase() == 'default';

bool sameExecutor(Map? a, Map? b) {
  if (a == null || b == null) return false;
  final x = a['installationId'], y = b['installationId'];
  if (x != null && y != null) return x == y;
  return a['providerId'] == b['providerId'];
}

Future<AgentChoice> loadChoice(
  HostApi link,
  Map<String, dynamic> executor,
  String? taskId,
) async {
  final permissions = link
      .call('permission_catalog', [executor, taskId])
      .then<Map<String, dynamic>?>(
        (v) => v is Map ? Map<String, dynamic>.from(v) : null,
        // An older computer or a busy agent: keep its default policy.
        onError: (Object _) => null,
      );
  final catalog = Map<String, dynamic>.from(
    await link.call('model_catalog_for_task', [executor, null, taskId]) as Map,
  );
  return AgentChoice(
    executor,
    catalog: catalog,
    model: catalog['defaultModel'] as String?,
    permissions: await permissions,
  );
}

/// Picks the task's last executor when it is still ready, else the first.
Map<String, dynamic>? defaultExecutor(HostState h, Map? task) {
  final wanted = task?['lastTurnExecutor'] ?? task?['preferredExecutor'];
  for (final e in h.executors) {
    if (sameExecutor(e, wanted as Map?)) return e;
  }
  return h.executors.isEmpty ? null : h.executors.first;
}

Future<AgentChoice?> showAgentSheet(
  BuildContext context, {
  required HostState host,
  required AgentChoice? initial,
  String? taskId,
}) => showModalBottomSheet<AgentChoice>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => _AgentSheet(
    hub: AppScope.of(context).hub,
    host: host,
    initial: initial,
    taskId: taskId,
  ),
);

class _AgentSheet extends StatefulWidget {
  const _AgentSheet({
    required this.hub,
    required this.host,
    this.initial,
    this.taskId,
  });
  final HostHub hub;
  final HostState host;
  final AgentChoice? initial;
  final String? taskId;
  @override
  State<_AgentSheet> createState() => _AgentSheetState();
}

class _AgentSheetState extends State<_AgentSheet> {
  AgentChoice? choice;
  bool loading = false;
  String? error;

  @override
  void initState() {
    super.initState();
    widget.hub.addListener(_hubChanged);
    choice = widget.initial;
    if (widget.host.executors.isEmpty) {
      _loadExecutors();
    } else {
      _pickDefault();
    }
  }

  void _hubChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.hub.removeListener(_hubChanged);
    super.dispose();
  }

  void _pickDefault() {
    if (choice == null || choice!.catalog == null) {
      // The session's own Agent first, like the conversation composer.
      final e =
          choice?.executor ??
          defaultExecutor(widget.host, widget.host.task(widget.taskId));
      if (e != null) pick(e);
    }
  }

  Future<void> _loadExecutors() async {
    setState(() => loading = true);
    final failure = await widget.hub.loadExecutors(widget.host);
    if (!mounted) return;
    setState(() {
      loading = false;
      error = failure;
    });
    if (failure == null) _pickDefault();
  }

  Future<void> pick(Map<String, dynamic> executor) async {
    final link = widget.host.link;
    setState(() {
      choice = AgentChoice(executor);
      loading = true;
      error = null;
    });
    if (link == null) {
      setState(() => loading = false);
      return;
    }
    try {
      final value = await loadChoice(link, executor, widget.taskId);
      if (mounted && sameExecutor(choice?.executor, executor)) {
        setState(() => choice = value);
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final c = context.dc;
    final selected = choice;
    final thinking = selected?.thinkingOptions ?? const [];
    return Padding(
      padding: const EdgeInsets.fromLTRB(DcSpace.page, 0, DcSpace.page, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(tr("选择 Agent"), style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          if (widget.host.executors.isEmpty && !loading && error == null)
            Text(
              tr("这台电脑上没有已就绪并启用的 Agent。安装或登录需在电脑上完成。"),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              children: [
                for (final e in widget.host.executors)
                  _AgentRow(
                    executor: e,
                    quota: QuotaMeter.from(
                      widget.host.quotas[e['installationId']],
                    ),
                    selected: sameExecutor(e, selected?.executor),
                    onTap: () => pick(e),
                  ),
              ],
            ),
          ),
          Divider(color: c.line),
          SizedBox(
            height: DcSpace.touch + 8,
            child: Row(
              children: [
                Text(tr("模型")),
                const Spacer(),
                if (loading)
                  const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  PopupMenuButton<String>(
                    enabled: (selected?.models.isNotEmpty ?? false),
                    tooltip: tr("选择模型"),
                    onSelected: (v) =>
                        setState(() => choice = selected!.withModel(v)),
                    itemBuilder: (_) => [
                      for (final m in selected!.models)
                        PopupMenuItem(
                          value: m['id'] as String,
                          child: Text(m['label'] as String),
                        ),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(selected?.modelName ?? tr("默认模型")),
                          const Icon(Icons.expand_more, size: 18),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (thinking.isNotEmpty)
            ThinkingSlider(
              choice: selected!,
              onChanged: (id) =>
                  setState(() => choice = selected.withThinking(id)),
            ),
          if (!loading && (selected?.permissionModes.isNotEmpty ?? false))
            PermissionPicker(
              choice: selected!,
              onChanged: (id) =>
                  setState(() => choice = selected.withPermission(id)),
            ),
          if (error != null) InlineNotice(error!, danger: true),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: selected == null || loading
                ? null
                : () => Navigator.of(context).pop(selected),
            child: Text(tr("完成")),
          ),
        ],
      ),
    );
  }
}

class _AgentRow extends StatelessWidget {
  const _AgentRow({
    required this.executor,
    required this.selected,
    required this.onTap,
    this.quota,
  });
  final Map<String, dynamic> executor;
  final QuotaMeter? quota;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final c = context.dc;
    final label = executor['label'] ?? executor['displayName'];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Panel(
        onTap: onTap,
        outlined: !selected,
        child: Row(
          children: [
            AgentGlyph(providerId: executor['providerId'] as String?, size: 36),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    agentLabel(executor['providerId'] as String?),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  if (label is String && label.isNotEmpty)
                    Text(label, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
            if (quota != null) ...[
              QuotaBars(meter: quota!),
              const SizedBox(width: 12),
            ],
            Icon(
              selected ? Icons.check_circle : Icons.radio_button_unchecked,
              color: selected ? c.accent : c.line,
              semanticLabel: selected ? tr("已选择") : tr("未选择"),
            ),
          ],
        ),
      ),
    );
  }
}

/// Permission policy row: the current mode, and a menu of the agent's modes
/// with what each allows. Applies from the next turn, as on the desktop.
class PermissionPicker extends StatelessWidget {
  const PermissionPicker({
    super.key,
    required this.choice,
    required this.onChanged,
  });
  final AgentChoice choice;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final c = context.dc;
    final current = choice.permissionView;
    Color tone(PermissionModeView m) =>
        m.kind == PermissionKind.full ? c.removed : c.text;
    return SizedBox(
      height: DcSpace.touch + 8,
      child: Row(
        children: [
          Text(tr("权限策略")),
          const Spacer(),
          PopupMenuButton<String>(
            tooltip: tr("权限策略"),
            onSelected: onChanged,
            constraints: const BoxConstraints(maxWidth: 320),
            itemBuilder: (_) => [
              for (final m in choice.permissionModes)
                PopupMenuItem(
                  value: m.id,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Icon(
                          permissionKindIcon(m.kind),
                          size: 20,
                          color: tone(m),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              m.label,
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: tone(m),
                              ),
                            ),
                            if (m.description.isNotEmpty)
                              Text(
                                m.description,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 20,
                        child: m.id == current?.id
                            ? Icon(Icons.check, size: 18, color: c.accent)
                            : null,
                      ),
                    ],
                  ),
                ),
              // A quiet footnote under a hairline, not another option.
              const PopupMenuDivider(height: 9),
              PopupMenuItem(
                enabled: false,
                height: 28,
                padding: const EdgeInsets.fromLTRB(12, 2, 12, 4),
                child: Row(
                  children: [
                    Icon(
                      Icons.info_outline,
                      size: 13,
                      color: c.secondary.withValues(alpha: 0.7),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        tr("所选策略在下一轮执行时生效"),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.2,
                          color: c.secondary.withValues(alpha: 0.7),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (current != null) ...[
                    Icon(
                      permissionKindIcon(current.kind),
                      size: 18,
                      color: tone(current),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Text(
                    current?.label ?? tr("默认权限"),
                    style: TextStyle(
                      color: current == null ? null : tone(current),
                    ),
                  ),
                  const Icon(Icons.expand_more, size: 18),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The agent chip under the composer, with its quota.
class AgentChips extends StatelessWidget {
  const AgentChips({
    super.key,
    required this.choice,
    required this.onTap,
    this.quota,
    this.loading = false,
  });
  final AgentChoice? choice;
  final QuotaMeter? quota;
  final bool loading;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final c = choice;
    // One chip; the composer scales it down rather than scrolling.
    return _Chip(
      c?.agentName ?? (loading ? tr("加载 Agent…") : tr("选择 Agent")),
      onTap,
      quota: quota,
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.label, this.onTap, {this.quota});
  final String label;
  final QuotaMeter? quota;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final radius = BorderRadius.circular(DcSpace.touch / 2);
    return Material(
      color: context.dc.surface,
      borderRadius: radius,
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        // At least as tall as the buttons beside it; one to three quota
        // rows grow it, always centred.
        child: Container(
          constraints: const BoxConstraints(minHeight: DcSpace.touch),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: const TextStyle(fontSize: 13)),
              if (quota != null) ...[
                const SizedBox(width: 8),
                QuotaBars(meter: quota!, compact: true),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Intensity order shared by vendors; ids outside it (e.g. auto, default) are
/// modes rather than levels and are offered as chips beside the slider.
const _thinkingRank = {
  'off': 0,
  'none': 0,
  'minimal': 1,
  'low': 2,
  'medium': 3,
  'high': 4,
  'xhigh': 5,
  'max': 6,
  'ultra': 7,
};

/// Dynamic thinking control: a slider over the model's levels (any count),
/// low to high, plus chips for non-level modes.
class ThinkingSlider extends StatelessWidget {
  const ThinkingSlider({
    super.key,
    required this.choice,
    required this.onChanged,
  });
  final AgentChoice choice;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final c = context.dc;
    final options = choice.thinkingOptions;
    final levels =
        [
          for (final t in options)
            if (_thinkingRank.containsKey('${t['id']}'.toLowerCase())) t,
        ]..sort(
          (a, b) => _thinkingRank['${a['id']}'.toLowerCase()]!.compareTo(
            _thinkingRank['${b['id']}'.toLowerCase()]!,
          ),
        );
    // An agent's own "default" option means "use the agent's default", the
    // same as choosing nothing, so it gets no chip of its own.
    final modes = [
      for (final t in options)
        if (!levels.contains(t) && !isAgentDefaultThinking(t['id'])) t,
    ];
    final effective = choice.thinking ?? choice.defaultThinking;
    final index = levels.indexWhere((t) => t['id'] == effective);
    final usingDefault =
        choice.thinking == null || isAgentDefaultThinking(choice.thinking);
    String label(Map t) => '${t['label']}';
    int at(double v) => v.round().clamp(0, levels.length - 1);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(tr("思考强度")),
              const Spacer(),
              Text(
                !usingDefault
                    ? choice.thinkingName
                    : isAgentDefaultThinking(effective) ||
                          index < 0 && modes.isEmpty
                    ? tr("默认")
                    : tr("默认 · {0}", [choice.thinkingName]),
                style: TextStyle(fontWeight: FontWeight.w600, color: c.text),
              ),
              if (!usingDefault)
                TextButton(
                  onPressed: () => onChanged(null),
                  child: Text(tr("恢复默认")),
                ),
            ],
          ),
          if (modes.isNotEmpty)
            Wrap(
              spacing: 8,
              children: [
                for (final m in modes)
                  ChoiceChip(
                    label: Text(label(m)),
                    selected: effective == m['id'],
                    selectedColor: c.surface,
                    backgroundColor: c.canvas,
                    labelStyle: TextStyle(color: c.text),
                    checkmarkColor: c.accent,
                    side: BorderSide(
                      color: effective == m['id'] ? c.accent : c.line,
                    ),
                    onSelected: (_) => onChanged(m['id'] as String),
                  ),
              ],
            ),
          if (levels.length > 1) ...[
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: index < 0 ? c.line : c.accent,
                inactiveTrackColor: c.line,
                thumbColor: index < 0 ? c.secondary : c.accent,
                activeTickMarkColor: c.onAccent.withValues(alpha: 0.4),
                inactiveTickMarkColor: c.secondary,
                valueIndicatorColor: c.text,
                valueIndicatorTextStyle: TextStyle(color: c.canvas),
                showValueIndicator: ShowValueIndicator.onDrag,
              ),
              child: Slider(
                // Another agent's levels get their own slider: the render
                // object updates its value before its range, so a reused one
                // briefly asks for a level the new list does not have.
                key: ValueKey(levels.map((t) => t['id']).join('|')),
                min: 0,
                max: (levels.length - 1).toDouble(),
                divisions: levels.length - 1,
                value: (index < 0 ? 0 : index).toDouble(),
                label: label(levels[index < 0 ? 0 : index]),
                semanticFormatterCallback: (v) => label(levels[at(v)]),
                onChanged: (v) => onChanged(levels[at(v)]['id'] as String),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                children: [
                  Text(
                    label(levels.first),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const Spacer(),
                  Text(
                    label(levels.last),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ] else if (levels.length == 1)
            Wrap(
              children: [
                ChoiceChip(
                  label: Text(label(levels.first)),
                  labelStyle: TextStyle(color: c.text),
                  checkmarkColor: c.accent,
                  selected: effective == levels.first['id'],
                  onSelected: (_) => onChanged(levels.first['id'] as String),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
