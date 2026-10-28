import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/app.dart';
import 'package:dogcodes_app/core/host_hub.dart';
import 'package:dogcodes_app/core/protocol.dart';
import 'package:dogcodes_app/features/inbox/pending_page.dart';
import 'package:dogcodes_app/core/security/secret_storage.dart';

class FakeLink implements HostLink {
  FakeLink(this.hostId, {this.name = 'MacBook Pro'});
  final String name;
  @override
  final String hostId;
  final calls = <String>[];
  bool tailPaging = false;
  final executed = <Map<String, dynamic>>[];
  @override
  String? get hostName => name;
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  @override
  Stream<Map<String, dynamic>> get events => _events.stream;
  @override
  Future<void> close() async => _events.close();
  void push(Map<String, dynamic> envelope) =>
      _events.add({'type': 'event', 'event': envelope});

  static final now = DateTime.now().toUtc().toIso8601String();
  static final executor = {
    'installationId': 'inst-claude',
    'providerId': 'claude',
  };

  @override
  Future<dynamic> call(String method, dynamic params) async {
    calls.add(method);
    // Behaves like a PC from before tail paging: the page falls back.
    if (method == 'timeline_tail' && !tailPaging) {
      throw const ProtocolException('remote method unavailable');
    }
    if (method == 'command_receipt' &&
        params[0]['payload']['type'] == 'cancel_turn') {
      final id = (params[0] as Map)['commandId'];
      return executed.any((e) => e['commandId'] == id)
          ? {'commandId': id, 'accepted': true}
          : null;
    }
    if (method == 'execute') {
      executed.add(Map<String, dynamic>.from(params[0] as Map));
    }
    return switch (method) {
      'bootstrap' => {
        'projects': [
          {
            'projectId': 'p1',
            'displayName': 'dogcodes-web',
            'path': '/Users/dev/dogcodes-web',
            'taskCount': 2,
          },
        ],
        'tasks': [
          {
            'taskId': 't1',
            'projectId': 'p1',
            'title': '优化登录流程',
            'preferredExecutor': executor,
            'activePrimaryRun': {'runId': 'r1', 'turnId': 'turn1'},
            'streamVersion': 4,
            'updatedAt': now,
          },
          {
            'taskId': 't2',
            'projectId': 'p1',
            'title': '修复移动端布局',
            'preferredExecutor': executor,
            'activePrimaryRun': null,
            'streamVersion': 2,
            'updatedAt': now,
          },
        ],
        'installations': [
          {
            'installationId': 'inst-claude',
            'providerId': 'claude',
            'status': 'ready',
            'version': '2.1.0',
          },
          {
            'installationId': 'inst-codex',
            'providerId': 'codex',
            'status': 'not_configured',
          },
        ],
        'lastSequence': 9,
        'companion': {
          'workspaces': [
            {'taskId': 't1', 'pendingInteractionCount': 1},
            {'taskId': 't2', 'pendingInteractionCount': 1},
          ],
        },
      },
      'agent_preferences' => {'disabled': []},
      'registered_executors' => [executor],
      'prepare_approval_response' => {
        'taskId': params[0]['payload']['data']['taskId'],
      },
      'approval_receipt' => {'delivery': 'sent'},
      'execute' => {'accepted': true},
      'pending_approvals' when params[0] == 't2' => [
        {
          'approvalId': 'q1',
          'turnId': 'turn2',
          'toolName': 'AskUserQuestion',
          'commandSummary': '',
          'requestedAtSequence': 7,
          'options': [],
          'question': {
            'title': '登录方式采用哪一种？',
            'schema': {
              'type': 'object',
              'required': ['method'],
              'properties': {
                'method': {
                  'type': 'string',
                  'title': '登录方式',
                  'enum': ['邮箱验证码', '账号密码'],
                },
              },
            },
          },
        },
      ],
      'pending_approvals' =>
        params[0] == 't1'
            ? [
                {
                  'approvalId': 'a1',
                  'turnId': 'turn1',
                  'toolName': 'Bash',
                  'commandSummary': 'pnpm test',
                  'requestedAtSequence': 8,
                  'options': [
                    {
                      'optionId': 'deny',
                      'label': '拒绝',
                      'semanticRole': 'reject_once',
                    },
                    {
                      'optionId': 'once',
                      'label': '允许一次',
                      'semanticRole': 'allow_once',
                    },
                    {
                      'optionId': 'always',
                      'label': '本会话始终允许',
                      'semanticRole': 'allow_always',
                    },
                  ],
                },
              ]
            : [],
      'timeline_snapshot' => {
        'items': [
          {
            'kind': 'user_message',
            'text': '完善登录流程，并补上错误提示。',
            'occurredAt': now,
          },
          {
            'kind': 'assistant_message',
            'text': '我会先检查登录逻辑，再处理错误状态。',
            'occurredAt': now,
          },
          {'kind': 'tool', 'text': '读取 auth.ts\n42 lines', 'occurredAt': now},
        ],
        'lastSequence': 9,
      },
      'model_catalog_for_task' => {
        'defaultModel': 'default',
        'models': [
          {
            'id': 'default',
            'label': '默认模型',
            'thinkingOptions': [
              {'id': 'low', 'label': '低'},
              {'id': 'high', 'label': '高'},
            ],
          },
        ],
      },
      _ => null,
    };
  }
}

