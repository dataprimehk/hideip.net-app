import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hideip_vpn/core/account_service.dart';
import 'package:hideip_vpn/state/app_state.dart';
import 'package:hideip_vpn/ui/redesign/account/account_port.dart';
import 'package:hideip_vpn/ui/redesign/account/account_widgets.dart';
import 'package:hideip_vpn/ui/redesign/account/new_device.dart';
import 'package:hideip_vpn/ui/redesign/account/pairing_port.dart';
import 'package:hideip_vpn/ui/redesign/account_screen.dart';
import 'package:hideip_vpn/ui/redesign/hip.dart';
import 'package:hideip_vpn/ui/redesign/hip_sheet.dart';
import 'package:hideip_vpn/ui/redesign/shell.dart';
import 'package:hideip_vpn/ui/strings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/account_fakes.dart';

/// How the screen is looked at: the theme, the text size and the screen.
enum Look { light, dark, largeSmall }

/// The ten states of the approved 1.2.1 Account design, each set up on the
/// fakes the way the state layer would report it.
final Map<String, void Function(FakeAccountPort a)> states = {
  'store': (a) => a
    ..storeLinked = true
    ..storeName = 'App Store'
    ..hasStoreEntitlement = true
    ..storeEntitlementLive = true
    ..storeRenews = DateTime(2026, 11, 10),
  'number': (a) => a
    ..plansOffered = true
    ..storeName = 'Google Play'
    ..overview = AccountOverview(
      AccountResult.ok,
      devices: sampleDevices(2),
      deviceLimit: 5,
    ),
  'add': (a) => a
    ..storeLinked = true
    ..storeName = 'App Store'
    ..hasStoreEntitlement = true
    ..overview = AccountOverview(
      AccountResult.ok,
      devices: sampleDevices(2),
      deviceLimit: 5,
    ),
  'more': (a) => a
    ..storeLinked = true
    ..storeName = 'App Store'
    ..hasStoreEntitlement = true,
  'outoftime': (a) => a
    ..active = false
    ..premiumOn = false
    ..plansOffered = true
    ..canLinkDevices = false
    ..expires = DateTime(2026, 10, 2)
    ..overview = AccountOverview(
      AccountResult.ok,
      devices: sampleDevices(2),
      deviceLimit: 5,
    ),
  'nonum': (a) => a
    ..numberKnown = false
    ..storeLinked = true
    ..storeName = 'App Store'
    ..hasStoreEntitlement = true,
  'replaced': (a) => a
    ..issue = AccountIssue.numberReplaced
    ..canManage = false,
  'revoked': (a) => a
    ..issue = AccountIssue.revoked
    ..canManage = false
    ..active = false
    ..premiumOn = false,
  'signedout': (a) => a
    ..deviceSignedOut = true
    ..canManage = false
    ..premiumOn = false,
  'form': (a) => a
    ..signedIn = false
    ..lastNumber = null,
};

late AppState _app;

Widget _host(
  FakeAccountPort account,
  FakePairingPort pairing, {
  required Look look,
  GlobalKey<NavigatorState>? sheets,
  List<HipScreen>? paywalls,
  FakeNewDevicePort? newDevice,
}) {
  final large = look == Look.largeSmall;
  return MaterialApp(
    navigatorKey: sheets,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: large ? const TextScaler.linear(1.5) : TextScaler.noScaling,
      ),
      child: child!,
    ),
    home: Scaffold(
      backgroundColor: Hip.surface,
      body: AccountScreen(
        state: _app,
        nav: fakeNav(sheets: sheets, paywalls: paywalls),
        account: account,
        pairing: pairing,
        newDevice: newDevice ?? FakeNewDevicePort(),
      ),
    ),
  );
}

