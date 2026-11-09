import 'package:dogcodes_app/l10n/strings.dart';
import 'package:flutter/material.dart';

/// One kind per meaning, as on the desktop (permissionPresentation.ts): each
/// kind has exactly one icon and one label.
enum PermissionKind {
  ask,
  onRequest,
  edit,
  plan,
  read,
  auto,
  deny,
  bypass,
  full,
  configured,
}

/// A mode from the computer's permission catalog, ready to show.
typedef PermissionModeView = ({
  String id,
  String label,
  String description,
  PermissionKind kind,
});

// IDs belong to each provider: Kimi's auto and yolo mean something different
// from similarly named modes in other agents.
const _providerModes = <String, Map<String, (PermissionKind, String)>>{
  'cursor': {
    'default': (PermissionKind.ask, 'cursorDefault'),
    'full-access': (PermissionKind.bypass, 'cursorFullAccess'),
  },
  'codex': {
    'read-only': (PermissionKind.read, 'codexReadOnly'),
    'default': (PermissionKind.onRequest, 'codexDefault'),
    'full-access': (PermissionKind.full, 'codexFullAccess'),
  },
  'claude-code': {
    'plan': (PermissionKind.plan, 'claudePlan'),
    'default': (PermissionKind.ask, 'claudeDefault'),
    'acceptEdits': (PermissionKind.edit, 'claudeAcceptEdits'),
    'auto': (PermissionKind.auto, 'claudeAuto'),
    'dontAsk': (PermissionKind.deny, 'claudeDontAsk'),
    'bypassPermissions': (PermissionKind.bypass, 'claudeBypass'),
  },
  'codebuddy': {
    'default': (PermissionKind.ask, 'codebuddyDefault'),
    'acceptEdits': (PermissionKind.edit, 'codebuddyAcceptEdits'),
    'plan': (PermissionKind.plan, 'codebuddyPlan'),
    'auto': (PermissionKind.auto, 'codebuddyAuto'),
    'dontAsk': (PermissionKind.deny, 'codebuddyDontAsk'),
    'bypassPermissions': (PermissionKind.bypass, 'codebuddyBypass'),
    'fullAccess': (PermissionKind.full, 'codebuddyFullAccess'),
  },
  'grok': {
    'ask': (PermissionKind.ask, 'grokAsk'),
    'auto': (PermissionKind.auto, 'grokAuto'),
    'always-approve': (PermissionKind.bypass, 'grokAlwaysApprove'),
  },
  'zcode': {
    'build': (PermissionKind.ask, 'zcodeBuild'),
    'edit': (PermissionKind.edit, 'zcodeEdit'),
    'plan': (PermissionKind.plan, 'zcodePlan'),
    'auto': (PermissionKind.auto, 'zcodeAuto'),
    'yolo': (PermissionKind.bypass, 'zcodeYolo'),
  },
  'kimi': {
    'default': (PermissionKind.ask, 'kimiDefault'),
    'yolo': (PermissionKind.onRequest, 'kimiYolo'),
    'plan': (PermissionKind.plan, 'kimiPlan'),
    'auto': (PermissionKind.bypass, 'kimiAuto'),
  },
  'kiro': {
    'off': (PermissionKind.ask, 'kiroOff'),
    'on': (PermissionKind.bypass, 'kiroOn'),
  },
  'opencode': {
    'build': (PermissionKind.configured, 'opencodeBuild'),
    'plan': (PermissionKind.plan, 'opencodePlan'),
  },
  'antigravity': {
    'desktop-approvals': (PermissionKind.ask, 'antigravityApprovals'),
    'plan': (PermissionKind.plan, 'antigravityPlan'),
    'dangerously-skip-permissions': (PermissionKind.bypass, 'antigravitySkip'),
  },
  'pi': {'native': (PermissionKind.full, 'piNative')},
};

// Kinds for modes other agents report natively; their own text is kept.
const _nativeKinds = <String, PermissionKind>{
  'default': PermissionKind.ask,
  'ask': PermissionKind.ask,
  'acceptEdits': PermissionKind.edit,
  'edit': PermissionKind.edit,
  'plan': PermissionKind.plan,
  'read-only': PermissionKind.read,
  'readOnly': PermissionKind.read,
  'auto': PermissionKind.auto,
  'dontAsk': PermissionKind.deny,
  'build': PermissionKind.configured,
  'configured': PermissionKind.configured,
  'bypassPermissions': PermissionKind.bypass,
  'always-approve': PermissionKind.bypass,
  'auto-approve': PermissionKind.bypass,
  'allow-all': PermissionKind.bypass,
  'dangerously-skip-permissions': PermissionKind.bypass,
  'full-access': PermissionKind.full,
  'fullAccess': PermissionKind.full,
  'danger-full-access': PermissionKind.full,
};

String permissionKindLabel(PermissionKind kind) => switch (kind) {
  PermissionKind.ask => tr("操作前确认"),
  PermissionKind.auto => tr("自动判断"),
  PermissionKind.bypass => tr("跳过审批"),
  PermissionKind.configured => tr("原生规则"),
  PermissionKind.deny => tr("仅限预先允许"),
  PermissionKind.edit => tr("接受编辑"),
  PermissionKind.full => tr("完全访问"),
  PermissionKind.onRequest => tr("按需确认"),
  PermissionKind.plan => tr("计划模式"),
  PermissionKind.read => tr("只读模式"),
};

