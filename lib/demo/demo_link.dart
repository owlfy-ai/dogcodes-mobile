import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../core/host_api.dart';
import '../core/protocol.dart';
import 'package:dogcodes_app/l10n/strings.dart';

/// The fictional computer behind the in-app example (示例模式).
///
/// It answers like a paired PC from memory only: no network, no pairing
/// record, no push registration. Sending a message, answering an approval and
/// stopping a turn are simulated so the main flows can be tried; other
/// changes to a computer are refused with an explanation. Everything is
/// discarded when the example is closed.
class DemoLink implements HostLink {
  DemoLink({this.replyDelay = const Duration(milliseconds: 900)});

  static const id = 'dogcodes-demo';

  /// Pause before each simulated step of an agent reply.
  final Duration replyDelay;

  @override
  String get hostId => id;
  @override
  String get hostName => tr("示例电脑");

  final _events = StreamController<Map<String, dynamic>>.broadcast();
  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  /// Pending reply steps per task.
  final _timers = <String, Set<Timer>>{};
  bool _closed = false;

  void _stop(String taskId) {
    for (final t in _timers.remove(taskId) ?? const <Timer>{}) {
      t.cancel();
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    for (final id in [..._timers.keys]) {
      _stop(id);
    }
    await _events.close();
  }

  static const _roots = [
    '/Projects/Canvas/web',
    '/Projects/Canvas/api',
    '/Projects/Canvas/shared',
  ];
  static const _providers = ['claude', 'codex', 'cursor'];

  static Map<String, String> _executor(String p) => {
    'providerId': p,
    'installationId': 'demo-$p',
  };

  final _start = DateTime.now().toUtc();
  String _at(int minutesAgo) =>
      _start.subtract(Duration(minutes: minutesAgo)).toIso8601String();
  String _now() => DateTime.now().toUtc().toIso8601String();

  var _sequence = 9;
  var _turns = 0;
  final _accepted = <String>{};

  late final _tasks = <Map<String, dynamic>>[
    for (final (i, title) in [
      "完善商品搜索体验",
      "为购物车添加单元测试",
      "检查登录接口权限",
      "整理组件与设计变量",
      "优化移动端导航",
      "更新产品介绍页面",
    ].indexed)
      {
        'taskId': 't$i',
        'projectId': i < 4 ? 'p1' : 'p2',
        'titleKey': title,
        'preferredExecutor': _executor(_providers[i % 3]),
        'activePrimaryRun': null,
        'streamVersion': 2,
        'updatedAt': _at(i * 17),
      },
  ];

  late final _pending = <String, List<Map<String, dynamic>>>{
    't0': [
      {
        'approvalId': 'demo-permission',
        'turnId': 'turn-t0',
        'toolName': 'Bash',
        'commandSummary': 'pnpm test --filter search',
        'requestedAtSequence': 8,
        'options': [
          {'optionId': 'deny', 'label': '拒绝', 'semanticRole': 'reject_once'},
          {'optionId': 'once', 'label': '允许一次', 'semanticRole': 'allow_once'},
        ],
      },
    ],
    't1': [
      {
        'approvalId': 'demo-question',
        'turnId': 'turn-t1',
        'toolName': 'AskUserQuestion',
        'commandSummary': '',
        'requestedAtSequence': 7,
        'options': [],
        'question': {
          'title': '购物车测试先覆盖哪一部分？',
          'schema': {
            'type': 'object',
            'required': ['scope'],
            'properties': {
              'scope': {
                'type': 'string',
                'title': '优先范围',
                'enum': ['数量与库存', '优惠计算'],
              },
            },
          },
        },
      },
    ],
  };

  /// Timeline items per task. Text keys go through [tr] when read, so the
  /// example follows the app language.
  late final _timeline = <String, List<Map<String, dynamic>>>{
    for (final (i, (ask, tool, answer)) in [
      (
        "给商品搜索加上防抖，保留最近使用的筛选条件，并补上测试。",
        "读取 src/search.ts · 检查测试配置",
        "已完成搜索体验优化。\n\n### 本次改动\n- 输入停止 300ms 后再发起搜索\n- 返回页面时恢复上次筛选条件\n- 空结果提供清除筛选入口\n\n```ts\nconst query = useDebounce(input, 300);\nconst filters = useSavedFilters();\n```\n\n运行测试前需要你的许可。",
      ),
      (
        "为购物车的加减数量和优惠计算补上单元测试。",
        "读取 src/cart.ts · 列出现有测试",
        "我先列出要覆盖的场景：数量增减、库存上限、满减和优惠券叠加。开始写测试前，想确认先覆盖哪一部分。",
      ),
      (
        "检查登录接口有没有越权访问的风险。",
        "读取 api/auth.ts · 读取 api/middleware.ts",
        "检查完成，没有发现越权问题。\n\n- 所有接口都经过登录校验\n- 管理接口额外校验角色\n- 建议给刷新令牌加上过期时间",
      ),
      (
        "把颜色和间距整理成设计变量。",
        "读取 shared/tokens.css · 更新 12 个组件",
        "已把颜色和间距整理到 shared/tokens.css，12 个组件改为引用变量，界面外观保持不变。",
      ),
      (
        "手机上的导航菜单太挤了，优化一下。",
        "读取 src/Nav.tsx · 检查断点样式",
        "窄屏下改为底部标签栏，菜单项加大点击区域，并在滚动时自动收起顶部栏。",
      ),
      (
        "首页加上新功能介绍和用户评价。",
        "读取 pages/index.html · 更新样式",
        "首页已新增功能介绍和用户评价两个区块，并补上了手机端布局。",
      ),
    ].indexed)
      't$i': [
        {
          'itemId': 't$i-ask',
          'kind': 'user_message',
          'turnId': 'turn-t$i',
          'textKey': ask,
          'occurredAt': _at(i * 17 + 6),
        },
        {
          'itemId': 't$i-tool',
          'providerId': _providers[i % 3],
          'kind': 'tool',
          'turnId': 'turn-t$i',
          'textKey': tool,
          'occurredAt': _at(i * 17 + 3),
        },
        {
          'itemId': 't$i-answer',
          'providerId': _providers[i % 3],
          'kind': 'assistant_message',
          'turnId': 'turn-t$i',
          'textKey': answer,
          'occurredAt': _at(i * 17),
        },
      ],
  };

  Map<String, dynamic>? _task(Object? taskId) =>
      _tasks.where((t) => t['taskId'] == taskId).firstOrNull;

  Map<String, dynamic> _shown(Map<String, dynamic> task) => {
    for (final e in task.entries)
      if (e.key != 'titleKey') e.key: e.value,
    'title': task['title'] ?? tr(task['titleKey'] as String),
  };

  Map<String, dynamic> _item(Map<String, dynamic> item) => {
    for (final e in item.entries)
      if (e.key != 'textKey') e.key: e.value,
    'text': item['text'] ?? tr(item['textKey'] as String),
  };

  void _later(String taskId, Duration delay, void Function() step) {
    late final Timer timer;
    timer = Timer(delay, () {
      _timers[taskId]?.remove(timer);
      if (!_closed) step();
    });
    _timers.putIfAbsent(taskId, () => {}).add(timer);
  }

  /// Marks [task] changed and tells the app, as a PC's event stream would.
  void _touch(Map<String, dynamic> task) {
    task['streamVersion'] = (task['streamVersion'] as int) + 1;
    task['updatedAt'] = _now();
    _sequence++;
    if (_closed) return;
    _events.add({
      'type': 'event',
      'event': {
        'sequence': '$_sequence',
        'eventType': 'task.updated',
        'taskId': task['taskId'],
        'streamVersion': task['streamVersion'],
        'payload': {'taskId': task['taskId']},
      },
    });
  }

  void _add(Map<String, dynamic> task, String kind, String text) {
    final provider = (task['preferredExecutor'] as Map)['providerId'];
    _timeline.putIfAbsent(task['taskId'] as String, () => []).add({
      'itemId': 'demo-${_sequence + 1}-$kind',
      if (kind != 'user_message') 'providerId': provider,
      'kind': kind,
      'turnId': (task['activePrimaryRun'] as Map?)?['turnId'] ?? 'turn-demo',
      'text': text,
      'occurredAt': _now(),
    });
  }

  void _begin(Map<String, dynamic> task) {
    _stop(task['taskId'] as String);
    _turns++;
    task['activePrimaryRun'] = {
      'runId': 'demo-run-$_turns',
      'turnId': 'demo-turn-$_turns',
    };
  }

  /// A simulated agent turn: work shown first, then the answer.
  void _reply(Map<String, dynamic> task, String tool, String answer) {
    if (task['activePrimaryRun'] == null) _begin(task);
    final id = task['taskId'] as String;
    _touch(task);
    _later(id, replyDelay, () {
      _add(task, 'tool', tool);
      _touch(task);
      _later(id, replyDelay, () {
        _add(task, 'assistant_message', answer);
        task['activePrimaryRun'] = null;
        _touch(task);
      });
    });
  }

  Map<String, dynamic> _submit(Map params) {
    final input = Map<String, dynamic>.from(params['input'] as Map? ?? {});
    final prompt = '${input['prompt'] ?? ''}'.trim();
    var task = _task(params['taskId']);
    if (task == null) {
      final title = prompt.split('\n').first;
      task = {
        'taskId': 'demo-t${_tasks.length}',
        'projectId': params['projectId'] ?? 'p1',
        'title': title.length > 40 ? '${title.substring(0, 40)}…' : title,
        'preferredExecutor': params['target'] ?? _executor(_providers.first),
        'activePrimaryRun': null,
        'streamVersion': 1,
        'updatedAt': _now(),
      };
      _tasks.insert(0, task);
    } else if (params['target'] is Map) {
      task['preferredExecutor'] = params['target'];
    }
    _begin(task);
    _add(task, 'user_message', prompt);
    _reply(
      task,
      tr("读取项目文件 · 分析需要的改动"),
      tr("这是示例模式里的模拟回复。连接你自己的电脑后，Agent 会在电脑上真正执行这条指令，并在这里实时显示进度。"),
    );
    return {
      'state': 'closed',
      'resolution': {'status': 'submitted', 'taskId': task['taskId']},
    };
  }

  void _respond(Map data) {
    final task = _task(data['taskId']);
    final list = _pending[data['taskId']];
    final approval = list
        ?.where((a) => a['approvalId'] == data['approvalId'])
        .firstOrNull;
    if (task == null || list == null || approval == null) return;
    list.remove(approval);
    if (approval['toolName'] == 'AskUserQuestion') {
      final answer = (data['answer'] as Map?)?['values']?['scope'];
      _reply(
        task,
        tr("记录你的选择 · 更新测试计划"),
        tr("好的，先从「{0}」开始编写测试。", [answer is String ? tr(answer) : tr("数量与库存")]),
      );
    } else if (data['optionId'] == 'deny') {
      _reply(task, tr("跳过运行测试"), tr("好的，这次不运行测试。改动已经保留，你可以稍后再运行。"));
    } else {
      _reply(
        task,
        'pnpm test --filter search',
        tr("测试全部通过（24 项）。改动可以在工作区里查看并提交。"),
      );
    }
  }

  void _cancel(Map data) {
    final task = _task(data['taskId']);
    if (task == null) return;
    _stop(task['taskId'] as String);
    task['activePrimaryRun'] = null;
    _add(task, 'tool', tr("已停止"));
    _touch(task);
  }

  @override
  Future<dynamic> call(String method, dynamic params) async {
    if (_closed) throw ProtocolException(tr("示例已关闭。"));
    switch (method) {
      case 'bootstrap':
        return {
          'projects': [
            {
              'projectId': 'p1',
              'displayName': 'Canvas',
              'path': _roots[0],
              'additionalDirectories': _roots.sublist(1),
              'taskCount': _tasks.where((t) => t['projectId'] == 'p1').length,
            },
            {
              'projectId': 'p2',
              'displayName': tr("产品官网"),
              'path': '/Projects/Website',
              'taskCount': _tasks.where((t) => t['projectId'] == 'p2').length,
            },
          ],
          'tasks': [for (final t in _tasks) _shown(t)],
          'installations': [
            for (final p in _providers)
              {..._executor(p), 'status': 'ready', 'version': '1.0.0'},
          ],
          'lastSequence': _sequence,
          'companion': {
            'workspaces': [
              for (final e in _pending.entries)
                {'taskId': e.key, 'pendingInteractionCount': e.value.length},
            ],
          },
        };
      case 'registered_executors':
        return [for (final p in _providers) _executor(p)];
      case 'agent_preferences':
        return {'disabled': []};
      case 'history_preferences':
        return null;
      case 'pending_approvals':
        return [
          for (final a in _pending[(params as List)[0]] ?? const [])
            _approval(a),
        ];
      case 'timeline_tail':
        throw const ProtocolException('remote method unavailable');
      case 'timeline_snapshot':
        return {
          'lastSequence': _sequence,
          'items': [
            for (final item in _timeline[(params as List)[0]] ?? const [])
              _item(item),
          ],
        };
      case 'model_catalog_for_task':
        return {
          'defaultModel': 'default',
          'models': [
            {
              'id': 'default',
              'label': tr("默认模型"),
              'thinkingOptions': [
                {'id': 'low', 'label': tr("低")},
                {'id': 'medium', 'label': tr("中")},
                {'id': 'high', 'label': tr("高")},
              ],
              'defaultThinking': 'high',
            },
            {
              'id': 'fast',
              'label': tr("快速模型"),
              'thinkingOptions': [
                {'id': 'low', 'label': tr("低")},
                {'id': 'high', 'label': tr("高")},
              ],
            },
          ],
        };
      case 'submission_intents':
        if (params['type'] == 'start') return _submit(params as Map);
        return {
          'state': 'closed',
          'resolution': {'status': 'submitted', 'taskId': params['taskId']},
        };
      case 'prepare_approval_response':
        final data = (params as List)[0]['payload']['data'] as Map;
        return {'taskId': data['taskId'], 'approvalId': data['approvalId']};
      case 'execute':
        final envelope = (params as List)[0] as Map;
        final payload = envelope['payload'] as Map;
        final data = payload['data'] as Map? ?? const {};
        _accepted.add('${envelope['commandId']}');
        if (payload['type'] == 'respond_to_approval') {
          _respond(data);
        } else if (payload['type'] == 'cancel_turn') {
          _cancel(data);
        } else {
          throw ProtocolException(_unavailable);
        }
        return {'accepted': true};
      case 'approval_receipt':
        return {'delivery': 'sent'};
      case 'command_receipt':
        final id = '${(params as List)[0]['commandId']}';
        return _accepted.contains(id)
            ? {'commandId': id, 'accepted': true}
            : null;
      case 'quota_snapshots_for':
        return [
          for (final (i, p) in _providers.indexed)
            {
              ..._executor(p),
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
      case 'power_preferences':
        return {'enabled': true, 'supported': true};
      case 'device_status':
        return {'locked': false};
      case 'remote_capabilities':
        return {'terminalInputStreams': true};
      case 'workspace_roots':
        return _roots;
      case 'workspace_directory':
        return [
          for (final name in ['src', 'components', 'public', 'tests'])
            {'name': name, 'path': name, 'directory': true},
          for (final name in [
            'package.json',
            'README.md',
            'tsconfig.json',
            'vite.config.ts',
          ])
            {'name': name, 'path': name, 'directory': false},
        ];
      case 'review':
        return _review(params as Map);
      case 'project_runs':
        return {
          'projectId': 'p1',
          'generation': 'demo-generation',
          'directories': [
            for (final (i, p) in _roots.indexed)
              {
                'path': p,
                'status': 'ready',
                'commands': [
                  {
                    'id': 'dev',
                    'label': i == 1 ? tr("API 开发服务") : tr("Web 开发服务"),
                    'command': 'pnpm dev',
                    'pinned': true,
                  },
                  {
                    'id': 'test',
                    'label': tr("运行测试"),
                    'command': 'pnpm test',
                    'pinned': false,
                  },
                ],
              },
          ],
        };
      case 'terminal_list':
        return [_terminal()];
      case 'terminal_get':
        return _terminal();
      case 'terminal_resize':
        return null;
      case 'terminal_read':
        return {
          'bytes': (params as List)[1] == '0'
              ? utf8.encode(
                  '\r\n> canvas-web@1.0.0 dev\r\n> vite\r\n\r\n'
                  '  \x1b[32mVITE\x1b[0m  ready in 214 ms\r\n\r\n'
                  '  ➜  Local: http://localhost:5173/\r\n\r\n'
                  '  ✓ dependencies optimized\r\n'
                  '  ✓ src/search.ts updated\r\n\r\n',
                )
              : <int>[],
          'next': '256',
          'info': _terminal(),
        };
      case 'terminal_input':
        return {
          'terminalId': 'demo-terminal',
          'epoch': 'demo',
          'revision': params['type'] == 'open' ? '1' : '0',
          'sequence': '0',
          'streamId': params['streamId'],
          'owned': true,
          'state': 'ready',
          'uncertain': false,
        };
      case 'remote_desktop_displays':
        return [
          {
            'id': 1,
            'width': 1600,
            'height': 1000,
            'scale': 1.0,
            'primary': true,
          },
        ];
      case 'remote_desktop_open':
        return {
          'leaseId': 'demo-desktop',
          'inputSequence': '0',
          'maxFps': 10,
          'inputBatch': 64,
        };
      case 'remote_desktop_frame':
        if (params is Map && params['knownFrameId'] == 'demo-frame') {
          return {'frameId': 'demo-frame', 'unchanged': true};
        }
        final frame = await rootBundle.load('assets/demo/desktop.png');
        return {
          'frameId': 'demo-frame',
          'width': 1600,
          'height': 1000,
          'bytes': base64.encode(frame.buffer.asUint8List()),
          'cursor': {'x': .5, 'y': .45},
        };
      case 'remote_desktop_input':
        return {'accepted': true};
      case 'remote_desktop_close':
      case 'preview_close':
        return {};
      case 'preview_open':
        return {'previewId': 'demo-preview', 'port': 5173};
      case 'preview_http':
        final html = await rootBundle.loadString('assets/demo/canvas.html');
        return {
          'status': 200,
          'headers': [
            ['content-type', 'text/html; charset=utf-8'],
          ],
          'body': base64.encode(utf8.encode(html)),
        };
      case 'remote_hosts':
        return const [];
      case 'computer_use_status':
        return const {'mode': 'idle'};
      case 'subscribe_project':
      case 'unsubscribe':
      case 'permission_catalog':
      case 'turn_reviews':
      case 'transport_status':
        return null;
    }
    if (_reads.any(method.startsWith)) return null;
    throw ProtocolException(_unavailable);
  }

  static const _reads = ['query_', 'timeline_', 'attachment_read'];

  String get _unavailable => tr("示例模式不会真正执行这项操作。连接你自己的电脑后即可使用。");

  /// Option labels and the question are app-owned example text.
  Map<String, dynamic> _approval(Map<String, dynamic> a) {
    final question = a['question'] as Map?;
    final layout = question?['schema']['properties']['scope'] as Map?;
    return {
      ...a,
      'options': [
        for (final o in a['options'] as List)
          {...o as Map, 'label': tr(o['label'] as String)},
      ],
      if (question != null)
        'question': {
          'title': tr(question['title'] as String),
          'schema': {
            ...question['schema'] as Map,
            'properties': {
              'scope': {
                ...layout!,
                'title': tr(layout['title'] as String),
                'enum': [
                  for (final e in layout['enum'] as List) tr(e as String),
                ],
              },
            },
          },
        },
    };
  }

  Map<String, dynamic> _terminal() => {
    'id': 'demo-terminal',
    'epoch': 'demo',
    'projectId': 'p1',
    'taskId': 't0',
    'directoryIndex': 0,
    'commandId': 'dev',
    'status': 'running',
    'createdAt': 1,
    'label': tr("Web 开发服务"),
    'cwd': _roots[0],
  };

  dynamic _review(Map params) {
    final op = params['operation'];
    if (op == 'query') {
      return {
        'id': 'demo-snapshot',
        'roots': [
          for (final (i, p) in _roots.indexed)
            {
              'root': {'id': 'root$i', 'path': p, 'git': true},
              'files': params['arguments']?['mode'] == 'staged' || i > 0
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
    throw ProtocolException(_unavailable);
  }
}
