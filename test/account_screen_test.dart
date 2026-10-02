import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hideip_vpn/core/account_service.dart';
import 'package:hideip_vpn/core/account_store.dart';
import 'package:hideip_vpn/core/provisioning.dart';
import 'package:hideip_vpn/core/secret_prefs.dart';
import 'package:hideip_vpn/state/app_state.dart';
import 'package:hideip_vpn/ui/redesign/account_screen.dart';
import 'package:hideip_vpn/ui/redesign/hip.dart';
import 'package:hideip_vpn/ui/redesign/hip_sheet.dart';
import 'package:hideip_vpn/ui/redesign/paywall_screen.dart'
    show openStoreSubscriptions;
import 'package:hideip_vpn/ui/redesign/shell.dart';
import 'package:hideip_vpn/ui/strings.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _number = '8236387788950319';

/// Words that would point a user to a purchase outside the stores.
const _forbidden = [
  't.me',
  'telegram',
  'stars',
  'stripe',
  'crypto',
  'bitcoin',
  'monero',
  'usdt',
  'hideip.net/premium',
  'buy online',
  'checkout',
  'discount',
  'cheaper',
  'redeem',
  'license key',
  'promo code',
  'coupon',
  'voucher',
];

/// With [sheets], sheets really open (on that navigator); without, they
/// close at once with nothing chosen.
HipNav _nav({List<HipScreen>? went, GlobalKey<NavigatorState>? sheets}) => HipNav(
  go: (s, [_]) => went?.add(s),
  back: () {},
  ctx: () => null,
  showSheet: <T>(List<Widget> children) async => sheets == null
      ? null
      : showHipSheet<T>(sheets.currentContext!, children: children),
  openDetail: (_) {},
  openImport: () {},
  openImportWith: (_) {},
  openPaywall: ({required HipScreen from, String? locId}) {},
  claimBack: (_) {},
  releaseBack: (_) {},
);

/// The account API, counting every call. Nothing is served at the
/// subscription URL, so no server rows (and no latency probes) appear.
class _Backend {
  int calls = 0;
  bool active = true;
  List<String> devices = ['dev_abc', 'dev_two'];

  http.Client get client => MockClient((req) async {
    calls++;
    final ms = DateTime.now()
        .add(Duration(days: active ? 30 : -3))
        .millisecondsSinceEpoch;
    if (req.url.path == '/v1/account/signin') {
      return http.Response(
        jsonEncode({
          'active': active,
          'expires_ms': ms,
          'subscription_url': active ? 'https://api.test/v1/sub/dev_abc' : null,
          'device': active
              ? {'id': 'dev_abc', 'kind': 'phone', 'name': 'Android phone'}
              : null,
          'device_token': active ? 'k9Q-token' : null,
          'device_limit': 5,
        }),
        200,
      );
    }
    if (req.url.path == '/v1/account/status') {
      return http.Response(
        jsonEncode({
          'active': active,
          'expires_ms': ms,
          'kind': 'monthly',
          'devices': [
            for (final id in devices)
              {
                'id': id,
                'kind': id == 'dev_abc' ? 'phone' : 'desktop',
                'name': id == 'dev_abc' ? 'Android phone' : 'Desktop',
                'created_at': 1756800000,
              },
          ],
          'device_limit': 5,
        }),
        200,
      );
    }
    return http.Response('', 404);
  });
}

AppState _state(_Backend backend) => AppState(
  accounts: AccountService(client: backend.client),
  provisioning: ProvisioningService(
    client: MockClient((_) async => http.Response('', 503)),
    catalogSources: [Uri.parse('https://mirror.test/catalog')],
  ),
);

Widget _host(
  AppState state, {
  List<HipScreen>? went,
  GlobalKey<NavigatorState>? sheets,
}) => MaterialApp(
  navigatorKey: sheets,
  home: Scaffold(
    body: AccountScreen(
      state: state,
      nav: _nav(went: went, sheets: sheets),
    ),
  ),
);

