import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hideip_vpn/core/account_service.dart';
import 'package:hideip_vpn/core/camera_permission.dart';
import 'package:hideip_vpn/core/deep_link.dart';
import 'package:hideip_vpn/state/app_pairing.dart';
import 'package:hideip_vpn/state/app_state.dart';
import 'package:hideip_vpn/ui/redesign/account/account_device.dart';
import 'package:hideip_vpn/ui/redesign/account/account_port.dart';
import 'package:hideip_vpn/ui/redesign/account/account_strings.dart';
import 'package:hideip_vpn/ui/redesign/account/account_widgets.dart';
import 'package:hideip_vpn/ui/redesign/account/pairing_flow.dart';
import 'package:hideip_vpn/ui/redesign/account/pairing_port.dart';
import 'package:hideip_vpn/ui/redesign/account_screen.dart';
import 'package:hideip_vpn/ui/redesign/hip.dart';
import 'package:hideip_vpn/ui/redesign/hip_sheet.dart';
import 'package:hideip_vpn/ui/redesign/linked_devices_screen.dart';
import 'package:hideip_vpn/ui/strings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/account_fakes.dart';

late AppState _app;

Widget _account(
  FakeAccountPort account,
  FakePairingPort pairing, {
  required GlobalKey<NavigatorState> sheets,
  ScanQr? scan,
  CamPerm cam = CamPerm.granted,
}) => MaterialApp(
  navigatorKey: sheets,
  home: Scaffold(
    body: AccountScreen(
      state: _app,
      nav: fakeNav(sheets: sheets),
      account: account,
      pairing: pairing,
      scan: scan,
      camStatus: () async => cam,
    ),
  ),
);

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Finder _inSheet(Finder f) =>
    find.descendant(of: find.byType(HipSheet).last, matching: f);

/// Opens Add a device and picks [row] in it.
Future<void> _addVia(WidgetTester tester, String row) async {
  await tester.tap(find.text(SA.addDevice));
  await _settle(tester);
  await tester.tap(_inSheet(find.text(row)));
  await _settle(tester);
}

