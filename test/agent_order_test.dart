import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/core/host_hub.dart';
import 'package:dogcodes_app/core/security/secret_storage.dart';

void main() {
  test('agent lists follow the PC order, then the desktop default', () {
    final installed = [
      {'providerId': 'antigravity'},
      {'providerId': 'claude-code'},
      {'providerId': 'codex'},
      {'providerId': 'custom'},
      {'providerId': 'kimi'},
    ];
    final custom = orderAgents(installed, (agent) => '${agent['providerId']}', [
      'kimi',
      'codex',
    ]);
    expect(custom.map((agent) => agent['providerId']), [
      'kimi',
      'codex',
      'claude-code',
      'antigravity',
      'custom',
    ]);

    final fallback = orderAgents(
      installed,
      (agent) => '${agent['providerId']}',
      const [],
    );
    expect(fallback.map((agent) => agent['providerId']), [
      'codex',
      'claude-code',
      'antigravity',
      'kimi',
      'custom',
    ]);
  });

  test('an Agent preference update reorders the open picker', () {
    final host = HostState({'hostId': 'mac'}, MemorySecretStorage());
    host.executors = [
      {'providerId': 'antigravity', 'installationId': 'a'},
      {'providerId': 'codex', 'installationId': 'c'},
      {'providerId': 'kimi', 'installationId': 'k'},
    ];
    host.applyAgentPreferences({
      'revision': 2,
      'preferences': {
        'order': ['kimi', 'codex'],
        'disabled': ['antigravity'],
      },
    });
    expect(host.agentOrder, ['kimi', 'codex']);
    expect(host.executors.map((agent) => agent['providerId']), [
      'kimi',
      'codex',
    ]);
  });
}