/// The account v2 surface, set by hand: what the state layer would say
/// about the store and the number.
class _V2State extends AppState {
  _V2State(_Backend backend)
    : super(
        accounts: AccountService(client: backend.client),
        provisioning: ProvisioningService(
          client: MockClient((_) async => http.Response('', 503)),
          catalogSources: [Uri.parse('https://mirror.test/catalog')],
        ),
      );

  bool linked = false;
  String? store;
  DateTime? renews;
  String? fresh;
  int acks = 0;
  bool elsewhere = false;
  bool numberKnown = true;
  bool storeBought = false;
  AccountResult deleteResult = AccountResult.ok;
  int deletes = 0;

  @override
  bool get storeLinked => linked;
  @override
  String? get storeName => store;
  @override
  DateTime? get storeRenews => renews;
  @override
  String? get freshAccountNumber => fresh;
  @override
  void ackFreshAccountNumber() {
    acks++;
    fresh = null;
    notifyListeners();
  }

  @override
  bool get storeLinkedElsewhere => elsewhere;
  @override
  String? get accountNumber => numberKnown ? super.accountNumber : null;
  @override
  bool get accountNumberKnown => numberKnown && super.accountNumberKnown;
  @override
  bool get hasStoreEntitlement => storeBought || super.hasStoreEntitlement;
  @override
  Future<AccountResult> deleteAccountNumber() async {
    deletes++;
    if (deleteResult == AccountResult.ok) await signOutAccount();
    return deleteResult;
  }
}

/// A [_V2State] signed in to the test number.
Future<_V2State> _v2SignedIn(WidgetTester tester, _Backend backend) async {
  final state = _V2State(backend);
  await tester.pumpWidget(const SizedBox());
  unawaited(state.signInWithAccountNumber(_number));
  await _settle(tester);
  expect(state.accountSignedIn, isTrue);
  return state;
}

/// A tall surface, so the whole account screen is built at once.
void _tall(WidgetTester tester) {
  final view = tester.view;
  view.physicalSize = const Size(1000, 3200);
  view.devicePixelRatio = 1;
  addTearDown(view.resetPhysicalSize);
  addTearDown(view.resetDevicePixelRatio);
}

HipCta _signInButton(WidgetTester tester) =>
    tester.widget<HipCta>(find.widgetWithText(HipCta, S.accountCtaSignIn));

