import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/app.dart';
import 'package:dogcodes_app/core/host_hub.dart';
import 'package:dogcodes_app/core/security/secret_storage.dart';
import 'widget_test.dart' show FakeLink;

/// A PC with two real projects, its built-in 快速对话 project, the shared
/// project-list settings and project editing.
class ProjectsLink extends FakeLink {
  ProjectsLink() : super('mac');
  var revision = 1;
  Map<String, dynamic> prefs = {
    'tasks': <String, dynamic>{},
    'projects': <String, dynamic>{},
    'sorts': <String, dynamic>{},
    'orders': <String, dynamic>{},
  };
  final edits = <Map<String, dynamic>>[];
  late List<Map<String, dynamic>> projects = [
    {
      'projectId': 'p1',
      'displayName': 'dogcodes-web',
      'path': '/Users/dev/dogcodes-web',
      'additionalDirectories': ['/Users/dev/dogcodes-docs'],
      'streamVersion': 7,
      'taskCount': 2,
    },
    {
      'projectId': 'p2',
      'displayName': 'owlfy',
      'path': '/Users/dev/owlfy',
      'additionalDirectories': <String>[],
      'streamVersion': 3,
      'taskCount': 0,
    },
    {
      'projectId': 'scratch',
      'displayName': '快速对话',
      'path': '/Users/dev/scratch',
      'additionalDirectories': <String>[],
      'streamVersion': 1,
      'taskCount': 1,
    },
  ];

  @override
  Future<dynamic> call(String method, dynamic params) async {
    switch (method) {
      case 'command_receipt'
          when params[0]['payload']['type'] == 'set_history_preferences':
        final id = (params[0] as Map)['commandId'];
        return executed.any((e) => e['commandId'] == id)
            ? {'commandId': id, 'accepted': true}
            : null;
      case 'history_preferences':
        return {
          'revision': revision,
          'lastSequence': 0,
          'preferences': jsonDecode(jsonEncode(prefs)),
        };
      case 'update_project':
        final edit = Map<String, dynamic>.from(params[0] as Map);
        edits.add(edit);
        final p = projects.firstWhere(
          (p) => p['projectId'] == edit['projectId'],
        );
        p
          ..['displayName'] = edit['displayName']
          ..['path'] = edit['path']
          ..['additionalDirectories'] = edit['additionalDirectories']
          ..['streamVersion'] = (p['streamVersion'] as int) + 1;
        return null;
      case 'execute':
        final payload = (params[0] as Map)['payload'] as Map;
        if (payload['type'] == 'set_history_preferences') {
          prefs = Map<String, dynamic>.from(
            jsonDecode(jsonEncode(payload['data'])) as Map,
          );
          revision++;
        }
    }
    final value = await super.call(method, params);
    if (method == 'bootstrap') {
      final base = Map<String, dynamic>.from(value as Map);
      base['projects'] = jsonDecode(jsonEncode(projects));
      base['tasks'] = [
        ...(base['tasks'] as List),
        {
          'taskId': 't-quick',
          'projectId': 'scratch',
          'title': '随便问问',
          'preferredExecutor': FakeLink.executor,
          'activePrimaryRun': null,
          'streamVersion': 1,
          'updatedAt': FakeLink.now,
        },
      ];
      return base;
    }
    return value;
  }
}

Future<(HostHub, ProjectsLink)> start(WidgetTester tester) async {
  final link = ProjectsLink();
  final hub = HostHub(
    storage: MemorySecretStorage(),
    lister: () async => [
      {'hostId': 'mac', 'displayName': 'MacBook Pro'},
    ],
    connector: (_) async => link,
  );
  await tester.pumpWidget(DogCodesApp(hub: hub));
  await tester.pumpAndSettle();
  return (hub, link);
}

