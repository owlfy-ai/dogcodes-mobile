// Isolated fictional data for store captures; never connects to a PC.
import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:dogcodes_app/core/host_api.dart';
import 'package:dogcodes_app/core/protocol.dart';

const roots = [
  '/Projects/Canvas/web',
  '/Projects/Canvas/api',
  '/Projects/Canvas/shared',
];
final date = DateTime(
  DateTime.now().year,
  DateTime.now().month,
  DateTime.now().day,
  9,
  40,
).toUtc();
Map<String, String> executor(String p) => {
  'providerId': p,
  'installationId': 'store-$p',
};

class StoreLink implements HostLink {
  StoreLink({
    this.approvals = true,
    this.english = false,
    this.working = false,
    this.plainTerminal = false,
  });
  final bool english, working, plainTerminal;
  @override
  String get hostId => 'store-mac';
  @override
  String get hostName => 'MacBook Pro';
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  @override
  Stream<Map<String, dynamic>> get events => _events.stream;
  @override
  Future<void> close() async {
    await _events.close();
  }

  final bool approvals;
  @override
  Future<dynamic> call(String method, dynamic params) async =>
      localize(await data(method, params));

  Future<dynamic> data(String method, dynamic params) async {
    if (method == 'bootstrap') {
      return {
        'projects': [
          {
            'projectId': 'p1',
            'displayName': 'Canvas',
            'path': roots[0],
            'additionalDirectories': roots.sublist(1),
            'taskCount': 4,
          },
          {
            'projectId': 'p2',
            'displayName': '产品官网',
            'path': '/Projects/Website',
            'taskCount': 2,
          },
        ],
        'tasks': [
          for (final (i, title) in [
            '完善商品搜索体验',
            '为购物车添加单元测试',
            '检查登录接口权限',
            '整理组件与设计变量',
            '优化移动端导航',
            '更新产品介绍页面',
          ].indexed)
            {
              'taskId': 't$i',
              'projectId': i < 4 ? 'p1' : 'p2',
              'title': title,
              'preferredExecutor': executor(
                ['claude', 'codex', 'cursor'][i % 3],
              ),
              'activePrimaryRun': working && i < 3
                  ? {'runId': 'store-run-$i', 'turnId': 'turn-$i'}
                  : null,
              'streamVersion': 2,
              'updatedAt': date
                  .subtract(Duration(minutes: i * 17))
                  .toIso8601String(),
            },
        ],
        'installations': [
          for (final p in ['claude', 'codex', 'cursor'])
            {...executor(p), 'status': 'ready', 'version': '1.0.0'},
        ],
        'lastSequence': 9,
        'companion': {
          'workspaces': [
            {'taskId': 't0', 'pendingInteractionCount': approvals ? 1 : 0},
            {'taskId': 't1', 'pendingInteractionCount': approvals ? 1 : 0},
          ],
        },
      };
    }
    if (method == 'registered_executors') {
      return [
        for (final p in ['claude', 'codex', 'cursor']) executor(p),
      ];
    }
    if (method == 'pending_approvals') {
      if (!approvals) return [];
      if (params[0] == 't0') {
        return [
          {
            'approvalId': 'store-permission',
            'turnId': 'turn-search',
            'toolName': 'Bash',
            'commandSummary': 'pnpm test --filter search',
            'requestedAtSequence': 8,
            'options': [
              {'optionId': 'deny', 'label': '拒绝', 'semanticRole': 'reject'},
              {
                'optionId': 'once',
                'label': '允许一次',
                'semanticRole': 'approve_once',
              },
            ],
          },
        ];
      }
      if (params[0] == 't1') {
        return [
          {
            'approvalId': 'store-question',
            'turnId': 'turn-test',
            'toolName': 'AskUserQuestion',
            'requestedAtSequence': 7,
            'options': [],
            'question': {
              'title': '搜索结果采用哪种展示方式？',
              'schema': {
                'type': 'object',
                'required': ['layout'],
                'properties': {
                  'layout': {
                    'type': 'string',
                    'title': '结果布局',
                    'enum': ['紧凑列表', '商品卡片'],
                  },
                },
              },
            },
          },
        ];
      }
      return [];
    }
    if (method == 'timeline_snapshot') {
      return {
        'lastSequence': 9,
        'items': [
          {
            'itemId': 'request',
            'kind': 'user_message',
            'turnId': 'turn-search',
            'text': '给商品搜索加上防抖，保留最近使用的筛选条件，并补上测试。',
            'occurredAt': date.toIso8601String(),
          },
          {
            'itemId': 'work',
            'providerId': 'claude',
            'kind': 'tool',
            'turnId': 'turn-search',
            'text': '读取 src/search.ts · 检查测试配置',
            'occurredAt': date.toIso8601String(),
          },
          {
            'itemId': 'answer',
            'providerId': 'claude',
            'kind': 'assistant_message',
            'turnId': 'turn-search',
            'text':
                '已完成搜索体验优化。\n\n### 本次改动\n- 输入停止 300ms 后再发起搜索\n- 返回页面时恢复上次筛选条件\n- 空结果提供清除筛选入口\n\n```ts\nconst query = useDebounce(input, 300);\nconst filters = useSavedFilters();\n```\n\n新增的单元测试已通过，可以继续检查代码变更。',
            'occurredAt': date.toIso8601String(),
          },
        ],
      };
    }
    if (method == 'model_catalog_for_task') {
      return {
        'defaultModel': 'default',
        'models': [
          {
            'id': 'default',
            'label': '默认模型',
            'thinkingOptions': [
              {'id': 'low', 'label': '低'},
              {'id': 'medium', 'label': '中'},
              {'id': 'high', 'label': '高'},
            ],
            'defaultThinking': 'high',
          },
          {
            'id': 'fast',
            'label': '快速模型',
            'thinkingOptions': [
              {'id': 'low', 'label': '低'},
              {'id': 'high', 'label': '高'},
            ],
          },
        ],
      };
    }
    if (method == 'workspace_roots') return roots;
    if (method == 'workspace_directory') {
      return [
        for (final name in ['src', 'components', 'public', 'tests'])
          {'name': name, 'path': name, 'directory': true},
        for (final name in [
          'package.json',
          'README.md',
          'tsconfig.json',
          'vite.config.ts',
          '.gitignore',
        ])
          {'name': name, 'path': name, 'directory': false},
      ];
    }
    if (method == 'review') {
      final op = params['operation'];
      if (op == 'query') {
        return {
          'id': 'store-snapshot',
          'roots': [
            for (final (i, p) in roots.indexed)
              {
                'root': {'id': 'root$i', 'path': p, 'git': true},
                'files': params['arguments']['mode'] == 'staged'
                    ? []
                    : [
                        {'path': 'src/search.ts', 'kind': 'modified'},
                        {'path': 'tests/search.test.ts', 'kind': 'added'},
                        {
                          'path': 'src/components/SearchBar.tsx',
                          'kind': 'modified',
                        },
                      ],
                'statistics': {
                  'src/search.ts': {'additions': 8, 'deletions': 2},
                  'tests/search.test.ts': {'additions': 24, 'deletions': 0},
                },
              },
          ],
        };
      }
      if (op == 'workspaces') {
        return [
          {'current': true, 'git': true, 'branch': 'feature/search'},
        ];
      }
      if (op == 'file') {
        return {
          'text': {
            'before': [
              'export function search(input: string) {',
              '  return fetchResults(input);',
              '}',
            ],
            'after': [
              'export function search(input: string) {',
              '  const query = input.trim();',
              '  if (!query) return [];',
              '',
              '  return fetchResults(query, {',
              '    debounceMs: 300,',
              '    filters: savedFilters,',
              '  });',
              '}',
            ],
          },
        };
      }
      return [];
    }
    if (method == 'project_runs') {
      return {
        'projectId': 'p1',
        'generation': 'store-generation',
        'directories': [
          for (final (i, p) in roots.indexed)
            {
              'path': p,
              'status': 'ready',
              'commands': [
                {
                  'id': 'dev',
                  'label': i == 1 ? 'API 开发服务' : 'Web 开发服务',
                  'command': 'pnpm dev',
                  'pinned': true,
                },
                {
                  'id': 'test',
                  'label': '运行测试',
                  'command': 'pnpm test',
                  'pinned': false,
                },
              ],
            },
        ],
      };
    }
    final terminal = {
      'id': 'store-terminal',
      'epoch': 'store',
      'projectId': 'p1',
      'taskId': plainTerminal ? null : 't0',
      'directoryIndex': 0,
      'commandId': plainTerminal ? null : 'dev',
      'status': 'running',
      'createdAt': 1,
      'label': plainTerminal ? 'Canvas · web' : 'Web 开发服务',
      'cwd': roots[0],
    };
    if (method == 'terminal_list') return [terminal];
    if (method == 'terminal_read') {
      return {
        'bytes': params[1] == '0'
            ? utf8.encode(
                plainTerminal
                    ? '\r\ncanvas/web % pnpm test\r\n\r\n RUN  tests/search.test.ts\r\n\r\n ✓ debounce search requests\r\n ✓ restore saved filters\r\n ✓ clear empty results\r\n ✓ preserve query on navigation\r\n\r\n Test Files  3 passed (3)\r\n      Tests  24 passed (24)\r\n   Duration  1.24s\r\n\r\ncanvas/web % git status --short\r\n M src/search.ts\r\n A tests/search.test.ts\r\n\r\ncanvas/web % '
                    : '\r\n> canvas-web@1.0.0 dev\r\n> vite\r\n\r\n  \x1b[32mVITE\x1b[0m  ready in 214 ms\r\n\r\n  ➜  Local: http://localhost:5173/\r\n\r\n  ✓ dependencies optimized\r\n  ✓ src/search.ts updated\r\n  ✓ browser connected\r\n\r\n',
              )
            : [],
        'next': '256',
        'info': terminal,
      };
    }
    if (method == 'terminal_resize') return null;
    if (method == 'terminal_get') return terminal;
    if (method == 'remote_capabilities') return {'terminalInputStreams': true};
    if (method == 'terminal_input') {
      return {
        'terminalId': 'store-terminal',
        'epoch': 'store',
        'revision': params['type'] == 'open' ? '1' : '0',
        'sequence': '0',
        'streamId': params['streamId'],
        'owned': true,
        'state': 'ready',
        'uncertain': false,
      };
    }
    if (method == 'execute') {
      throw StateError('Screenshot fixtures never execute work.');
    }
    if (method == 'timeline_tail') {
      throw const ProtocolException('remote method unavailable');
    }
    if (method == 'agent_preferences') return {'disabled': []};
    if (method == 'quota_snapshots_for') {
      return [
        for (final (i, p) in ['claude', 'codex', 'cursor'].indexed)
          {
            ...executor(p),
            'quota': {
              'confidence': 'provider_reported',
              'staleAfterUnixMs': DateTime.now()
                  .add(const Duration(hours: 1))
                  .millisecondsSinceEpoch,
              'windows': [
                {
                  'id': p == 'cursor' ? 'cursor-models' : 'five-hour',
                  'windowMinutes': p == 'cursor' ? 0 : 300,
                  'usedPercent': [24, 48, 63][i],
                  'resetsAtUnix':
                      DateTime.now()
                          .add(Duration(hours: i + 2))
                          .millisecondsSinceEpoch ~/
                      1000,
                },
              ],
            },
          },
      ];
    }
    if (method == 'power_preferences') {
      return {'enabled': true, 'supported': true};
    }
    if (method == 'device_status') return {'locked': false};
    if (method == 'remote_desktop_displays') {
      return [
        {'id': 1, 'width': 1600, 'height': 1000, 'scale': 1.0, 'primary': true},
      ];
    }
    if (method == 'remote_desktop_open') {
      return {
        'leaseId': 'store-desktop',
        'inputSequence': '0',
        'maxFps': 10,
        'inputBatch': 64,
      };
    }
    if (method == 'remote_desktop_frame') {
      if (params?['knownFrameId'] == 'store-frame') {
        return {'frameId': 'store-frame', 'unchanged': true};
      }
      final frame = File('build/store-captures-v2/desktop.png');
      return {
        'frameId': 'store-frame',
        'width': 1600,
        'height': 1000,
        'bytes': base64.encode(frame.readAsBytesSync()),
        'cursor': {'x': .5, 'y': .45},
      };
    }
    if (method == 'remote_desktop_close') return {};
    if (method == 'preview_open') {
      return {'previewId': 'store-preview', 'port': 5173};
    }
    if (method == 'preview_http') {
      const encoded = String.fromEnvironment('STORE_PREVIEW_HTML_BASE64');
      final html = utf8.decode(base64.decode(encoded));
      return {
        'status': 200,
        'headers': [
          ['content-type', 'text/html; charset=utf-8'],
        ],
        'body': base64.encode(utf8.encode(html)),
      };
    }
    if (method == 'preview_close') return {};
    return null;
  }

