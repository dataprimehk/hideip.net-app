import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hideip_vpn/core/account_store.dart';
import 'package:hideip_vpn/core/pairing.dart';
import 'package:hideip_vpn/core/pairing_store.dart';
import 'package:hideip_vpn/core/provisioning.dart';
import 'package:hideip_vpn/state/app_pairing.dart';
import 'package:hideip_vpn/state/app_state.dart';
import 'package:hideip_vpn/ui/redesign/account/new_device.dart';
import 'package:hideip_vpn/ui/redesign/account/pairing_flow.dart';
import 'package:hideip_vpn/ui/redesign/account_screen.dart';
import 'package:hideip_vpn/ui/redesign/hip.dart';
import 'package:hideip_vpn/ui/strings.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/account_fakes.dart';

late AppState _app;

/// The Account screen on a device that is not signed in.
Widget _host(
  FakeNewDevicePort device, {
  FakeAccountPort? account,
  GlobalKey<NavigatorState>? sheets,
}) {
  final a =
      account ??
      (FakeAccountPort()
        ..signedIn = false
        ..lastNumber = null
        ..premiumOn = false);
  return MaterialApp(
    navigatorKey: sheets,
    home: Scaffold(
      body: AccountScreen(
        state: _app,
        nav: fakeNav(sheets: sheets),
        account: a,
        pairing: FakePairingPort(caps: FakePairingPort.v2),
        newDevice: device,
      ),
    ),
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _app = AppState();
    Hip.reducedMotion = true;
  });

  tearDown(() => Hip.reducedMotion = false);

  testWidgets('one request: its QR code and short code show together', (
    tester,
  ) async {
    _phone(tester);
    final device = FakeNewDevicePort.v2();
    await tester.pumpWidget(_host(device));
    await _settle(tester);

    expect(device.starts, [false]);
    final qr = tester.widget<PairingQr>(find.byType(PairingQr));
    expect(qr.data, device.ticket!.qrPayload);
    // The QR names the request and nothing else: no secret, no code, no
    // account number.
    expect(qr.data.contains('secret'), isFalse);
    expect(qr.data.contains('7KQM'), isFalse);
    expect(qr.data.contains(testNumber), isFalse);
    expect(find.text('7KQM-3XHP'), findsOneWidget);
    expect(find.textContaining('Expires in'), findsOneWidget);
    expect(find.text(S.accountNewDeviceWaiting), findsOneWidget);
    // This phone shows its code; it has nothing to scan or approve here.
    expect(find.text(S.accountScanQr), findsNothing);
    expect(find.text(S.accountEnterCode), findsNothing);
    // The other ways in sit under the code.
    expect(find.text(S.accountNewDeviceOrNumber.toUpperCase()), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text(S.pwRestore), findsOneWidget);
  });

  testWidgets('a server without pairing v2 leaves the 1.2.0 sign-in alone', (
    tester,
  ) async {
    _phone(tester);
    final device = FakeNewDevicePort();
    await tester.pumpWidget(_host(device));
    await _settle(tester);

    expect(device.starts, [false]);
    expect(find.byType(PairingQr), findsNothing);
    expect(find.text(S.accountNewDeviceIntro), findsNothing);
    expect(find.text(S.accountNewDeviceOrNumber.toUpperCase()), findsNothing);
    expect(find.text(S.accountHelp), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text(S.pwRestore), findsOneWidget);
  });

  testWidgets('Restore purchases asks the store, and only where there is one', (
    tester,
  ) async {
    _phone(tester);
    final device = FakeNewDevicePort.v2();
    await tester.pumpWidget(_host(device));
    await _settle(tester);
    await tester.tap(find.text(S.pwRestore));
    await _settle(tester);
    expect(device.restores, 1);

    final none = FakeNewDevicePort.v2()..canRestore = false;
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_host(none));
    await _settle(tester);
    expect(find.text(S.pwRestore), findsNothing);
  });

  testWidgets('a code that ran out here offers a new one, the old withdrawn', (
    tester,
  ) async {
    _phone(tester);
    final device = FakeNewDevicePort.v2()
      ..phase = LinkRequestPhase.waiting
      ..ticket = sampleTicket(left: Duration.zero);
    await tester.pumpWidget(_host(device));
    await _settle(tester);

    // Still up on the server as far as this device knows: nothing new was
    // asked for on the way in.
    expect(device.starts, isEmpty);
    expect(find.text(S.accountNewDeviceExpired), findsOneWidget);
    await tester.tap(find.text(S.accountNewDeviceNewCode));
    await _settle(tester);
    expect(device.cancels, 1);
    expect(device.starts, [false]);
    expect(find.textContaining('Expires in'), findsOneWidget);
  });

  testWidgets('how a request ended is said calmly, with a new code (K5)', (
    tester,
  ) async {
    _phone(tester);
    final ends = {
      LinkRequestPhase.expired: S.accountNewDeviceExpired,
      LinkRequestPhase.cancelled: S.accountNewDeviceCancelled,
      LinkRequestPhase.revoked: S.accountNewDeviceRevoked,
      LinkRequestPhase.inactive: S.accountNewDeviceInactive,
      LinkRequestPhase.tooManyAttempts: S.accountErrTooMany,
      LinkRequestPhase.failed: S.accountErrNetwork,
    };
    for (final end in ends.entries) {
      final device = FakeNewDevicePort.v2();
      await tester.pumpWidget(_host(device));
      await _settle(tester);
      device.land(end.key);
      await _settle(tester);
      expect(find.text(end.value), findsOneWidget, reason: end.key.name);
      expect(find.byType(PairingQr), findsNothing, reason: end.key.name);
      // No answer is tried again; anything the server decided gets a new
      // code.
      await tester.tap(
        find.text(
          end.key == LinkRequestPhase.failed
              ? S.aTryAgain
              : S.accountNewDeviceNewCode,
        ),
      );
      await _settle(tester);
      expect(device.starts, [false, false], reason: end.key.name);
      expect(find.byType(PairingQr), findsOneWidget, reason: end.key.name);
      // A different screen before the next round.
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }
  });

  testWidgets('a device with Premium is asked before its code goes up (K10)', (
    tester,
  ) async {
    _phone(tester);
    final sheets = GlobalKey<NavigatorState>();
    final account = FakeAccountPort()
      ..signedIn = false
      ..lastNumber = null
      ..storeName = 'App Store'
      ..hasStoreEntitlement = true;
    final device = FakeNewDevicePort.v2(needsConfirm: true);
    await tester.pumpWidget(_host(device, account: account, sheets: sheets));
    await _settle(tester);

    // Nothing is asked of the server before the user says yes.
    expect(device.starts, isEmpty);
    expect(find.byType(PairingQr), findsNothing);

    await tester.tap(find.text(S.accountNewDeviceShow));
    await _settle(tester);
    expect(find.text(S.accountSwitchTitle), findsOneWidget);
    expect(find.text(S.accountSwitchBodyStore('App Store')), findsOneWidget);
    await tester.tap(find.text(S.aCancel));
    await _settle(tester);
    expect(device.starts, isEmpty);

    await tester.tap(find.text(S.accountNewDeviceShow));
    await _settle(tester);
    await tester.tap(find.text(S.aContinue));
    await _settle(tester);
    expect(device.starts, [true]);
    expect(find.byType(PairingQr), findsOneWidget);
  });

  testWidgets('an approval from the other device ends on the success screen', (
    tester,
  ) async {
    _phone(tester);
    final account = FakeAccountPort()
      ..signedIn = false
      ..lastNumber = null;
    final device = FakeNewDevicePort.v2();
    await tester.pumpWidget(_host(device, account: account));
    await _settle(tester);

    device.land(LinkRequestPhase.storing);
    device.ticket = sampleTicket();
    device.notifyListeners();
    await _settle(tester);
    expect(find.text(S.accountNewDeviceStoring), findsOneWidget);

    account.signedIn = true;
    device.land(LinkRequestPhase.done);
    await _settle(tester);
    expect(find.text(S.pwDoneTitle), findsOneWidget);
    expect(find.text(S.pwDonePaid), findsOneWidget);
    expect(device.clears, 1);
  });

  testWidgets('leaving withdraws a request that is still open', (tester) async {
    _phone(tester);
    final waiting = FakeNewDevicePort.v2();
    await tester.pumpWidget(_host(waiting));
    await _settle(tester);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(waiting.cancels, 1);

    final storing = FakeNewDevicePort.v2();
    await tester.pumpWidget(_host(storing));
    await _settle(tester);
    storing.land(LinkRequestPhase.storing);
    storing.ticket = sampleTicket();
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    // An approval still being confirmed goes too (the state keeps an
    // account already in force); a finished one is left alone.
    expect(storing.cancels, 1);

    final done = FakeNewDevicePort.v2();
    await tester.pumpWidget(_host(done));
    await _settle(tester);
    done.land(LinkRequestPhase.expired);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(done.cancels, 0);
  });

  testWidgets('a confirmation that keeps failing has a way out', (
    tester,
  ) async {
    _phone(tester);
    final device = FakeNewDevicePort.v2();
    await tester.pumpWidget(_host(device));
    await _settle(tester);
    device.land(LinkRequestPhase.storing);
    device.ticket = sampleTicket();
    device.notifyListeners();
    await _settle(tester);

    expect(find.text(S.accountNewDeviceStoring), findsOneWidget);
    await tester.tap(find.text(S.aCancel));
    await _settle(tester);
    expect(device.cancels, 1);
    expect(find.text(S.accountNewDeviceShow), findsOneWidget);
  });

  testWidgets('scrolling the code away keeps the same request', (tester) async {
    tester.view.physicalSize = const Size(360, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final device = FakeNewDevicePort.v2();
    await tester.pumpWidget(_host(device));
    await _settle(tester);
    await tester.scrollUntilVisible(
      find.text(S.pwRestore),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.scrollUntilVisible(
      find.byType(PairingQr),
      -200,
      scrollable: find.byType(Scrollable).first,
    );
    await _settle(tester);
    expect(device.cancels, 0);
    expect(device.starts, [false]);
  });

  test('approving its own request is refused in words that say so', () {
    expect(
      pairingErrorText(PairingError.self, request: true),
      S.accountErrOwnRequest,
    );
    expect(pairingErrorText(PairingError.self), S.accountErrSelf);
  });

  group('on the app state', () {
    late List<http.Request> calls;

    http.Response json(Object body, [int status = 200]) =>
        http.Response(jsonEncode(body), status);

    AppState v2State() => AppState(
      provisioning: ProvisioningService(
        client: MockClient((_) async => http.Response('', 503)),
        catalogSources: [Uri.parse('https://mirror.test/catalog')],
      ),
      pairing: PairingClient(
        client: MockClient((req) async {
          calls.add(req);
          return switch (req.url.path) {
            '/v1/link/capabilities' => json({
              'pairing': 2,
              'kinds': ['phone', 'tablet', 'desktop', 'tv', 'extension'],
              'code_length': 8,
              'link_ttl_s': 600,
              'delivery_ttl_s': 900,
              'features': [
                'preview',
                'ack',
                'cancel',
                'permissions',
                'signout',
              ],
            }),
            '/v1/link/start' => json({
              'link_id': 'L1',
              'poll_secret': 'secret-1',
              'qr_payload': 'hideip://link?v=1&id=L1',
              'code': '4GHJ-KMNP',
              'expires_in': 600,
              'v': 2,
            }),
            '/v1/link/poll' => json({'status': 'pending', 'expires_in': 590}),
            '/v1/link/cancel' => json({'ok': true}),
            _ => http.Response('', 404),
          };
        }),
      ),
      linkPollInterval: null,
      tablet: false,
    );

    Future<void> realSettle(WidgetTester tester) async {
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    setUp(() async {
      calls = [];
      await const AccountStore().clear();
      await const PendingLinkStore().clear();
    });

    testWidgets('the screen shows the code the server gave this device', (
      tester,
    ) async {
      _phone(tester);
      final state = v2State();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AccountScreen(state: state, nav: fakeNav()),
          ),
        ),
      );
      await realSettle(tester);

      expect(state.linkPhase, LinkRequestPhase.waiting);
      expect(find.text('4GHJ-KMNP'), findsOneWidget);
      expect(
        tester.widget<PairingQr>(find.byType(PairingQr)).data,
        'hideip://link?v=1&id=L1',
      );
      final start = calls.firstWhere((r) => r.url.path == '/v1/link/start');
      expect(jsonDecode(start.body)['v'], 2);

      // Leaving takes the request back on the server too.
      await tester.pumpWidget(const SizedBox());
      await realSettle(tester);
      expect(calls.where((r) => r.url.path == '/v1/link/cancel'), hasLength(1));
      expect(state.linkPhase, LinkRequestPhase.idle);
    });
  });
}