Future<void> openTab(WidgetTester tester, String label) async {
  await tester.tap(
    find.descendant(of: find.byType(NavigationBar), matching: find.text(label)),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('会话 sheet filters by project or 不在项目中工作', (tester) async {
    final (hub, _) = await start(tester);
    // The PC's built-in project is never listed as a project.
    expect(find.text('快速对话'), findsNothing);
    expect(find.text('无项目'), findsOneWidget); // its session group

    await tester.tap(find.byTooltip('选择项目'));
    await tester.pumpAndSettle();
    expect(find.text('全部项目'), findsWidgets);
    expect(find.text('不在项目中工作'), findsOneWidget);
    expect(find.text('新建项目'), findsOneWidget);
    // Filtering never manages projects.
    expect(find.byTooltip('项目操作'), findsNothing);

    await tester.tap(find.text('不在项目中工作'));
    await tester.pumpAndSettle();
    expect(hub.sessionScope.value, ('mac', 'scratch'));
    expect(find.text('随便问问'), findsOneWidget);
    expect(find.text('优化登录流程'), findsNothing);
    // The field reads like the desktop: 无项目.
    expect(
      find.descendant(of: find.byTooltip('选择项目'), matching: find.text('无项目')),
      findsOneWidget,
    );

    await tester.tap(find.byTooltip('选择项目'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('owlfy'));
    await tester.pumpAndSettle();
    expect(hub.sessionScope.value, ('mac', 'p2'));
    await tester.pumpWidget(const SizedBox());
    hub.dispose();
  });

  testWidgets('项目 sheet pins, removes and restores like the desktop', (
    tester,
  ) async {
    final (hub, link) = await start(tester);
    await openTab(tester, '项目');
    await tester.tap(find.byTooltip('选择项目'));
    await tester.pumpAndSettle();
    // A real project is always chosen here: no 全部 / 无项目 choices.
    expect(find.text('不在项目中工作'), findsNothing);
    expect(find.text('全部项目'), findsNothing);
    expect(find.text('owlfy'), findsOneWidget);

    // ⋯ on owlfy → 置顶项目.
    await tester.tap(
      find.descendant(
        of: find.ancestor(
          of: find.text('owlfy'),
          matching: find.byType(ListTile),
        ),
        matching: find.byTooltip('项目操作'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('置顶项目'));
    await tester.pumpAndSettle();
    expect(link.prefs['projects'], {'p2': 'pinned'});

    // Long press → 移除项目, confirmed.
    await tester.longPress(find.text('owlfy'));
    await tester.pumpAndSettle();
    expect(find.text('取消置顶'), findsOneWidget);
    await tester.tap(find.text('移除项目'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移除'));
    await tester.pumpAndSettle();
    expect(link.prefs['projects'], {'p2': 'removed'});
    expect(find.text('已移除项目（1）'), findsOneWidget);

    await tester.tap(find.text('已移除项目（1）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复'));
    await tester.pumpAndSettle();
    expect(link.prefs['projects'], isEmpty);
    expect(find.textContaining('已移除项目'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    hub.dispose();
  });

  testWidgets('editing renames and reorders directories on the PC', (
    tester,
  ) async {
    final (hub, link) = await start(tester);
    await openTab(tester, '项目');
    // Header ⋯ acts on the current project.
    await tester.tap(find.byTooltip('项目操作').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑项目'));
    await tester.pumpAndSettle();
    expect(find.text('/Users/dev/dogcodes-web'), findsOneWidget);
    expect(find.text('主目录'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'dogcodes');
    // Make the docs directory the main one.
    await tester.tap(find.byTooltip('目录操作').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('设为主目录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(link.edits.single, {
      'projectId': 'p1',
      'expectedStreamVersion': '7',
      'displayName': 'dogcodes',
      'path': '/Users/dev/dogcodes-docs',
      'additionalDirectories': ['/Users/dev/dogcodes-web'],
    });
    expect(find.text('编辑项目'), findsNothing);
    expect(hub.hosts.single.project('p1')?['displayName'], 'dogcodes');
    await tester.pumpWidget(const SizedBox());
    hub.dispose();
  });

  testWidgets('a removed project hides its sessions like the desktop', (
    tester,
  ) async {
    final (hub, link) = await start(tester);
    expect(find.text('优化登录流程'), findsOneWidget);
    expect(find.text('修复移动端布局'), findsOneWidget);
    // Removed on the PC; one of its sessions is pinned.
    link.prefs = {
      ...link.prefs,
      'projects': {'p1': 'removed'},
      'tasks': {'t2': 'pinned'},
    };
    link.revision++;
    await hub.refresh(hub.hosts.single);
    await tester.pumpAndSettle();
    expect(find.text('优化登录流程'), findsNothing);
    expect(find.text('修复移动端布局'), findsOneWidget); // pinned stays
    expect(find.text('随便问问'), findsOneWidget); // other projects unaffected
    // Search does not bring it back either.
    await tester.enterText(find.byType(TextField).first, '优化');
    await tester.pumpAndSettle();
    expect(find.text('优化登录流程'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    hub.dispose();
  });
}
