import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/app.dart';
import 'package:dogcodes_app/core/secure_host_client.dart';
import 'package:dogcodes_app/features/workspace/add_project_page.dart';
import 'widget_test.dart' show FakeLink, fakeHub;

class ProjectLink extends FakeLink {
  ProjectLink({
    this.empty = false,
    this.loseReply = false,
    this.existing = false,
  }) : super('macbook-pro-host');
  final bool empty, loseReply, existing;
  final created = <Map<String, dynamic>>[];
  final registrations = <Map<String, dynamic>>[];
  static const path = r'C:\Projects\app';
  @override
  Future<dynamic> call(String method, dynamic params) async {
    if (method == 'host_directories') {
      final target = params['path'];
      return target == null
          ? {
              'path': null,
              'parent': null,
              'next': null,
              'entries': [
                {'name': 'C 盘', 'path': 'C:\\'},
              ],
            }
          : target == 'C:\\'
          ? {
              'path': 'C:\\',
              'parent': null,
              'next': null,
              'entries': [
                {'name': 'Projects', 'path': r'C:\Projects'},
              ],
            }
          : target == r'C:\Projects'
          ? {
              'path': r'C:\Projects',
              'parent': 'C:\\',
              'next': null,
              'entries': [
                {'name': 'app', 'path': path},
              ],
            }
          : {
              'path': path,
              'parent': r'C:\Projects',
              'entries': [],
              'next': null,
            };
    }
    if (method == 'register_project') {
      final request = Map<String, dynamic>.from(params[0] as Map);
      registrations.add(request);
      if (!existing) {
        created.add({
          'projectId': 'p-mobile',
          'displayName': request['displayName'] == ''
              ? 'app'
              : request['displayName'],
          'path': request['path'],
          'additionalDirectories': [],
        });
      }
      if (loseReply) throw const RemoteOutcomeUnknown();
      return {'projectId': existing ? 'p1' : 'p-mobile', 'created': !existing};
    }
    final result = await super.call(method, params);
    if (method == 'bootstrap') {
      final projects = <dynamic>[
        if (!empty) ...(result['projects'] as List),
        ...created,
      ];
      if (existing) projects.first['path'] = path;
      result['projects'] = projects;
    }
    return result;
  }
}