/// A phone-sized surface, or a small one for the large-text pass.
void _screen(WidgetTester tester, Look look) {
  final view = tester.view;
  view.physicalSize = look == Look.largeSmall
      ? const Size(360, 740)
      : const Size(390, 844);
  view.devicePixelRatio = 1;
  addTearDown(view.resetPhysicalSize);
  addTearDown(view.resetDevicePixelRatio);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Finds [text] anywhere in the list, scrolling to it first.
Future<Finder> _seek(WidgetTester tester, String text) async {
  final f = find.text(text);
  await tester.scrollUntilVisible(
    f,
    200,
    scrollable: find.byType(Scrollable).first,
    maxScrolls: 60,
  );
  return f;
}

/// Every piece of text on screen, read out of the widgets.
Iterable<String> _texts(WidgetTester tester) sync* {
  for (final w in tester.widgetList<Text>(find.byType(Text))) {
    final t = w.data ?? w.textSpan?.toPlainText();
    if (t != null) yield t;
  }
  for (final w in tester.widgetList<RichText>(find.byType(RichText))) {
    yield w.text.toPlainText();
  }
}

void _expectCleanCopy(WidgetTester tester) {
  for (final t in _texts(tester)) {
    expect(t.contains('—') || t.contains('–'), isFalse, reason: t);
    for (final word in forbiddenWords) {
      expect(t.toLowerCase().contains(word), isFalse, reason: '$word in $t');
    }
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _app = AppState();
    Hip.reducedMotion = true;
  });

  tearDown(() {
    Hip.reducedMotion = false;
    Hip.dm = false;
  });

  for (final look in Look.values) {
    group('in ${look.name}', () {
      setUp(() => Hip.dm = look == Look.dark);

      testWidgets('01 store: Premium on, devices, number, payment', (
        tester,
      ) async {
        _screen(tester, look);
        final a = FakeAccountPort();
        states['store']!(a);
        await tester.pumpWidget(_host(a, FakePairingPort(), look: look));
        await _settle(tester);

        expect(find.text(S.accountTitle), findsOneWidget);
        expect(find.text(S.accountStatusOn), findsOneWidget);
        expect(find.textContaining('Active until'), findsOneWidget);
        expect(
          find.text(S.accountStatusRenewsThrough('App Store')),
          findsOneWidget,
        );
        expect(
          await _seek(tester, S.accountDevicesCount(3, 5)),
          findsOneWidget,
        );
        expect(await _seek(tester, 'MacBook Air'), findsOneWidget);
        expect(await _seek(tester, S.accountAddDevice), findsOneWidget);
        expect(await _seek(tester, '•••• •••• •••• 0319'), findsOneWidget);
        expect(find.text('8236 3877 8895 0319'), findsNothing);
        expect(await _seek(tester, S.accountNumberNote), findsOneWidget);
        expect(
          await _seek(tester, S.accountPaymentTitle.toUpperCase()),
          findsOneWidget,
        );
        expect(
          find.textContaining('App Store subscription · renews'),
          findsOneWidget,
        );
        expect(await _seek(tester, S.accountMoreOptions), findsOneWidget);
        // The rare actions are folded on the way in.
        expect(find.text(S.accountRotate), findsNothing);
        expect(find.text(S.accountDelete), findsNothing);
        _expectCleanCopy(tester);
      });

      testWidgets('02 number: no store, Subscribe under Payment', (
        tester,
      ) async {
        _screen(tester, look);
        final a = FakeAccountPort();
        states['number']!(a);
        await tester.pumpWidget(_host(a, FakePairingPort(), look: look));
        await _settle(tester);

        expect(find.text(S.accountStatusOn), findsOneWidget);
        expect(find.text(S.accountStatusEndsUnlessAdded), findsOneWidget);
        expect(
          await _seek(tester, S.accountDevicesCount(2, 5)),
          findsOneWidget,
        );
        expect(
          await _seek(tester, S.accountSubscribeStore('Google Play')),
          findsOneWidget,
        );
        expect(find.textContaining('subscription · renews'), findsNothing);
        _expectCleanCopy(tester);
      });

      testWidgets('03 add: one sheet with QR, code and the number', (
        tester,
      ) async {
        _screen(tester, look);
        final a = FakeAccountPort();
        states['add']!(a);
        final sheets = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          _host(
            a,
            FakePairingPort(caps: FakePairingPort.v2),
            look: look,
            sheets: sheets,
          ),
        );
        await _settle(tester);

        await tester.tap(await _seek(tester, S.accountAddDevice));
        await _settle(tester);
        expect(find.byType(HipSheet), findsOneWidget);
        expect(find.text(S.accountScanQr), findsOneWidget);
        expect(find.text(S.accountEnterCode), findsOneWidget);
        expect(find.textContaining(S.accountAddInUse(2, 5)), findsOneWidget);
        expect(find.textContaining(S.accountAddHowV2), findsOneWidget);
        expect(find.text(S.accountOrSignIn.toUpperCase()), findsOneWidget);
        // Masked and large in the sheet too, with Show and Copy.
        expect(find.text('•••• •••• •••• 0319'), findsNWidgets(2));
        expect(
          find.descendant(
            of: find.byType(HipSheet),
            matching: find.text(S.accountNumberShow),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byType(HipSheet),
            matching: find.text(S.accountCopy),
          ),
          findsOneWidget,
        );
        _expectCleanCopy(tester);
      });

      testWidgets('04 more: the rare actions unfold, delete last and red', (
        tester,
      ) async {
        _screen(tester, look);
        final a = FakeAccountPort();
        states['more']!(a);
        await tester.pumpWidget(_host(a, FakePairingPort(), look: look));
        await _settle(tester);

        await tester.tap(await _seek(tester, S.accountMoreOptions));
        await tester.pump();
        expect(await _seek(tester, S.accountRotate), findsOneWidget);
        expect(await _seek(tester, S.accountRotateSub), findsOneWidget);
        expect(await _seek(tester, S.accountSignOut), findsOneWidget);
        final delete = await _seek(tester, S.accountDelete);
        expect(tester.widget<Text>(delete).style?.color, Hip.danger);
        expect(
          tester.getTopLeft(delete).dy,
          greaterThan(tester.getTopLeft(find.text(S.accountSignOut)).dy),
        );
        _expectCleanCopy(tester);
      });

      testWidgets('05 out of time: See plans, quiet Check again, list kept', (
        tester,
      ) async {
        _screen(tester, look);
        final a = FakeAccountPort();
        states['outoftime']!(a);
        final paywalls = <HipScreen>[];
        await tester.pumpWidget(
          _host(a, FakePairingPort(), look: look, paywalls: paywalls),
        );
        await _settle(tester);

        expect(find.text(S.accountStatusOff), findsOneWidget);
        expect(find.textContaining('Ended on'), findsOneWidget);
        expect(find.text(S.accountOutOfTimeNote), findsOneWidget);
        final plans = tester.widget<AccountCta>(
          find.widgetWithText(AccountCta, S.aSeePlans),
        );
        expect(plans.quiet, isFalse);
        final again = tester.widget<AccountCta>(
          find.widgetWithText(AccountCta, S.accountCheckAgain),
        );
        expect(again.quiet, isTrue);
        await tester.tap(find.widgetWithText(AccountCta, S.aSeePlans));
        expect(paywalls, [HipScreen.account]);

        // Devices stay; adding waits for Premium, and says so.
        expect(await _seek(tester, 'Chrome'), findsOneWidget);
        expect(await _seek(tester, S.accountAddDeviceOff), findsOneWidget);
        // No second way to the same paywall.
        expect(find.textContaining('Subscribe with'), findsNothing);
        expect(find.text(S.accountPaymentTitle.toUpperCase()), findsNothing);
        _expectCleanCopy(tester);
      });

      testWidgets('06 no number here: Premium first, a quiet number card', (
        tester,
      ) async {
        _screen(tester, look);
        final a = FakeAccountPort();
        states['nonum']!(a);
        await tester.pumpWidget(_host(a, FakePairingPort(), look: look));
        await _settle(tester);

        expect(find.text(S.accountStatusOn), findsOneWidget);
        expect(await _seek(tester, S.accountNumberNotHere), findsOneWidget);
        expect(find.text(S.accountNumberNotHereNote), findsOneWidget);
        expect(find.textContaining('0319'), findsNothing);
        expect(find.text(S.accountNumberShow), findsNothing);
        expect(await _seek(tester, S.accountEnterNumber), findsOneWidget);
        _expectCleanCopy(tester);
      });

      testWidgets('07 replaced: one action, sign out stays alone', (
        tester,
      ) async {
        _screen(tester, look);
        final a = FakeAccountPort();
        states['replaced']!(a);
        await tester.pumpWidget(_host(a, FakePairingPort(), look: look));
        await _settle(tester);

        expect(find.text(S.accountStatusReplaced), findsOneWidget);
        expect(find.text(S.accountStatusReplacedLine), findsOneWidget);
        expect(find.text(S.accountStatusReplacedStillOn), findsOneWidget);
        expect(
          find.widgetWithText(AccountCta, S.accountCtaSignInNewNumber),
          findsOneWidget,
        );
        expect(find.text(S.accountDevicesTitle.toUpperCase()), findsNothing);
        expect(await _seek(tester, S.accountSignOut), findsOneWidget);
        expect(find.text(S.accountMoreOptions), findsNothing);
        expect(find.text(S.accountRotate), findsNothing);
        expect(find.text(S.accountDelete), findsNothing);
        _expectCleanCopy(tester);
      });

      testWidgets('08 revoked: red, sign in with another number', (
        tester,
      ) async {
        _screen(tester, look);
        final a = FakeAccountPort();
        states['revoked']!(a);
        await tester.pumpWidget(_host(a, FakePairingPort(), look: look));
        await _settle(tester);

        expect(find.text(S.accountStatusRevoked), findsOneWidget);
        expect(find.text(S.accountErrRevoked), findsOneWidget);
        expect(
          find.widgetWithText(AccountCta, S.accountCtaSignInAnotherNumber),
          findsOneWidget,
        );
        // Nothing claims Premium works for a number that does not.
        expect(find.text(S.accountStatusReplacedStillOn), findsNothing);
        expect(find.text(S.accountStatusOn), findsNothing);
        expect(find.text(S.accountDevicesTitle.toUpperCase()), findsNothing);
        expect(find.text(S.accountMoreOptions), findsNothing);
        expect(await _seek(tester, S.accountSignOut), findsOneWidget);
        _expectCleanCopy(tester);
      });

      testWidgets('09 signed out elsewhere: one-tap sign in, number kept', (
        tester,
      ) async {
        _screen(tester, look);
        final a = FakeAccountPort();
        states['signedout']!(a);
        await tester.pumpWidget(_host(a, FakePairingPort(), look: look));
        await _settle(tester);

        expect(find.text(S.accountStatusSignedOut), findsOneWidget);
        expect(find.text(S.accountStatusSignedOutLine), findsOneWidget);
        expect(find.text(S.accountStatusSignedOutKept), findsOneWidget);
        // The success page after it is 1.2.0's own; its large-text pass is
        // not this test's business.
        if (look != Look.largeSmall) {
          await tester.tap(find.widgetWithText(AccountCta, S.accountCtaSignIn));
          await _settle(tester);
          expect(a.signIns, [testNumber]);
        }
        _expectCleanCopy(tester);
      });

      testWidgets('10 form: the code another device approves, then the '
          'number, titled Account', (tester) async {
        _screen(tester, look);
        final a = FakeAccountPort();
        states['form']!(a);
        final device = FakeNewDevicePort.v2();
        await tester.pumpWidget(
          _host(a, FakePairingPort(), look: look, newDevice: device),
        );
        await _settle(tester);

        expect(find.text(S.accountTitle), findsOneWidget);
        // One request, asked for on the way in, shown as a QR code and a
        // short code together.
        expect(device.starts, [false]);
        expect(find.text(S.accountNewDeviceIntro), findsOneWidget);
        expect(find.byType(PairingQr), findsOneWidget);
        expect(find.text('7KQM-3XHP'), findsOneWidget);
        expect(find.text(S.accountNewDeviceWaiting), findsOneWidget);
        // The number and the restore stay as the other ways in.
        expect(await _seek(tester, S.accountHelp), findsOneWidget);
        await _seek(tester, S.accountPaste);
        expect(find.byType(TextField), findsOneWidget);
        expect(find.widgetWithText(HipCta, S.accountCtaSignIn), findsOneWidget);
        expect(await _seek(tester, S.pwRestore), findsOneWidget);
        expect(a.refreshes, 0, reason: 'nothing to ask about yet');
        _expectCleanCopy(tester);
      });
    });
  }

  group('state actions', () {
    testWidgets('replaced: the action signs out first, after asking', (
      tester,
    ) async {
      _screen(tester, Look.light);
      final a = FakeAccountPort();
      states['replaced']!(a);
      final sheets = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        _host(a, FakePairingPort(), look: Look.light, sheets: sheets),
      );
      await _settle(tester);

      await tester.tap(
        find.widgetWithText(AccountCta, S.accountCtaSignInNewNumber),
      );
      await _settle(tester);
      expect(find.text(S.accountSignOutBody), findsOneWidget);
      await tester.tap(find.widgetWithText(AccountCta, S.accountSignOut));
      await _settle(tester);
      expect(a.signOuts, 1);
      // Then the form, empty for the new number.
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('8236 3877 8895 0319'), findsNothing);
    });

    testWidgets('Copy in the add sheet copies the whole number', (
      tester,
    ) async {
      _screen(tester, Look.light);
      final a = FakeAccountPort();
      final sheets = GlobalKey<NavigatorState>();
      String? copied;
      const control = MethodChannel('net.hideip.vpn/control');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(control, (
        call,
      ) async {
        if (call.method == 'setSensitiveClipboard') {
          copied = (call.arguments as Map)['text'] as String?;
          return true;
        }
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          control,
          null,
        ),
      );
      await tester.pumpWidget(
        _host(a, FakePairingPort(), look: Look.light, sheets: sheets),
      );
      await _settle(tester);
      await tester.tap(await _seek(tester, S.accountAddDevice));
      await _settle(tester);
      await tester.tap(
        find.descendant(
          of: find.byType(HipSheet),
          matching: find.text(S.accountCopy),
        ),
      );
      await _settle(tester);
      expect(copied, '8236 3877 8895 0319');
      expect(a.toasts, [S.accountCopied]);
    });

    testWidgets('the device count follows the server limit, not five', (
      tester,
    ) async {
      _screen(tester, Look.light);
      final a = FakeAccountPort()
        ..overview = AccountOverview(
          AccountResult.ok,
          devices: sampleDevices(4),
          deviceLimit: 8,
        );
      await tester.pumpWidget(_host(a, FakePairingPort(), look: Look.light));
      await _settle(tester);
      expect(await _seek(tester, S.accountDevicesCount(4, 8)), findsOneWidget);
      expect(await _seek(tester, 'Living room TV'), findsOneWidget);
      expect(
        find.text(S.accountKindTv),
        findsNothing,
        reason: 'kind is in a span',
      );
      expect(find.textContaining(S.accountKindTv), findsWidgets);
    });

    testWidgets('devices that could not be loaded say so and retry', (
      tester,
    ) async {
      _screen(tester, Look.light);
      final a = FakeAccountPort()..overview = null;
      await tester.pumpWidget(_host(a, FakePairingPort(), look: Look.light));
      await _settle(tester);
      expect(await _seek(tester, S.accountErrNetwork), findsOneWidget);
      a.overview = AccountOverview(
        AccountResult.ok,
        devices: sampleDevices(2),
        deviceLimit: 5,
      );
      await tester.tap(find.text(S.accountErrNetwork));
      await _settle(tester);
      expect(await _seek(tester, S.accountDevicesCount(2, 5)), findsOneWidget);
    });

    testWidgets('an empty device list says so instead of a blank card', (
      tester,
    ) async {
      _screen(tester, Look.light);
      final a = FakeAccountPort()
        ..overview = const AccountOverview(
          AccountResult.ok,
          devices: [],
          deviceLimit: 5,
        );
      await tester.pumpWidget(_host(a, FakePairingPort(), look: Look.light));
      await _settle(tester);
      expect(await _seek(tester, S.accountDevicesEmpty), findsOneWidget);
    });

    testWidgets('without plans on offer, Check again is the one button', (
      tester,
    ) async {
      _screen(tester, Look.light);
      final a = FakeAccountPort();
      states['outoftime']!(a);
      a.plansOffered = false;
      await tester.pumpWidget(_host(a, FakePairingPort(), look: Look.light));
      await _settle(tester);
      expect(find.widgetWithText(AccountCta, S.aSeePlans), findsNothing);
      final again = tester.widget<AccountCta>(
        find.widgetWithText(AccountCta, S.accountCheckAgain),
      );
      expect(again.quiet, isFalse);
      final before = a.refreshes;
      await tester.tap(find.widgetWithText(AccountCta, S.accountCheckAgain));
      await _settle(tester);
      expect(a.refreshes, before + 1);
    });

    testWidgets('replaced without Premium on here claims nothing', (
      tester,
    ) async {
      _screen(tester, Look.light);
      final a = FakeAccountPort();
      states['replaced']!(a);
      a.premiumOn = false;
      await tester.pumpWidget(_host(a, FakePairingPort(), look: Look.light));
      await _settle(tester);
      expect(find.text(S.accountStatusReplaced), findsOneWidget);
      expect(find.text(S.accountStatusReplacedStillOn), findsNothing);
    });

    testWidgets('a pairing port that throws leaves the 1.2.0 rows', (
      tester,
    ) async {
      _screen(tester, Look.light);
      final sheets = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        _host(
          FakeAccountPort(),
          _ThrowingPairing(),
          look: Look.light,
          sheets: sheets,
        ),
      );
      await _settle(tester);
      await tester.tap(await _seek(tester, S.accountAddDevice));
      await _settle(tester);
      expect(find.text(S.accountScanQr), findsOneWidget);
      expect(find.text(S.accountLinkCode), findsOneWidget);
      expect(find.text(S.accountEnterCode), findsNothing);
    });
  });
}

class _ThrowingPairing extends FakePairingPort {
  @override
  Future<PairingCapabilities> capabilities() async =>
      throw StateError('no answer');
}