HostHub fakeHub([FakeLink? link]) => HostHub(
  storage: MemorySecretStorage(),
  lister: () async => [
    {'hostId': 'macbook-pro-host', 'displayName': 'MacBook Pro'},
  ],
  connector: (host) async => link ?? FakeLink(host['hostId'] as String),
);

void main() {
  testWidgets('unconfigured app starts on 电脑 with an honest empty state', (
    tester,
  ) async {
    await tester.pumpWidget(const DogCodesApp());
    await tester.pumpAndSettle();
    expect(find.text('把电脑上的工作带在身边'), findsOneWidget);
    final connect = tester.widget<ButtonStyleButton>(
      find.ancestor(
        of: find.text('连接电脑'),
        matching: find.bySubtype<ButtonStyleButton>(),
      ),
    );
    expect(connect.onPressed, isNull);
    for (final label in ['会话', '工作区', '待处理', '电脑']) {
      expect(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text(label),
        ),
        findsOneWidget,
      );
    }
    await tester.tap(find.text('会话').last);
    await tester.pumpAndSettle();
    expect(find.text('会话将从电脑同步'), findsOneWidget);
    await tester.tap(find.text('电脑').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('偏好设置'));
    await tester.pumpAndSettle();
    expect(find.text('跟随系统'), findsOneWidget);
    expect(find.text('未配置'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sessions, pending approvals and conversation use PC data', (
    tester,
  ) async {
    final link = FakeLink('macbook-pro-host');
    final hub = fakeHub(link);
    await tester.pumpWidget(DogCodesApp(hub: hub));
    await tester.pumpAndSettle();

    expect(find.text('优化登录流程'), findsOneWidget);
    expect(find.text('修复移动端布局'), findsOneWidget);
    expect(find.text('2 项等待处理'), findsOneWidget);
    expect(find.text('待处理').first, findsOneWidget);
    // One computer: its level is a plain label; sessions grouped by project.
    expect(find.text('MacBook Pro'), findsOneWidget);
    expect(find.text('全部项目'), findsOneWidget);
    expect(find.text('dogcodes-web'), findsOneWidget);

    await tester.tap(find.text('2 项等待处理'));
    await tester.pumpAndSettle();
    expect(find.text('允许 Bash？'), findsOneWidget);
    expect(find.text('pnpm test'), findsOneWidget);
    expect(find.text('允许一次'), findsOneWidget);
    expect(find.text('拒绝'), findsOneWidget);
    expect(find.byTooltip('其他授权范围'), findsOneWidget);

    // Structured question answered on the phone, validated again by the PC.
    await tester.scrollUntilVisible(
      find.text('发送回答'),
      200,
      scrollable: find
          .descendant(
            of: find.byType(PendingPage),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('登录方式采用哪一种？'), findsOneWidget);
    await tester.ensureVisible(find.text('邮箱验证码'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('邮箱验证码'));
    await tester.pump();
    await tester.ensureVisible(find.text('发送回答'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('发送回答'));
    await tester.pumpAndSettle();
    final answer = link.executed.last['payload']['data'];
    expect(answer['approvalId'], 'q1');
    expect(answer['optionId'], '');
    expect(answer['answer'], {
      'cancelled': false,
      'values': {'method': '邮箱验证码'},
    });

    await tester.tap(find.text('电脑').last);
    await tester.pumpAndSettle();
    expect(find.text('MacBook Pro'), findsOneWidget);
    expect(find.text('在线'), findsOneWidget);
    expect(find.text('远程桌面'), findsOneWidget);
    expect(find.text('已就绪'), findsOneWidget);
    expect(find.text('需要在电脑上配置'), findsOneWidget);

    await tester.tap(find.text('会话').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('优化登录流程'));
    // A running task shows an indefinite progress indicator.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // The timeline is built lazily and opens at its end.
    final timeline = find
        .descendant(
          of: find.byKey(const ValueKey('conversation-timeline')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('完善登录流程，并补上错误提示。'),
      -300,
      scrollable: timeline,
    );
    expect(find.text('完善登录流程，并补上错误提示。'), findsOneWidget);
    expect(find.text('我会先检查登录逻辑，再处理错误状态。'), findsOneWidget);
    expect(find.text('读取 auth.ts'), findsOneWidget);
    expect(find.text('Claude Code'), findsOneWidget);
    expect(find.text('默认模型'), findsOneWidget);
    expect(link.calls, contains('timeline_snapshot'));
    expect(link.calls, contains('subscribe_project'));

    // Streamed answer chunks merge in place: no snapshot or overview reload.
    final reads = link.calls.length;
    for (final (seq, text) in [(10, '登录错误'), (11, '已改为明确提示。')]) {
      link.push({
        'sequence': seq,
        'eventType': 'message.delta',
        'occurredAt': FakeLink.now,
        'source': {'kind': 'driver', 'providerId': 'claude'},
        'payload': {
          'taskId': 't1',
          'turnId': 'turn1',
          'itemId': 'm2',
          'text': text,
        },
      });
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(find.text('登录错误已改为明确提示。'), findsOneWidget);
    expect(link.calls.sublist(reads), isNot(contains('timeline_snapshot')));
    expect(link.calls.sublist(reads), isNot(contains('bootstrap')));

    await tester.scrollUntilVisible(
      find.text('Agent 正在电脑上工作…'),
      300,
      scrollable: timeline,
    );
    expect(find.text('Agent 正在电脑上工作…'), findsOneWidget);
    await tester.tap(find.byTooltip('停止'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final cancel = link.executed.last['payload'];
    expect(cancel['type'], 'cancel_turn');
    expect(cancel['data'], {'taskId': 't1', 'turnId': 'turn1', 'runId': 'r1'});
    expect(find.text('允许 Bash？'), findsOneWidget);
    await tester.tap(find.byTooltip('返回'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    hub.dispose();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a computer can be removed from this phone only', (tester) async {
    final forgotten = <String>[];
    final hub = HostHub(
      storage: MemorySecretStorage(),
      lister: () async => [
        {'hostId': 'macbook-pro-host', 'displayName': 'MacBook Pro'},
      ],
      connector: (host) async => FakeLink(host['hostId'] as String),
      forgetter: (id, _) async => forgotten.add(id),
    );
    await tester.pumpWidget(DogCodesApp(hub: hub));
    await tester.pumpAndSettle();
    await tester.tap(find.text('电脑').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('从手机移除'));
    await tester.pumpAndSettle();
    expect(find.text('从这部手机移除「MacBook Pro」？'), findsOneWidget);
    await tester.tap(find.text('移除'));
    await tester.pumpAndSettle();
    expect(forgotten, ['macbook-pro-host']);
    expect(find.text('把电脑上的工作带在身边'), findsOneWidget);
    hub.dispose();
  });

  testWidgets('sessions filter computer first, then its projects', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final hub = HostHub(
      storage: MemorySecretStorage(),
      lister: () async => [
        {'hostId': 'mac', 'displayName': 'MacBook Pro'},
        {'hostId': 'win', 'displayName': 'Windows 台式机'},
      ],
      connector: (host) async => FakeLink(
        host['hostId'] as String,
        name: host['displayName'] as String,
      ),
    );
    await tester.pumpWidget(DogCodesApp(hub: hub));
    await tester.pumpAndSettle();
    // All computers: both appear as group headers; project level unavailable.
    expect(find.text('全部电脑'), findsOneWidget);
    expect(find.text('Windows 台式机'), findsOneWidget);
    expect(find.text('优化登录流程'), findsNWidgets(2));
    expect(find.text('全部项目'), findsOneWidget);
    expect(find.byTooltip('选择项目'), findsNothing);

    await tester.tap(find.text('全部电脑'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('MacBook Pro').last);
    await tester.pumpAndSettle();
    expect(find.text('优化登录流程'), findsOneWidget);
    expect(hub.sessionScope.value, ('mac', null));

    await tester.tap(find.text('全部项目'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('dogcodes-web').last);
    await tester.pumpAndSettle();
    expect(hub.sessionScope.value, ('mac', 'p1'));
    expect(find.text('修复移动端布局'), findsOneWidget);

    // 「全部」 entries must be selectable, not treated as a dismissal.
    await tester.tap(find.text('dogcodes-web').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部项目').last);
    await tester.pumpAndSettle();
    expect(hub.sessionScope.value, ('mac', null));

    await tester.tap(find.byTooltip('选择电脑'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部电脑').last);
    await tester.pumpAndSettle();
    expect(hub.sessionScope.value, (null, null));
    expect(find.text('优化登录流程'), findsNWidgets(2));
    hub.dispose();
  });

  testWidgets('workspace 查看全部 filters 会话 without changing workspace', (
    tester,
  ) async {
    final hub = fakeHub();
    await tester.pumpWidget(DogCodesApp(hub: hub));
    await tester.pumpAndSettle();
    await tester.tap(find.text('工作区').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看全部'));
    await tester.pumpAndSettle();
    expect(hub.sessionScope.value, ('macbook-pro-host', 'p1'));
    expect(find.text('搜索会话'), findsOneWidget);
    expect(find.text('dogcodes-web'), findsWidgets);
    hub.dispose();
  });

  testWidgets('dark theme keeps a pure black canvas', (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final hub = fakeHub();
    await tester.pumpWidget(DogCodesApp(hub: hub));
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(HomeShell));
    expect(Theme.of(context).scaffoldBackgroundColor, const Color(0xFF000000));
    hub.dispose();
  });

  testWidgets('small screen and large text remain usable', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final hub = fakeHub();
    await tester.pumpWidget(DogCodesApp(hub: hub));
    await tester.pumpAndSettle();
    for (final tab in ['工作区', '待处理', '电脑', '会话']) {
      await tester.tap(find.text(tab).last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: tab);
    }
    hub.dispose();
  });
}
