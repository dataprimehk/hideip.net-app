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
import 'package:hideip_vpn/ui/redesign/shell.dart';
import 'package:hideip_vpn/ui/strings.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _number = '8236387788950319';

/// The words C11 keeps out of the app, as a user would read them.
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

HipNav _nav({List<HipScreen>? went}) => HipNav(
  go: (s, [_]) => went?.add(s),
  back: () {},
  ctx: () => null,
  showSheet: <T>(List<Widget> children) async => null,
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
            {
              'id': 'dev_abc',
              'kind': 'phone',
              'name': 'Android phone',
              'created_at': 1756800000,
            },
            {
              'id': 'dev_two',
              'kind': 'desktop',
              'name': 'Desktop',
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

Widget _host(AppState state, {List<HipScreen>? went}) => MaterialApp(
  home: Scaffold(
    body: AccountScreen(
      state: state,
      nav: _nav(went: went),
    ),
  ),
);

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
    final state = _state(backend);
    await tester.pumpWidget(const SizedBox());
    unawaited(state.signInWithAccountNumber(_number));
    await _settle(tester);
    expect(state.accountSignedIn, isTrue);
    await tester.pumpWidget(_host(state));
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
    expect(find.byType(Dialog), findsOneWidget);
    expect(
      find.text('8236 3877 8895 0319'),
      findsNothing,
      reason: 'nothing shows before the warning is confirmed',
    );

    await tester.tap(find.widgetWithText(TextButton, S.aCancel));
    await _dialog(tester);
    expect(find.text('8236 3877 8895 0319'), findsNothing);

    await tester.tap(find.text(S.accountReveal));
    await _dialog(tester);
    await tester.tap(find.widgetWithText(TextButton, S.accountReveal));
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

  testWidgets('the sign-in form carries none of the forbidden words', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_state(backend)));
    _expectNoForbiddenWords();
  });
}
