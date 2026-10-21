import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:dogcodes_app/core/host_api.dart';
import 'package:dogcodes_app/core/turn_changes.dart';
import 'package:dogcodes_app/features/conversation/turn_files.dart';
import 'package:dogcodes_app/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

String hex(String s) =>
    utf8.encode(s).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Map<String, dynamic> root(String id, String path, List<String> files) => {
  'root': {'id': id, 'path': path, 'git': true},
  'files': [
    for (final f in files) {'path': f},
  ],
  'untracked': <String>[],
};

/// PC double: one artifact, a Git index, and the review operations used.
class FakePc implements HostApi {
  FakePc(this.artifact);
  final Map<String, dynamic> artifact;
  final index = <String>{'already.txt'};
  final calls = <String>[];
  Map<String, dynamic>? committed;

  List<int> get bytes => utf8.encode(jsonEncode(artifact));
  Map<String, dynamic> get meta => {
    'artifactId': 'art_1',
    'payloadSha256': sha256.convert(bytes).toString(),
    'byteLength': bytes.length,
  };

  @override
  Future<dynamic> call(String method, dynamic params) async {
    if (method == 'read_artifact') {
      final r = params[1] as Map;
      final offset = r['offset'] as int;
      final end = (offset + 32768).clamp(0, bytes.length);
      return {
        'offset': offset,
        'bytes': bytes.sublist(offset, end),
        'nextOffset': end < bytes.length ? end : null,
      };
    }
    final op = params['operation'] as String;
    final a = params['arguments'] as Map;
    calls.add(op);
    switch (op) {
      case 'query':
        return a['mode'] == 'staged'
            ? {
                'id': 'staged-${index.length}',
                'roots': [
                  root('r1', '/repo', [...index]),
                ],
              }
            : {
                'id': 'u1',
                'roots': [
                  root('r1', '/repo', [
                    'a.ts',
                    'b.ts',
                    'other.ts',
                    'already.txt',
                  ]),
                ],
              };
      case 'index':
        for (final p in a['paths'] as List) {
          a['action'] == 'stage' ? index.add('$p') : index.remove('$p');
        }
        return null;
      case 'commit_summary':
        return 'feat: update a and b\n';
      case 'git_action':
        committed = Map<String, dynamic>.from(a);
        return true;
    }
    return null;
  }
}

final artifact = {
  'schemaVersion': 1,
  'files': [
    {
      'path': 'a.ts',
      'status': 'M',
      'before': {'kind': 'file', 'hex': hex('one\ntwo\n')},
      'after': {'kind': 'file', 'hex': hex('one\n2\nthree\n')},
    },
    {
      'path': 'b.ts',
      'status': 'A',
      'before': null,
      'after': {'kind': 'file', 'hex': hex('new\n')},
    },
  ],
  'workspacePaths': ['/repo'],
};

Widget host(FakePc pc, Widget child) => MaterialApp(
  theme: dcTheme(Brightness.light),
  home: Scaffold(
    body: TurnScope(
      link: pc,
      taskId: 't1',
      executor: const {'providerId': 'claude-code', 'installationId': 'i1'},
      child: child,
    ),
  ),
);

void main() {
  test('parses v1/v2 artifacts with line counts and commit targets', () {
    final v1 = TurnChanges.parse(artifact);
    expect(v1.files.map((f) => f.absolute), ['/repo/a.ts', '/repo/b.ts']);
    expect((v1.additions, v1.deletions), (3, 1));
    expect(
      v1
          .commitTargets({
            'roots': [
              root('r1', '/repo', ['a.ts', 'x.ts']),
            ],
          })
          .single
          .paths,
      ['a.ts'],
    );
    final v2 = TurnChanges.parse({
      'schemaVersion': 2,
      'files': [
        {
          'path': '/w/one/a.md',
          'workspacePath': '/w/one',
          'relativePath': 'a.md',
          'status': 'A',
        },
        {
          'path': '/w/two/b.md',
          'workspacePath': '/w/two',
          'relativePath': 'b.md',
          'status': 'A',
        },
      ],
      'workspacePaths': ['/w/one', '/w/two'],
    });
    expect(v2.files.map((f) => f.display), ['one/a.md', 'two/b.md']);
    final targets = v2.commitTargets({
      'roots': [
        root('r1', '/w/one', ['a.md']),
        root('r2', '/w/two', ['b.md']),
      ],
    });
    expect(targets.map((t) => t.rootId), ['r1', 'r2']);
  });

  testWidgets('summary shows files and commits only this turn', (tester) async {
    final pc = FakePc(artifact);
    await tester.pumpWidget(host(pc, TurnFilesCard(metadata: pc.meta)));
    await tester.pumpAndSettle();
    expect(find.text('2 个文件已更改'), findsOneWidget);
    expect(find.text('+3'), findsOneWidget);
    await tester.tap(find.text('2 个文件已更改'));
    await tester.pumpAndSettle();
    expect(find.text('a.ts'), findsOneWidget);

    await tester.tap(find.text('提交'));
    await tester.pumpAndSettle();
    expect(pc.index, {'already.txt', 'a.ts', 'b.ts'});
    expect(find.text('feat: update a and b'), findsOneWidget);
    expect(find.textContaining('其中 1 个是此前已暂存的其他更改'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, '提交'));
    await tester.pumpAndSettle();
    expect(pc.committed, containsPair('stageAll', false));
    expect(pc.committed, containsPair('snapshotId', 'staged-3'));
    expect(pc.committed, containsPair('message', 'feat: update a and b'));
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.text('已提交'), findsOneWidget);
  });

  testWidgets('closing without committing unstages what it staged', (
    tester,
  ) async {
    final pc = FakePc(artifact);
    await tester.pumpWidget(host(pc, TurnFilesCard(metadata: pc.meta)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('提交'));
    await tester.pumpAndSettle();
    expect(pc.index, contains('a.ts'));
    Navigator.of(tester.element(find.text('提交本轮修改'))).pop();
    await tester.pumpAndSettle();
    expect(pc.index, {'already.txt'});
    expect(pc.committed, isNull);
  });

  testWidgets('a turn without file changes renders nothing', (tester) async {
    final pc = FakePc({
      'files': [],
      'workspacePaths': ['/repo'],
    });
    await tester.pumpWidget(host(pc, TurnFilesCard(metadata: pc.meta)));
    await tester.pumpAndSettle();
    expect(find.textContaining('文件'), findsNothing);
  });
}
