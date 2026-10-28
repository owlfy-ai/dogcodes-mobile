import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/core/mobile_runtime.dart';
import 'package:dogcodes_app/core/host_api.dart';
import 'package:dogcodes_app/core/protocol.dart';
import 'package:dogcodes_app/core/security/pairing_recovery.dart';
import 'package:dogcodes_app/features/devices/pairing_page.dart';
import 'package:dogcodes_app/ui/theme.dart';

import 'pairing_recovery_test.dart' show MemorySecrets, invitation, phoneKey;

class OfflineRuntime extends MobileRuntime {
  OfflineRuntime(MemorySecrets storage) : super(storage: storage);
  int recoveries = 0;
  @override
  Future<HostLink> recoverPairing(PairingRecovery original) async {
    recoveries++;
    throw const ProtocolException('电脑暂时离线，请稍后核实。');
  }
}

void main() {
  testWidgets(
    'restarted pairing page exposes the original receipt and retains it while offline',
    (t) async {
      final storage = MemorySecrets(),
          original = PairingRecovery.fromInvitation(
            invitation(),
            phoneKey,
            bindingEpoch: testEpoch,
          );
      await PairingJournal(storage).begin(original);
      final runtime = OfflineRuntime(storage);
      await t.pumpWidget(
        MaterialApp(
          theme: dcTheme(Brightness.light),
          home: PairingPage(trustedService: original.service, runtime: runtime),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('配对结果待核实'), findsOneWidget);
      await t.tap(find.text('核实原配对'));
      await t.pumpAndSettle();
      expect(runtime.recoveries, 1);
      expect(find.text('电脑暂时离线，请稍后核实。'), findsOneWidget);
      expect(
        (await runtime.pairingJournal.list()).single.sameAttempt(original),
        isTrue,
      );
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'removing a local record explains that PC authorization may remain',
    (t) async {
      final storage = MemorySecrets(),
          original = PairingRecovery.fromInvitation(
            invitation(),
            phoneKey,
            bindingEpoch: testEpoch,
          );
      await PairingJournal(storage).begin(original);
      final runtime = OfflineRuntime(storage);
      await t.pumpWidget(
        MaterialApp(
          theme: dcTheme(Brightness.light),
          home: PairingPage(trustedService: original.service, runtime: runtime),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('移除本机记录'));
      await t.pumpAndSettle();
      expect(find.textContaining('电脑上可能已允许这台手机'), findsOneWidget);
      await t.tap(find.text('移除本机记录').last);
      await t.pumpAndSettle();
      expect(await runtime.pairingJournal.list(), isEmpty);
      expect(runtime.recoveries, 0);
      expect(find.text('配对结果待核实'), findsNothing);
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'expired pairing recovery offers rescan instead of new authorization',
    (t) async {
      final storage = MemorySecrets(),
          original = PairingRecovery.fromInvitation(
            invitation(),
            phoneKey,
            bindingEpoch: testEpoch,
          );
      final expired = PairingRecovery.fromJson({
        ...original.toJson(),
        'recoverUntil': '2020-01-01T00:00:00Z',
      }, allowLocalDevelopment: false);
      await PairingJournal(storage).begin(expired);
      final runtime = OfflineRuntime(storage);
      await t.pumpWidget(
        MaterialApp(
          theme: dcTheme(Brightness.light),
          home: PairingPage(trustedService: original.service, runtime: runtime),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('恢复期限已过，请在电脑核实授权后重新扫码。'), findsOneWidget);
      expect(
        t
            .widget<TextButton>(find.widgetWithText(TextButton, '核实原配对'))
            .onPressed,
        isNull,
      );
      expect(runtime.recoveries, 0);
      await t.pumpWidget(const SizedBox());
    },
  );
}

const testEpoch = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