Future<void> _typeCode(WidgetTester tester, String code) async {
  await tester.enterText(find.byKey(const ValueKey('pairing-code')), code);
  await tester.pump();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _app = AppState();
    Hip.reducedMotion = true;
  });
  tearDown(() => Hip.reducedMotion = false);

  group('K1: what Add a device offers', () {
    for (final caps in [
      PairingCapabilities.unknown,
      PairingCapabilities.legacy,
    ]) {
      testWidgets('pairing ${caps.pairing}: the 1.2.0 rows, no code entry', (
        tester,
      ) async {
        _tall(tester);
        final sheets = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          _account(
            FakeAccountPort(),
            FakePairingPort(caps: caps),
            sheets: sheets,
          ),
        );
        await _settle(tester);
        await tester.tap(find.text(SA.addDevice));
        await _settle(tester);

        expect(_inSheet(find.text(SA.scanQr)), findsOneWidget);
        expect(_inSheet(find.text(S.setLinkedDevicesSub)), findsOneWidget);
        expect(_inSheet(find.text(S.accountLinkCode)), findsOneWidget);
        expect(_inSheet(find.text(SA.enterCode)), findsNothing);
        expect(find.textContaining(SA.addHowV2), findsNothing);
        expect(find.textContaining(SA.addHowLegacy), findsOneWidget);
      });
    }

    testWidgets('a v1 answer with the preview feature is still not v2', (
      tester,
    ) async {
      expect(
        PairingCapabilities.fromJson({
          'pairing': 1,
          'features': ['preview'],
        }).v2,
        isFalse,
      );
      expect(
        PairingCapabilities.fromJson({
          'pairing': 2,
          'features': ['ack'],
        }).v2,
        isFalse,
      );
      expect(PairingCapabilities.fromJson('nonsense').pairing, 0);
    });

    testWidgets('no token to pair with: only the number is offered', (
      tester,
    ) async {
      _tall(tester);
      final sheets = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        _account(
          FakeAccountPort()..canLinkDevices = false,
          FakePairingPort(caps: FakePairingPort.v2),
          sheets: sheets,
        ),
      );
      await _settle(tester);
      await tester.tap(find.text(SA.addDevice));
      await _settle(tester);
      expect(_inSheet(find.text(SA.scanQr)), findsNothing);
      expect(_inSheet(find.text(SA.enterCode)), findsNothing);
      expect(_inSheet(find.text('•••• •••• •••• 0319')), findsOneWidget);
    });

    testWidgets('neither a token nor the number: no Add a device at all', (
      tester,
    ) async {
      _tall(tester);
      await tester.pumpWidget(
        _account(
          FakeAccountPort()
            ..canLinkDevices = false
            ..numberKnown = false,
          FakePairingPort(caps: FakePairingPort.v2),
          sheets: GlobalKey<NavigatorState>(),
        ),
      );
      await _settle(tester);
      expect(find.text(SA.addDevice), findsNothing);
    });

    testWidgets('Show in the sheet asks before the number appears', (
      tester,
    ) async {
      _tall(tester);
      final sheets = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        _account(FakeAccountPort(), FakePairingPort(), sheets: sheets),
      );
      await _settle(tester);
      await tester.tap(find.text(SA.addDevice));
      await _settle(tester);
      await tester.tap(_inSheet(find.text(SA.numberShow)));
      await _settle(tester);
      expect(find.text(S.accountKeepSafe), findsOneWidget);
      expect(find.text('8236 3877 8895 0319'), findsNothing);
      await tester.tap(find.widgetWithText(AccountCta, S.accountReveal));
      await _settle(tester);
      expect(find.text('8236 3877 8895 0319'), findsOneWidget);
    });
  });

  group('P2: the code the new device shows', () {
    testWidgets('typed loosely, it reads as the code and goes to preview', (
      tester,
    ) async {
      _tall(tester);
      final sheets = GlobalKey<NavigatorState>();
      final pairing = FakePairingPort(caps: FakePairingPort.v2);
      await tester.pumpWidget(
        _account(FakeAccountPort(), pairing, sheets: sheets),
      );
      await _settle(tester);
      await _addVia(tester, SA.enterCode);

      expect(find.text(SA.codeBody), findsOneWidget);
      HipCta next() =>
          tester.widget<HipCta>(find.widgetWithText(HipCta, S.aContinue));
      await _typeCode(tester, '7kqm 3x');
      expect(find.text('7KQM-3X'), findsOneWidget);
      expect(next().onTap, isNull);
      await _typeCode(tester, '7kqm 3xhp');
      expect(find.text('7KQM-3XHP'), findsOneWidget);
      expect(next().onTap, isNotNull);

      await tester.tap(find.widgetWithText(HipCta, S.aContinue));
      await _settle(tester);
      expect(pairing.previews.single, (linkId: null, code: '7KQM3XHP'));
      expect(find.text(SA.confirmTitle), findsOneWidget);
    });

    testWidgets('a character no code has is pointed out, nothing is sent', (
      tester,
    ) async {
      _tall(tester);
      final sheets = GlobalKey<NavigatorState>();
      final pairing = FakePairingPort(caps: FakePairingPort.v2);
      await tester.pumpWidget(
        _account(FakeAccountPort(), pairing, sheets: sheets),
      );
      await _settle(tester);
      await _addVia(tester, SA.enterCode);

      await _typeCode(tester, '7KQM-3XH0');
      expect(find.text(SA.codeBadChars), findsOneWidget);
      expect(
        tester.widget<HipCta>(find.widgetWithText(HipCta, S.aContinue)).onTap,
        isNull,
      );
      expect(pairing.previews, isEmpty);
    });

    testWidgets('a code that matches nothing says so and can be fixed', (
      tester,
    ) async {
      _tall(tester);
      final sheets = GlobalKey<NavigatorState>();
      final pairing = FakePairingPort(caps: FakePairingPort.v2)
        ..previewResult = const PairingPreviewResult.failed(
          PairingError.unknownLink,
        );
      await tester.pumpWidget(
        _account(FakeAccountPort(), pairing, sheets: sheets),
      );
      await _settle(tester);
      await _addVia(tester, SA.enterCode);
      await _typeCode(tester, '7KQM3XHP');
      await tester.tap(find.widgetWithText(HipCta, S.aContinue));
      await _settle(tester);

      expect(find.text(SA.errUnknownCode), findsOneWidget);
      expect(find.byKey(const ValueKey('pairing-code')), findsOneWidget);
      // Typing again clears the old answer.
      await _typeCode(tester, '7KQM3XHQ');
      expect(find.text(SA.errUnknownCode), findsNothing);
    });

    testWidgets('too many attempts is said calmly', (tester) async {
      _tall(tester);
      final sheets = GlobalKey<NavigatorState>();
      final pairing = FakePairingPort(caps: FakePairingPort.v2)
        ..previewResult = const PairingPreviewResult.failed(
          PairingError.tooManyAttempts,
        );
      await tester.pumpWidget(
        _account(FakeAccountPort(), pairing, sheets: sheets),
      );
      await _settle(tester);
      await _addVia(tester, SA.enterCode);
      await _typeCode(tester, '7KQM3XHP');
      await tester.tap(find.widgetWithText(HipCta, S.aContinue));
      await _settle(tester);
      expect(find.text(S.accountErrTooMany), findsOneWidget);
    });

    testWidgets('with the camera off, Scan opens the code entry and says why', (
      tester,
    ) async {
      _tall(tester);
      final sheets = GlobalKey<NavigatorState>();
      var scans = 0;
      await tester.pumpWidget(
        _account(
          FakeAccountPort(),
          FakePairingPort(caps: FakePairingPort.v2),
          sheets: sheets,
          cam: CamPerm.denied,
          scan: (_) async {
            scans++;
            return null;
          },
        ),
      );
      await _settle(tester);
      await _addVia(tester, SA.scanQr);
      expect(scans, 0);
      expect(find.text(SA.cameraOff), findsOneWidget);
      expect(find.byKey(const ValueKey('pairing-code')), findsOneWidget);
    });
  });

  group('P5: the device is shown before it is added', () {
    testWidgets('a scanned QR code previews by its id, then one approval', (
      tester,
    ) async {
      _tall(tester);
      final sheets = GlobalKey<NavigatorState>();
      final account = FakeAccountPort();
      final pairing = FakePairingPort(caps: FakePairingPort.v2);
      await tester.pumpWidget(
        _account(
          account,
          pairing,
          sheets: sheets,
          scan: (_) async => 'hideip://link?v=1&id=link_abc',
        ),
      );
      await _settle(tester);
      final before = account.refreshes;
      await _addVia(tester, SA.scanQr);

      expect(pairing.previews.single, (linkId: 'link_abc', code: null));
      expect(pairing.approvals, isEmpty, reason: 'reading approves nothing');
      expect(find.text(SA.confirmTitle), findsOneWidget);
      expect(find.text('Living room TV'), findsWidgets);
      expect(find.textContaining(SA.kindTv), findsWidgets);
      expect(find.text('${SA.kindTv}  ·  Android'), findsOneWidget);
      expect(find.text('7KQM-3XHP'), findsOneWidget);
      expect(find.text(SA.confirmCodeNote), findsOneWidget);
      // A TV only uses Premium: nothing to grant.
      expect(find.text(SA.grantManage), findsNothing);
      expect(find.text(SA.useOnly), findsOneWidget);
      expect(find.text(SA.addInUse(3, 5)), findsOneWidget);
      expect(find.text(SA.expiresIn('06:52')), findsOneWidget);

      await tester.tap(find.widgetWithText(HipCta, SA.approve));
      await _settle(tester);
      expect(pairing.approvals.single, (
        linkId: 'link_abc',
        grantManage: false,
      ));
      expect(find.text(SA.doneTitle), findsOneWidget);
      expect(find.text(SA.doneBody('Living room TV')), findsOneWidget);
      await tester.tap(find.widgetWithText(HipCta, SA.done));
      await _settle(tester);
      expect(account.refreshes, greaterThan(before));
    });

    testWidgets('a phone can be given the account, only when asked', (
      tester,
    ) async {
      _tall(tester);
      final sheets = GlobalKey<NavigatorState>();
      final pairing = FakePairingPort(caps: FakePairingPort.v2)
        ..previewResult = PairingPreviewResult.ok(
          sampleRequest(kind: DeviceKind.phone, name: 'Pixel 9'),
        );
      await tester.pumpWidget(
        _account(FakeAccountPort(), pairing, sheets: sheets),
      );
      await _settle(tester);
      await _addVia(tester, SA.enterCode);
      await _typeCode(tester, '7KQM3XHP');
      await tester.tap(find.widgetWithText(HipCta, S.aContinue));
      await _settle(tester);

      expect(find.text(SA.grantManage), findsOneWidget);
      final toggle = tester.widget<Switch>(find.byType(Switch));
      expect(toggle.value, isFalse, reason: 'use only, unless granted');
      await tester.tap(find.byType(Switch));
      await tester.pump();
      await tester.tap(find.widgetWithText(HipCta, SA.approve));
      await _settle(tester);
      expect(pairing.approvals.single.grantManage, isTrue);
      expect(find.text(SA.doneManage('Living room TV')), findsOneWidget);
    });

    testWidgets('an approval that was already made is a success, once', (
      tester,
    ) async {
      _tall(tester);
      final sheets = GlobalKey<NavigatorState>();
      final pairing = FakePairingPort(caps: FakePairingPort.v2);
      pairing.approveResults.add(
        const PairingApproveResult.ok(
          device: AccountDevice(
            id: 'dev_new',
            kind: DeviceKind.tv,
            name: 'Living room TV',
          ),
          already: true,
        ),
      );
      await tester.pumpWidget(
        _account(
          FakeAccountPort(),
          pairing,
          sheets: sheets,
          scan: (_) async => 'hideip://link?v=1&id=link_abc',
        ),
      );
      await _settle(tester);
      await _addVia(tester, SA.scanQr);
      await tester.tap(find.widgetWithText(HipCta, SA.approve));
      await _settle(tester);
      expect(find.text(SA.doneTitle), findsOneWidget);
      expect(pairing.approvals, hasLength(1));
    });

    testWidgets('an account out of time cannot approve, and is told why', (
      tester,
    ) async {
      _tall(tester);
      final sheets = GlobalKey<NavigatorState>();
      final pairing = FakePairingPort(caps: FakePairingPort.v2)
        ..previewResult = PairingPreviewResult.ok(sampleRequest(active: false));
      await tester.pumpWidget(
        _account(
          FakeAccountPort(),
          pairing,
          sheets: sheets,
          scan: (_) async => 'hideip://link?v=1&id=link_abc',
        ),
      );
      await _settle(tester);
      await _addVia(tester, SA.scanQr);
      expect(find.text(SA.errInactive), findsOneWidget);
      expect(
        tester.widget<HipCta>(find.widgetWithText(HipCta, SA.approve)).onTap,
        isNull,
      );
    });

    testWidgets('a request that runs out on screen stops the approval', (
      tester,
    ) async {
      _tall(tester);
      final sheets = GlobalKey<NavigatorState>();
      final pairing = FakePairingPort(caps: FakePairingPort.v2)
        ..previewResult = PairingPreviewResult.ok(
          sampleRequest(expiresIn: const Duration(seconds: 2)),
        );
      await tester.pumpWidget(
        _account(
          FakeAccountPort(),
          pairing,
          sheets: sheets,
          scan: (_) async => 'hideip://link?v=1&id=link_abc',
        ),
      );
      await _settle(tester);
      await _addVia(tester, SA.scanQr);
      await tester.pump(const Duration(seconds: 3));
      expect(find.text(SA.errExpired), findsOneWidget);
      expect(
        tester.widget<HipCta>(find.widgetWithText(HipCta, SA.approve)).onTap,
        isNull,
      );
    });

    testWidgets('a request gone by approval time ends the sheet calmly', (
      tester,
    ) async {
      _tall(tester);
      final sheets = GlobalKey<NavigatorState>();
      final pairing = FakePairingPort(caps: FakePairingPort.v2);
      pairing.approveResults.add(
        const PairingApproveResult.failed(PairingError.linkCancelled),
      );
      await tester.pumpWidget(
        _account(
          FakeAccountPort(),
          pairing,
          sheets: sheets,
          scan: (_) async => 'hideip://link?v=1&id=link_abc',
        ),
      );
      await _settle(tester);
      await _addVia(tester, SA.scanQr);
      await tester.tap(find.widgetWithText(HipCta, SA.approve));
      await _settle(tester);
      expect(find.text(SA.errCancelled), findsOneWidget);
      expect(find.widgetWithText(HipCta, SA.approve), findsNothing);
      expect(find.widgetWithText(HipCta, S.aClose), findsOneWidget);
    });

    testWidgets('a QR code that is not a pairing code is named as such', (
      tester,
    ) async {
      _tall(tester);
      final sheets = GlobalKey<NavigatorState>();
      final pairing = FakePairingPort(caps: FakePairingPort.v2);
      await tester.pumpWidget(
        _account(
          FakeAccountPort(),
          pairing,
          sheets: sheets,
          scan: (_) async => 'vless://someone@example.com:443',
        ),
      );
      await _settle(tester);
      await _addVia(tester, SA.scanQr);
      expect(find.text(SA.errBadCode), findsOneWidget);
      expect(pairing.previews, isEmpty);
    });
  });

  group('P4: no place left', () {
    testWidgets('one device removed from the sheet, the same request goes on', (
      tester,
    ) async {
      _tall(tester);
      final sheets = GlobalKey<NavigatorState>();
      final pairing = FakePairingPort(caps: FakePairingPort.v2);
      pairing.approveResults.add(
        PairingApproveResult.limit(
          deviceLimit: 5,
          devices: sampleDevices(5, withManage: true),
        ),
      );
      await tester.pumpWidget(
        _account(
          FakeAccountPort(),
          pairing,
          sheets: sheets,
          scan: (_) async => 'hideip://link?v=1&id=link_abc',
        ),
      );
      await _settle(tester);
      await _addVia(tester, SA.scanQr);
      await tester.tap(find.widgetWithText(HipCta, SA.approve));
      await _settle(tester);

      expect(find.text(SA.limitTitle(5)), findsOneWidget);
      expect(find.text(SA.limitBody), findsOneWidget);
      expect(_inSheet(find.text('iPad')), findsOneWidget);
      // This device cannot be taken off from here.
      final removable = _inSheet(find.byIcon(Icons.link_off));
      expect(removable, findsNWidgets(4));

      await tester.tap(removable.last);
      await _settle(tester);
      expect(find.text(S.accountRemoveDevice('iPad')), findsOneWidget);
      await tester.tap(find.widgetWithText(HipCta, S.aRemove));
      await _settle(tester);

      expect(pairing.revokes.single, (id: 'dev_tab', confirm: false));
      expect(pairing.approvals, hasLength(2));
      expect(pairing.approvals.last.linkId, 'link_abc');
      expect(find.text(SA.doneTitle), findsOneWidget);
    });

    testWidgets('the last manager is asked about before it goes', (
      tester,
    ) async {
      _tall(tester);
      final sheets = GlobalKey<NavigatorState>();
      final pairing = FakePairingPort(caps: FakePairingPort.v2);
      pairing.approveResults.add(
        PairingApproveResult.limit(
          deviceLimit: 2,
          devices: sampleDevices(2, withManage: true),
        ),
      );
      pairing.revokeResults.add(
        const DeviceChangeResult.failed(PairingError.lastManager),
      );
      await tester.pumpWidget(
        _account(
          FakeAccountPort(),
          pairing,
          sheets: sheets,
          scan: (_) async => 'hideip://link?v=1&id=link_abc',
        ),
      );
      await _settle(tester);
      await _addVia(tester, SA.scanQr);
      await tester.tap(find.widgetWithText(HipCta, SA.approve));
      await _settle(tester);
      await tester.tap(_inSheet(find.byIcon(Icons.link_off)));
      await _settle(tester);
      await tester.tap(find.widgetWithText(HipCta, S.aRemove));
      await _settle(tester);

      expect(find.text(SA.lastManagerTitle), findsOneWidget);
      expect(find.text(SA.lastManagerBody), findsOneWidget);
      await tester.tap(find.widgetWithText(HipCta, S.aContinue));
      await _settle(tester);
      expect(pairing.revokes, [
        (id: 'dev_chrome', confirm: false),
        (id: 'dev_chrome', confirm: true),
      ]);
      expect(find.text(SA.doneTitle), findsOneWidget);
    });
  });

  group('K7/K8: devices and who manages', () {
    testWidgets('a device opens, and can be given the account', (tester) async {
      _tall(tester);
      final sheets = GlobalKey<NavigatorState>();
      final account = FakeAccountPort()
        ..overview = AccountOverview(
          AccountResult.ok,
          devices: sampleDevices(3, withManage: true),
          deviceLimit: 5,
        );
      final pairing = FakePairingPort(caps: FakePairingPort.v2);
      pairing.manageResults.add(
        const DeviceChangeResult.failed(PairingError.lastManager),
      );
      await tester.pumpWidget(_account(account, pairing, sheets: sheets));
      await _settle(tester);

      await tester.tap(find.text('MacBook Air'));
      await _settle(tester);
      expect(_inSheet(find.text(SA.grantManage)), findsOneWidget);
      expect(_inSheet(find.textContaining('Added')), findsOneWidget);
      expect(_inSheet(find.text(SA.deviceNeverUsed)), findsOneWidget);
      await tester.tap(_inSheet(find.byType(Switch)));
      await _settle(tester);
      // Not really the last one here, but the server said so: asked first.
      expect(find.text(SA.lastManagerTitle), findsOneWidget);
      await tester.tap(find.widgetWithText(HipCta, S.aContinue));
      await _settle(tester);
      expect(pairing.manages, [
        (id: 'dev_mac', manage: true, confirm: false),
        (id: 'dev_mac', manage: true, confirm: true),
      ]);
      expect(
        tester.widget<Switch>(_inSheet(find.byType(Switch))).value,
        isTrue,
      );
    });

    testWidgets('a browser only uses Premium: no switch for it', (
      tester,
    ) async {
      _tall(tester);
      final sheets = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        _account(
          FakeAccountPort(),
          FakePairingPort(caps: FakePairingPort.v2),
          sheets: sheets,
        ),
      );
      await _settle(tester);
      await tester.tap(find.text('Chrome'));
      await _settle(tester);
      expect(_inSheet(find.byType(Switch)), findsNothing);
      expect(_inSheet(find.text(SA.useOnly)), findsOneWidget);
    });

    testWidgets('with v2, removal goes through pairing; without, the account', (
      tester,
    ) async {
      _tall(tester);
      for (final v2 in [true, false]) {
        final sheets = GlobalKey<NavigatorState>();
        final account = FakeAccountPort();
        final pairing = FakePairingPort(
          caps: v2 ? FakePairingPort.v2 : PairingCapabilities.legacy,
        );
        await tester.pumpWidget(_account(account, pairing, sheets: sheets));
        await _settle(tester);
        await tester.tap(find.byIcon(Icons.link_off).first);
        await _settle(tester);
        await tester.tap(find.widgetWithText(AccountCta, S.aRemove));
        await _settle(tester);
        if (v2) {
          expect(pairing.revokes.single.id, 'dev_chrome');
          expect(account.removed, isEmpty);
        } else {
          expect(pairing.revokes, isEmpty);
          expect(account.removed, ['dev_chrome']);
        }
        expect(find.text('Chrome'), findsNothing);
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('without v2 a tap on a device opens nothing', (tester) async {
      _tall(tester);
      final sheets = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        _account(FakeAccountPort(), FakePairingPort(), sheets: sheets),
      );
      await _settle(tester);
      await tester.tap(find.text('MacBook Air'));
      await _settle(tester);
      expect(find.byType(HipSheet), findsNothing);
    });
  });

  group('Linked devices screen', () {
    Widget host(FakePairingPort pairing, {AppState? state}) => MaterialApp(
      home: Scaffold(
        body: LinkedDevicesScreen(
          state: state ?? _app,
          nav: fakeNav(),
          pairing: pairing,
        ),
      ),
    );

    testWidgets('pairing v2: Enter code takes the place of Show a code', (
      tester,
    ) async {
      _tall(tester);
      await tester.pumpWidget(host(FakePairingPort(caps: FakePairingPort.v2)));
      await _settle(tester);
      expect(find.widgetWithText(HipCta, SA.enterCode), findsOneWidget);
      expect(find.text('Show a code instead'), findsNothing);
      expect(find.text(SA.addHowV2), findsOneWidget);
    });

    testWidgets('before v2 the 1.2.0 buttons stay', (tester) async {
      _tall(tester);
      await tester.pumpWidget(host(FakePairingPort()));
      await _settle(tester);
      expect(
        find.widgetWithText(HipCta, 'Show a code instead'),
        findsOneWidget,
      );
      expect(find.widgetWithText(HipCta, SA.enterCode), findsNothing);
    });
  });

  group('the deep link approval', () {
    testWidgets('with v2 it previews the device first', (tester) async {
      final pairing = FakePairingPort(caps: FakePairingPort.v2);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showLinkApprovalSheet(
                  context,
                  state: _app,
                  pairing: const DeepLinkPairing('link_abc'),
                  port: pairing,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await _settle(tester);
      expect(pairing.previews.single.linkId, 'link_abc');
      expect(find.text(SA.confirmTitle), findsOneWidget);
      expect(find.text('Link this device?'), findsNothing);
    });
  });

  group('wire readers', () {
    test('K8 rows: kinds, permissions, this device', () {
      final d = AccountDevice.fromJson({
        'id': 'dev_1',
        'kind': 'tv',
        'name': ' ',
        'created_at': 1760000000,
        'last_seen_at': 1760000500,
        'permissions': {'use': true, 'manage': false},
        'current': true,
      })!;
      expect(d.kind, DeviceKind.tv);
      expect(d.name, SA.deviceUnnamed);
      expect(d.manage, isFalse);
      expect(d.current, isTrue);
      expect(d.lastSeenAt, isNotNull);
      expect(AccountDevice.fromJson({'kind': 'phone'}), isNull);
      expect(deviceKindOf('fridge'), DeviceKind.unknown);
      expect(AccountDevice.fromJson({'id': 'x'})!.manage, isNull);
    });

    test('K3 preview body', () {
      final r = PairingRequest.fromJson({
        'link_id': 'L',
        'code': '7KQM-3XHP',
        'device': {
          'kind': 'tv',
          'name': 'Living room TV',
          'platform': 'android',
        },
        'expires_in': 412,
        'state': 'pending',
        'can_grant_manage': false,
        'account': {'active': true, 'devices_used': 3, 'device_limit': 5},
      })!;
      expect(r.device.kind, DeviceKind.tv);
      expect(r.device.platform, 'android');
      expect(r.expiresIn, const Duration(seconds: 412));
      expect(r.devicesUsed, 3);
      expect(r.deviceLimit, 5);
      expect(PairingRequest.fromJson({'code': 'x'}), isNull);
    });

    test('statuses and details map onto the contract errors', () {
      expect(pairingErrorOf(200, null), isNull);
      expect(pairingErrorOf(401, 'unauthorized'), PairingError.unauthorized);
      expect(pairingErrorOf(403, 'not_permitted'), PairingError.notPermitted);
      expect(
        pairingErrorOf(403, 'subscription_inactive'),
        PairingError.subscriptionInactive,
      );
      expect(
        pairingErrorOf(403, 'account_revoked'),
        PairingError.accountRevoked,
      );
      expect(pairingErrorOf(404, 'unknown_link'), PairingError.unknownLink);
      expect(pairingErrorOf(400, 'bad_code'), PairingError.badCode);
      expect(
        pairingErrorOf(409, 'device_limit_reached'),
        PairingError.deviceLimitReached,
      );
      expect(pairingErrorOf(409, 'last_manager'), PairingError.lastManager);
      expect(pairingErrorOf(410, 'link_expired'), PairingError.linkExpired);
      expect(pairingErrorOf(410, 'link_cancelled'), PairingError.linkCancelled);
      expect(
        pairingErrorOf(400, 'not_allowed_for_kind'),
        PairingError.notAllowedForKind,
      );
      expect(pairingErrorOf(400, 'self'), PairingError.self);
      expect(
        pairingErrorOf(429, 'too_many_attempts'),
        PairingError.tooManyAttempts,
      );
      expect(pairingErrorOf(500, null), PairingError.network);
    });

    test('codes: normalized, checked against the alphabet, shown grouped', () {
      expect(normalizePairingCode(' 7kqm-3x hp '), '7KQM3XHP');
      expect(pairingCodeCharsValid('7KQM3XHP'), isTrue);
      for (final c in ['0', '1', 'I', 'O']) {
        expect(pairingCodeCharsValid('7KQM3XH$c'), isFalse, reason: c);
      }
      expect(displayPairingCode('7KQM3XHP'), '7KQM-3XHP');
    });

    test('the legacy port offers nothing of v2', () async {
      final port = LegacyPairingPort(_app);
      expect((await port.capabilities()).v2, isFalse);
      expect(
        (await port.preview(code: '7KQM3XHP')).error,
        PairingError.unsupported,
      );
      expect(
        (await port.approve(linkId: 'L', grantManage: true)).error,
        PairingError.unsupported,
      );
      expect(
        (await port.setManage('d', manage: true)).error,
        PairingError.unsupported,
      );
      expect(await port.devices(), isNull, reason: 'no token, no list');
    });

    test('without a host, the screens read AppState through adapters', () {
      expect(accountPortOf(_app), isA<AppStateAccountPort>());
      expect(pairingPortOf(_app), isA<AppPairingPort>());
    });
  });

  test('the account sources carry no em or en dash', () {
    final files = [
      ...Directory(
        'lib/ui/redesign/account',
      ).listSync().whereType<File>().map((f) => f.path),
      'lib/ui/redesign/account_screen.dart',
      'lib/ui/redesign/linked_devices_screen.dart',
    ];
    for (final path in files) {
      final text = File(path).readAsStringSync();
      expect(text.contains('—'), isFalse, reason: path);
      expect(text.contains('–'), isFalse, reason: path);
    }
  });
}