  dynamic localize(dynamic value) {
    if (!english) return value;
    if (value is Map) {
      return {for (final e in value.entries) e.key: localize(e.value)};
    }
    if (value is List) return value.map(localize).toList();
    if (value is! String) return value;
    return translations[value] ?? value;
  }

  static const translations = {
    '产品官网': 'Website',
    '完善商品搜索体验': 'Improve product search',
    '为购物车添加单元测试': 'Test the shopping cart',
    '检查登录接口权限': 'Review sign-in permissions',
    '整理组件与设计变量': 'Organize design tokens',
    '优化移动端导航': 'Polish mobile navigation',
    '更新产品介绍页面': 'Update the landing page',
    '默认模型': 'Default model',
    '快速模型': 'Fast model',
    'Web 开发服务': 'Web dev server',
    'API 开发服务': 'API dev server',
    '运行测试': 'Run tests',
    '高': 'High',
    '中': 'Medium',
    '低': 'Low',
    '搜索结果采用哪种展示方式？': 'How should search results appear?',
    '结果布局': 'Results layout',
    '紧凑列表': 'Compact list',
    '商品卡片': 'Product cards',
    '给商品搜索加上防抖，保留最近使用的筛选条件，并补上测试。':
        'Add search debouncing, remember the last filters, and cover both with tests.',
    '读取 src/search.ts · 检查测试配置': 'Read src/search.ts · Inspect test setup',
    '已完成搜索体验优化。\n\n### 本次改动\n- 输入停止 300ms 后再发起搜索\n- 返回页面时恢复上次筛选条件\n- 空结果提供清除筛选入口\n\n```ts\nconst query = useDebounce(input, 300);\nconst filters = useSavedFilters();\n```\n\n新增的单元测试已通过，可以继续检查代码变更。':
        'Search improvements are ready.\n\n### What changed\n- Debounce requests by 300ms\n- Restore your last filters\n- Add a clear-filters empty state\n\n```ts\nconst query = useDebounce(input, 300);\nconst filters = useSavedFilters();\n```\n\nThe new unit tests pass. The changes are ready for review.',
  };
}