/// Lets the sign-in and status calls finish. They run partly on real async
/// (encrypted storage) and partly on the test clock, so both are advanced
/// in turn; a spinner on screen would keep pumpAndSettle from returning.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Opens or closes a dialog: its route animates for a moment.
Future<void> _dialog(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void _expectNoForbiddenWords() {
  for (final word in _forbidden) {
    expect(
      find.textContaining(RegExp(RegExp.escape(word), caseSensitive: false)),
      findsNothing,
      reason: word,
    );
  }
}

void main() {
  group('accountFieldFontSize', () {
    test('keeps 24 when the whole number fits at default text size', () {
      expect(accountFieldFontSize(340, TextScaler.noScaling), 24);
    });

    test('shrinks so all 19 characters fit on a zoomed screen', () {
      // Display Zoom plus a larger text setting: narrow field, scaled text.
      const scaler = TextScaler.linear(1.2);
      const width = 290.0;
      final size = accountFieldFontSize(width, scaler);
      expect(size, lessThan(24));
      expect(19 * (.6 * scaler.scale(size) + 1) + 4, lessThanOrEqualTo(width));
    });

    test('never goes below 14', () {
      expect(accountFieldFontSize(120, const TextScaler.linear(2)), 14);
    });
  });

  late _Backend backend;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // A fresh vault also drops the per-key gates: work a previous test left
    // on its own clock must not queue this one behind it.
    SecretPrefs.installKeyVaultForTesting(MemorySecureKeyVault());
    await PremiumSub.clear();
    await const AccountStore().clear();
    backend = _Backend();
    Hip.reducedMotion = true;
  });

  tearDown(() => Hip.reducedMotion = false);

  testWidgets('the button waits for sixteen digits that pass the check', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_state(backend)));

    expect(find.text(S.accountNumberTitle), findsOneWidget);
    expect(find.text(S.accountHelp), findsOneWidget);
    expect(_signInButton(tester).onTap, isNull);

    await tester.enterText(find.byType(TextField), '8236 3877 8895 031');
    await tester.pump();
    expect(_signInButton(tester).onTap, isNull);
    expect(
      find.text(S.accountErrInvalid),
      findsNothing,
      reason: 'fifteen digits is unfinished, not wrong',
    );

    await tester.enterText(find.byType(TextField), _number);
    await tester.pump();
    expect(
      find.text('8236 3877 8895 0319'),
      findsOneWidget,
      reason: 'the field groups by four',
    );
    expect(_signInButton(tester).onTap, isNotNull);
  });

  testWidgets('a failed check digit is said here, with no call made', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_state(backend)));

    await tester.enterText(find.byType(TextField), '1234567890123456');
    await tester.pump();

    expect(find.text(S.accountErrInvalid), findsOneWidget);
    expect(_signInButton(tester).onTap, isNull);
    await tester.tap(find.widgetWithText(HipCta, S.accountCtaSignIn));
    await tester.pump();
    expect(backend.calls, 0);
  });

  testWidgets('a sign-in that goes through ends on the purchase success', (
    tester,
  ) async {
    final went = <HipScreen>[];
    await tester.pumpWidget(_host(_state(backend), went: went));

    await tester.enterText(find.byType(TextField), _number);
    await tester.pump();
    await tester.tap(find.widgetWithText(HipCta, S.accountCtaSignIn));
    await _settle(tester);

    expect(find.text(S.pwDoneTitle), findsOneWidget);
    expect(find.text(S.pwDonePaid), findsOneWidget);
    _expectNoForbiddenWords();

    await tester.tap(find.text(S.pwDoneCta));
    expect(went, [HipScreen.home]);
    // The status call that follows a sign-in finishes inside this test.
    await _settle(tester);
  });

  testWidgets('signed in, the number is masked and showing it asks first', (
    tester,
  ) async {
    _tall(tester);
    final state = _state(backend);
    await tester.pumpWidget(const SizedBox());
    unawaited(state.signInWithAccountNumber(_number));
    await _settle(tester);
    expect(state.accountSignedIn, isTrue);
    await tester.pumpWidget(_host(state, sheets: GlobalKey<NavigatorState>()));
    await _settle(tester);

    expect(find.text('•••• •••• •••• 0319'), findsOneWidget);
    expect(find.text('8236 3877 8895 0319'), findsNothing);
    expect(find.textContaining('Active until'), findsOneWidget);
    // This device is marked, the other one can be taken off.
    expect(find.text(S.accountThisDevice), findsOneWidget);
    expect(find.text(S.accountRotate), findsOneWidget);
    expect(find.text(S.accountSignOut), findsOneWidget);
    _expectNoForbiddenWords();

    await tester.tap(find.text(S.accountReveal));
    await _dialog(tester);
    expect(find.byType(HipSheet), findsOneWidget);
    expect(
      find.text('8236 3877 8895 0319'),
      findsNothing,
      reason: 'nothing shows before the warning is confirmed',
    );

    await tester.tap(find.widgetWithText(HipCta, S.aCancel));
    await _dialog(tester);
    expect(find.text('8236 3877 8895 0319'), findsNothing);

    await tester.tap(find.text(S.accountReveal));
    await _dialog(tester);
    await tester.tap(find.widgetWithText(HipCta, S.accountReveal));
    await _dialog(tester);
    expect(find.text('8236 3877 8895 0319'), findsOneWidget);
    expect(find.text(S.accountHide), findsOneWidget);

    await tester.tap(find.text(S.accountHide));
    await tester.pump();
    expect(find.text('•••• •••• •••• 0319'), findsOneWidget);
  });

  testWidgets('an account out of time says so, and keeps the number', (
    tester,
  ) async {
    backend.active = false;
    final state = _state(backend);
    await tester.pumpWidget(const SizedBox());
    unawaited(state.signInWithAccountNumber(_number));
    await _settle(tester);
    expect(state.accountSignedIn, isTrue);
    await tester.pumpWidget(_host(state));
    await _settle(tester);

    expect(find.text('•••• •••• •••• 0319'), findsOneWidget);
    expect(find.text(S.accountOutOfTime), findsOneWidget);
  });

  testWidgets('out of time, the screen offers a way forward', (tester) async {
    backend.active = false;
    final state = _state(backend);
    await tester.pumpWidget(const SizedBox());
    unawaited(state.signInWithAccountNumber(_number));
    await _settle(tester);
    await tester.pumpWidget(_host(state));
    await _settle(tester);

    expect(find.text(S.accountOutOfTimeNote), findsOneWidget);
    expect(find.widgetWithText(HipCta, S.accountCheckAgain), findsOneWidget);
    // No store catalog in a test: no plans to point at, so no dead button.
    expect(find.widgetWithText(HipCta, S.aSeePlans), findsNothing);
    // Neither line points anywhere outside the stores.
    _expectNoForbiddenWords();

    // Time added elsewhere: one tap asks the server again.
    backend.active = true;
    final before = backend.calls;
    await tester.ensureVisible(
      find.widgetWithText(HipCta, S.accountCheckAgain),
    );
    await tester.tap(find.widgetWithText(HipCta, S.accountCheckAgain));
    await _settle(tester);
    expect(backend.calls, greaterThan(before));
    expect(state.accountActive, isTrue);
    expect(find.text(S.accountOutOfTimeNote), findsNothing);
  });

  testWidgets('an account with time shows no out-of-time actions', (
    tester,
  ) async {
    final state = _state(backend);
    await tester.pumpWidget(const SizedBox());
    unawaited(state.signInWithAccountNumber(_number));
    await _settle(tester);
    await tester.pumpWidget(_host(state));
    await _settle(tester);

    expect(find.text(S.accountOutOfTimeNote), findsNothing);
    expect(find.widgetWithText(HipCta, S.accountCheckAgain), findsNothing);
  });

  testWidgets('storage that fails says so and frees the button', (
    tester,
  ) async {
    final vault = MemorySecureKeyVault()..failWrites = true;
    SecretPrefs.installKeyVaultForTesting(vault);
    await tester.pumpWidget(_host(_state(backend)));

    await tester.enterText(find.byType(TextField), _number);
    await tester.pump();
    await tester.tap(find.widgetWithText(HipCta, S.accountCtaSignIn));
    await _settle(tester);

    expect(find.text(S.accountErrNetwork), findsOneWidget);
    expect(find.text(S.pwDoneTitle), findsNothing);
    expect(
      _signInButton(tester).onTap,
      isNotNull,
      reason: 'the screen is not left busy',
    );
  });

  testWidgets('taken off from elsewhere, the number waits for one tap', (
    tester,
  ) async {
    final state = _state(backend);
    await tester.pumpWidget(const SizedBox());
    unawaited(state.signInWithAccountNumber(_number));
    await _settle(tester);

    backend.devices = ['dev_two'];
    await tester.pumpWidget(_host(state));
    await _settle(tester);

    expect(find.text('•••• •••• •••• 0319'), findsOneWidget);
    expect(find.text(S.accountDeviceSignedOut), findsOneWidget);
    expect(state.accountNumber, _number);

    backend.devices = ['dev_abc', 'dev_two'];
    await tester.tap(find.widgetWithText(HipCta, S.accountCtaSignIn));
    await _settle(tester);
    expect(find.text(S.pwDoneTitle), findsOneWidget);
    expect(state.premium.isOn, isTrue);
  });

  testWidgets('taken off from elsewhere, nothing on the account can change', (
    tester,
  ) async {
    _tall(tester);
    final state = _state(backend);
    await tester.pumpWidget(const SizedBox());
    unawaited(state.signInWithAccountNumber(_number));
    await _settle(tester);

    backend.devices = ['dev_two'];
    await tester.pumpWidget(_host(state));
    await _settle(tester);

    expect(find.text(S.accountDeviceSignedOut), findsOneWidget);
    expect(state.accountCanManage, isFalse);
    // The number, the reason, the way back in and the way out; nothing else.
    expect(find.text('•••• •••• •••• 0319'), findsOneWidget);
    expect(find.widgetWithText(HipCta, S.accountCtaSignIn), findsOneWidget);
    expect(find.text(S.accountSignOut), findsOneWidget);
    expect(find.text(S.accountDevices.toUpperCase()), findsNothing);
    expect(find.text('Desktop'), findsNothing);
    expect(find.byIcon(Icons.link_off), findsNothing);
    expect(find.text(S.accountRotate), findsNothing);
    expect(find.text(S.accountLinkDevice), findsNothing);
    expect(find.text(S.accountDelete), findsNothing);
  });

  testWidgets('signed in with time, the account can be managed here', (
    tester,
  ) async {
    _tall(tester);
    final state = await _v2SignedIn(tester, backend);
    await tester.pumpWidget(_host(state));
    await _settle(tester);

    expect(find.text(S.accountExplain), findsOneWidget);
    // Nothing pays for this number from here yet: a store subscription is
    // offered, and nothing else under Billing.
    expect(
      find.text(S.accountSubscribeStore('Google Play')),
      kPlansAvailable && state.plansOffered ? findsOneWidget : findsNothing,
    );
    expect(find.textContaining('subscription · renews'), findsNothing);
    expect(find.text('Desktop'), findsOneWidget);
    expect(find.text(S.accountRotate), findsOneWidget);
    expect(find.text(S.accountLinkDevice), findsOneWidget);
    expect(find.text(S.accountDelete), findsOneWidget);
    _expectNoForbiddenWords();
  });

  testWidgets('a linked store subscription gets its billing row', (
    tester,
  ) async {
    _tall(tester);
    final state = await _v2SignedIn(tester, backend);
    state
      ..linked = true
      ..store = 'App Store'
      ..renews = DateTime(2027, 1, 1);
    await tester.pumpWidget(_host(state));
    await _settle(tester);

    expect(find.text(S.accountExplainStore('App Store')), findsOneWidget);
    expect(find.text(S.accountExplain), findsNothing);
    expect(find.text(S.accountSubscribeStore('App Store')), findsNothing);
    expect(find.text(S.pmBilling.toUpperCase()), findsOneWidget);
    expect(
      find.textContaining('App Store subscription · renews'),
      findsOneWidget,
    );
    final manage = tester.widget<TextButton>(
      find.widgetWithText(TextButton, S.accountManage),
    );
    expect(
      manage.onPressed,
      openStoreSubscriptions,
      reason: 'the same way to the store page as Premium manage',
    );
    _expectNoForbiddenWords();
  });

  testWidgets('a store subscription on another number is noted quietly', (
    tester,
  ) async {
    final state = await _v2SignedIn(tester, backend);
    state
      ..elsewhere = true
      ..store = 'Google Play';
    await tester.pumpWidget(_host(state));
    await _settle(tester);

    expect(find.text(S.accountLinkedElsewhere('Google Play')), findsOneWidget);
  });

  testWidgets('with no number on this device, it says how to get one', (
    tester,
  ) async {
    _tall(tester);
    final state = await _v2SignedIn(tester, backend);
    state
      ..numberKnown = false
      ..storeBought = true
      ..store = 'App Store';
    expect(state.accountNumberKnown, isFalse);
    await tester.pumpWidget(_host(state));
    await _settle(tester);

    expect(find.text(S.accountNoNumberHere('App Store')), findsOneWidget);
    expect(find.textContaining('0319'), findsNothing);
    // The number can still be put in here, to see it again.
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.text(S.accountEnterNumber));
    await tester.pump();
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text(S.accountReveal), findsNothing);
    expect(find.text(S.accountCopy), findsNothing);
    expect(find.text(S.accountKeepSafe), findsNothing);
    // Getting a new number is the way to one.
    expect(find.text(S.accountRotate), findsOneWidget);
  });

  testWidgets('signing out while linked says the store keeps adding time', (
    tester,
  ) async {
    _tall(tester);
    final state = await _v2SignedIn(tester, backend);
    state
      ..linked = true
      ..store = 'App Store';
    await tester.pumpWidget(
      _host(state, sheets: GlobalKey<NavigatorState>()),
    );
    await _settle(tester);

    await tester.tap(find.text(S.accountSignOut));
    await _dialog(tester);
    expect(find.text(S.accountSignOutBodyLinked('App Store')), findsOneWidget);
    await tester.tap(find.widgetWithText(HipCta, S.aCancel));
    await _dialog(tester);
  });

  testWidgets('deleting says what happens to a store subscription', (
    tester,
  ) async {
    _tall(tester);
    final state = await _v2SignedIn(tester, backend);
    await tester.pumpWidget(
      _host(state, sheets: GlobalKey<NavigatorState>()),
    );
    await _settle(tester);

    // No store subscription: the plain warning and no store button.
    await tester.tap(find.text(S.accountDelete));
    await _dialog(tester);
    expect(find.text(S.accountDeleteBody), findsOneWidget);
    expect(find.textContaining('Manage in'), findsNothing);
    await tester.tap(find.widgetWithText(HipCta, S.aCancel));
    await _dialog(tester);
    expect(state.deletes, 0);

    // A store subscription goes on billing, and the sheet says so.
    state
      ..storeBought = true
      ..store = 'Google Play';
    await tester.tap(find.text(S.accountDelete));
    await _dialog(tester);
    expect(find.text(S.accountDeleteBodyStore('Google Play')), findsOneWidget);
    expect(
      find.widgetWithText(HipCta, S.accountManageStore('Google Play')),
      findsOneWidget,
    );
    _expectNoForbiddenWords();

    await tester.tap(find.widgetWithText(HipCta, S.accountDelete));
    await _dialog(tester);
    await _settle(tester);
    expect(state.deletes, 1);
    expect(state.accountSignedIn, isFalse);
    expect(state.toast, S.accountDeleted);
    // Back to the sign-in form.
    expect(find.text(S.accountHelp), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('a delete that fails keeps the account and says why', (
    tester,
  ) async {
    _tall(tester);
    final state = await _v2SignedIn(tester, backend);
    state.deleteResult = AccountResult.network;
    await tester.pumpWidget(
      _host(state, sheets: GlobalKey<NavigatorState>()),
    );
    await _settle(tester);

    await tester.tap(find.text(S.accountDelete));
    await _dialog(tester);
    await tester.tap(find.widgetWithText(HipCta, S.accountDelete));
    await _dialog(tester);
    await _settle(tester);
    expect(state.accountSignedIn, isTrue);
    expect(state.toast, S.accountErrNetwork);
    expect(find.text(S.accountDelete), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('a number a purchase just made is shown once', (tester) async {
    final state = await _v2SignedIn(tester, backend);
    state.fresh = _number;
    await tester.pumpWidget(
      _host(state, sheets: GlobalKey<NavigatorState>()),
    );
    await _settle(tester);

    expect(find.text(S.accountFreshTitle), findsOneWidget);
    expect(find.text(S.accountFreshBody), findsOneWidget);
    expect(find.text('8236 3877 8895 0319'), findsOneWidget);
    expect(find.widgetWithText(HipCta, S.accountCopy), findsOneWidget);
    expect(state.acks, 0);
    _expectNoForbiddenWords();

    await tester.tap(find.widgetWithText(HipCta, S.aClose));
    await _dialog(tester);
    expect(state.acks, 1);
    expect(find.text(S.accountFreshTitle), findsNothing);

    // Coming back to the screen does not show it again.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      _host(state, sheets: GlobalKey<NavigatorState>()),
    );
    await _settle(tester);
    expect(find.text(S.accountFreshTitle), findsNothing);
    expect(state.acks, 1);
  });

  testWidgets('a fresh number that never got on screen is kept', (
    tester,
  ) async {
    final state = await _v2SignedIn(tester, backend);
    state.fresh = _number;
    // Sheets close at once here, unseen.
    await tester.pumpWidget(_host(state));
    await _settle(tester);

    expect(state.acks, 0);
    expect(state.freshAccountNumber, _number);
  });

  testWidgets('the sign-in form carries none of the forbidden words', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_state(backend)));
    _expectNoForbiddenWords();
  });
}