Future<void> chooseDirectory(WidgetTester tester) async {
  await tester.tap(find.text('C 盘'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Projects'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('app'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('edited paths require PC confirmation before adding', (
    tester,
  ) async {
    final link = ProjectLink(empty: true), hub = fakeHub();
    await hub.load(connect: false);
    await hub.attach(hub.hosts.single, link);
    await tester.pumpWidget(DogCodesApp(hub: hub));
    await tester.pumpAndSettle();
    await openNewProject(tester);
    await chooseDirectory(tester);
    await tester.enterText(find.byType(TextField).first, r'C:\Projects\.\app');
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '添加此目录'))
          .onPressed,
      isNull,
    );
    expect(find.text('目录路径已修改，请点箭头或回车确认后再添加。'), findsOneWidget);
    expect(link.registrations, isEmpty);
    await tester.tap(find.byTooltip('前往目录'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      ProjectLink.path,
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '添加此目录'))
          .onPressed,
      isNotNull,
    );
    await tester.pumpWidget(const SizedBox());
    hub.dispose();
  });
  testWidgets(
    'empty workspace browses PC directories and selects the newly registered project',
    (tester) async {
      final link = ProjectLink(empty: true), hub = fakeHub();
      await hub.load(connect: false);
      await hub.attach(hub.hosts.single, link);
      await tester.pumpWidget(DogCodesApp(hub: hub));
      await tester.pumpAndSettle();
      await openNewProject(tester);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '添加此目录'))
            .onPressed,
        isNull,
      );
      await chooseDirectory(tester);
      expect(find.text('当前目录没有子目录，可直接添加此目录。'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, '新增项目');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.tap(find.text('添加此目录'));
      await tester.pumpAndSettle();
      expect(link.registrations.single['path'], ProjectLink.path);
      expect(link.registrations.single['displayName'], '新增项目');
      expect(find.text('新增项目'), findsOneWidget);
      expect(hub.hosts.single.project('p-mobile'), isNotNull);
      await tester.pumpWidget(const SizedBox());
      hub.dispose();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'an existing directory opens its existing project without creating a duplicate',
    (tester) async {
      final link = ProjectLink(existing: true), hub = fakeHub();
      await hub.load(connect: false);
      await hub.attach(hub.hosts.single, link);
      await tester.pumpWidget(DogCodesApp(hub: hub));
      await tester.pumpAndSettle();
      await openNewProject(tester);
      await chooseDirectory(tester);
      expect(find.text('打开已有项目'), findsOneWidget);
      await tester.tap(find.text('打开已有项目'));
      await tester.pumpAndSettle();
      expect(link.created, isEmpty);
      expect(hub.hosts.single.projects.length, 1);
      await tester.pumpWidget(const SizedBox());
      hub.dispose();
    },
  );
  testWidgets(
    'lost add reply can be verified in the page without sending registration again',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(430, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final link = ProjectLink(empty: true, loseReply: true), hub = fakeHub();
      await hub.load(connect: false);
      await hub.attach(hub.hosts.single, link);
      await tester.pumpWidget(DogCodesApp(hub: hub));
      await tester.pumpAndSettle();
      await openNewProject(tester);
      await chooseDirectory(tester);
      await tester.tap(find.text('添加此目录'));
      await tester.pumpAndSettle();
      expect(find.text('添加项目：还没收到电脑确认'), findsOneWidget);
      await tester.ensureVisible(find.text('重新确认'));
      await tester.tap(find.text('重新确认'));
      await tester.pumpAndSettle();
      expect(link.registrations.length, 1);
      expect(hub.hosts.single.pendingOperation, isNull);
      expect(find.text('app'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      hub.dispose();
    },
  );
  testWidgets(
    'new conversation can add a project while preserving its unsent task',
    (tester) async {
      final link = ProjectLink(), hub = fakeHub();
      await hub.load(connect: false);
      await hub.attach(hub.hosts.single, link);
      await tester.pumpWidget(DogCodesApp(hub: hub));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('新会话'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '保留未发送的任务');
      await tester.tap(find.byTooltip('添加项目'));
      await tester.pumpAndSettle();
      await chooseDirectory(tester);
      await tester.tap(find.text('添加此目录'));
      await tester.pumpAndSettle();
      expect(find.text('保留未发送的任务'), findsOneWidget);
      expect(find.text('app'), findsOneWidget);
      expect(link.executed, isEmpty);
      await tester.pumpWidget(const SizedBox());
      hub.dispose();
    },
  );
  testWidgets('an offline computer lists its folders once it connects', (
    tester,
  ) async {
    final link = ProjectLink(empty: true), hub = fakeHub();
    await hub.load(connect: false);
    // Already tried and failed: the gate shows 连接不上, not a fresh attempt.
    hub.hosts.single.connectAttempts = 1;
    await tester.pumpWidget(DogCodesApp(hub: hub));
    await tester.pumpAndSettle();
    // Opened while the computer is offline (e.g. it dropped off afterwards).
    unawaited(
      tester
          .state<NavigatorState>(find.byType(Navigator).first)
          .push(
            MaterialPageRoute<void>(
              builder: (_) => AddProjectPage(hostId: hub.hosts.single.id),
            ),
          ),
    );
    await tester.pumpAndSettle();
    expect(find.text('添加此目录'), findsOneWidget);
    expect(find.text('C 盘'), findsNothing);

    await hub.attach(hub.hosts.single, link);
    await tester.pumpAndSettle();
    expect(find.text('C 盘'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    hub.dispose();
  });
}

/// 项目 tab → project sheet → 新建项目.
Future<void> openNewProject(WidgetTester tester) async {
  await tester.tap(find.text('项目').last);
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('选择项目'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('新建项目').last);
  await tester.pumpAndSettle();
}