IconData permissionKindIcon(PermissionKind kind) => switch (kind) {
  PermissionKind.ask => Icons.front_hand_outlined,
  PermissionKind.onRequest => Icons.rule,
  PermissionKind.edit => Icons.edit_note,
  PermissionKind.plan => Icons.assignment_outlined,
  PermissionKind.read => Icons.visibility_outlined,
  PermissionKind.auto => Icons.auto_awesome_outlined,
  PermissionKind.deny => Icons.block,
  PermissionKind.bypass => Icons.bolt_outlined,
  PermissionKind.full => Icons.warning_amber_rounded,
  PermissionKind.configured => Icons.tune,
};

String _description(String key) => switch (key) {
  'antigravityApprovals' => tr("每次工具执行前在此审批；审批桥不可用时拒绝执行。"),
  'antigravityPlan' => tr("使用 Antigravity 原生计划模式；工具执行仍在此审批。"),
  'antigravitySkip' => tr("自动允许 Antigravity 工具操作。"),
  'claudeAcceptEdits' => tr("允许文件编辑；其他受保护操作仍需审批。"),
  'claudeAuto' => tr("由 Claude 自动分类权限请求。"),
  'claudeBypass' => tr("跳过 Claude Code 工具权限检查。"),
  'claudeDefault' => tr("编辑文件和其他受保护操作前请求审批。"),
  'claudeDontAsk' => tr("只运行预先允许的工具，其余直接拒绝，不请求审批。"),
  'claudePlan' => tr("探索并制定计划；使用 Claude 原生计划模式。"),
  'codebuddyAcceptEdits' => tr("本会话内自动接受文件编辑。"),
  'codebuddyAuto' => tr("由 AI 审查员批准或拒绝原本需要询问的操作；审查失败只阻止该操作。"),
  'codebuddyBypass' => tr("跳过所有权限确认。"),
  'codebuddyDefault' => tr("每个工具首次使用时请求授权。"),
  'codebuddyDontAsk' => tr("从不弹出确认；只运行预先允许和安全的只读操作，其余一律拒绝。"),
  'codebuddyFullAccess' => tr("对所有 Agent 跳过全部权限检查，包括危险命令。"),
  'codebuddyPlan' => tr("只分析，不修改文件或执行命令。"),
  'codexDefault' => tr("工作区写入沙箱；需要越出沙箱时请求审批。"),
  'codexFullAccess' => tr("关闭沙箱并跳过审批。"),
  'codexReadOnly' => tr("只读沙箱；需要扩大权限时请求审批。"),
  'configured' => tr("此 Agent 未报告可切换的权限模式；审批请求仍会显示在对话中。"),
  'cursorDefault' => tr("按 Cursor 权限规则执行；需要审批的操作在此确认。"),
  'cursorFullAccess' => tr("自动批准操作；明确禁止的操作和团队限制仍然生效。"),
  'grokAlwaysApprove' => tr("允许所有工具操作，无需审批。"),
  'grokAsk' => tr("受保护的工具操作前请求审批。"),
  'grokAuto' => tr("由 Grok 判断哪些工具操作可自动执行。"),
  'kimiAuto' => tr("不中断任务；所有操作和决策均自动进行。"),
  'kimiDefault' => tr("仅自动读取；其他操作均需先征得你的批准。"),
  'kimiPlan' => tr("先制定计划；需要批准的操作仍会询问。"),
  'kimiYolo' => tr("常规编辑和命令自动执行；高风险操作、提问和计划仍会询问。"),
  'kiroOff' => tr("监督模式：工具操作前请求审批。"),
  'kiroOn' => tr("自动驾驶：工具操作无需询问直接执行。"),
  'opencodeBuild' => tr("OpenCode 默认 Agent；工具按你配置的权限执行。"),
  'opencodePlan' => tr("计划模式；禁用所有编辑工具。"),
  'piNative' => tr("Pi 不内置逐工具审批或沙箱；工具直接执行，扩展发起的询问会显示在对话中。"),
  'zcodeAuto' => tr("由 ZCode 判断哪些操作可直接执行。"),
  'zcodeBuild' => tr("改文件前先问我。"),
  'zcodeEdit' => tr("自动编辑文件。"),
  'zcodePlan' => tr("编辑前先出计划。"),
  'zcodeYolo' => tr("减少确认次数。"),
  _ => key,
};

/// Catalogs the computer builds carry Chinese text; known modes are
/// translated, and modes agents report natively keep their own text.
PermissionModeView permissionPresentation(
  String? providerId,
  Map<String, dynamic> mode,
) {
  final id = '${mode['id']}';
  final provider = providerId == 'claude' ? 'claude-code' : providerId;
  final known = id == 'configured'
      ? (PermissionKind.configured, 'configured')
      : _providerModes[provider]?[id];
  if (known != null) {
    return (
      id: id,
      label: permissionKindLabel(known.$1),
      description: _description(known.$2),
      kind: known.$1,
    );
  }
  return (
    id: id,
    label: '${mode['label'] ?? id}',
    description: '${mode['description'] ?? ''}',
    kind:
        _nativeKinds[id] ??
        (mode['dangerous'] == true
            ? PermissionKind.bypass
            : PermissionKind.configured),
  );
}
