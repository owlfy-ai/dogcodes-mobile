import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/features/conversation/agent_picker.dart';
import 'timeline_paging_widget_test.dart' show PagedLink, openTurn;

/// A computer whose Claude Code offers three permission modes.
class PolicyLink extends PagedLink {
  final sent = <Map>[];
  @override
  Future<dynamic> call(String method, dynamic params) async {
    if (method == 'permission_catalog') {
      return {
        'defaultModeId': 'default',
        'modes': [
          {
            'id': 'default',
            'label': '默认',
            'description': '',
            'dangerous': false,
          },
          {
            'id': 'acceptEdits',
            'label': '接受编辑',
            'description': '',
            'dangerous': false,
          },
          {'id': 'plan', 'label': '计划', 'description': '', 'dangerous': false},
        ],
      };
    }
    if (method == 'submission_intents' && params['type'] == 'start') {
      sent.add(Map.of(params as Map));
    }
    return super.call(method, params);
  }
}

void main() {
  testWidgets('the permission policy is chosen in the agent sheet and sent '
      'with the next turn', (tester) async {
    final link = PolicyLink();
    final hub = await openTurn(tester, link);
    await tester.tap(find.byType(AgentChips));
    await tester.pumpAndSettle();
    expect(find.text('权限策略'), findsOneWidget);
    // The default mode, named as on the desktop.
    expect(find.text('操作前确认'), findsOneWidget);

    await tester.tap(find.text('操作前确认'));
    await tester.pumpAndSettle();
    expect(find.text('编辑文件和其他受保护操作前请求审批。'), findsOneWidget);
    expect(find.text('所选策略在下一轮执行时生效'), findsOneWidget);
    await tester.tap(find.text('计划模式'));
    await tester.pumpAndSettle();
    expect(find.text('计划模式'), findsOneWidget);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '先出方案');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    expect(link.sent.single['input']['permissionMode'], 'plan');

    await tester.pumpWidget(const SizedBox());
    hub.dispose();
  });
}
