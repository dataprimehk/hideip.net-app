import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hideip_vpn/core/account_service.dart';
import 'package:hideip_vpn/core/account_store.dart';
import 'package:hideip_vpn/core/premium.dart';
import 'package:hideip_vpn/core/provisioning.dart';
import 'package:hideip_vpn/core/secret_prefs.dart';
import 'package:hideip_vpn/state/app_state.dart';
import 'package:hideip_vpn/ui/redesign/hip.dart';
import 'package:hideip_vpn/ui/redesign/paywall_screen.dart';
import 'package:hideip_vpn/ui/redesign/settings_screen.dart';
import 'package:hideip_vpn/ui/redesign/shell.dart';
import 'package:hideip_vpn/ui/strings.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

HipNav _nav(List<HipScreen> went) => HipNav(
  go: (s, [_]) => went.add(s),
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

Widget _settings(AppState state, List<HipScreen> went) => MaterialApp(
  home: Scaffold(
    body: SettingsScreen(state: state, nav: _nav(went)),
  ),
);

/// A state whose store subscription adds time to its account number.
class _LinkedState extends AppState {
  _LinkedState({super.accounts, super.provisioning});

  @override
  bool get storeLinked => true;
  @override
  String? get storeName => 'App Store';
}

/// A device that signed out of the number its store subscription pays for.
class _PausedState extends AppState {
  int restores = 0;

  @override
  bool get storePausedHere => true;
  @override
  String? get storeName => 'App Store';
  @override
  Future<void> restorePurchases() async => restores++;
}

/// A state signed in to an account number whose sign-in answers [active],
/// with the store entitlement [store] reported first when given. With
/// [linked] the store subscription adds time to the number.
Future<AppState> _signedIn(
  WidgetTester tester, {
  required bool active,
  Premium? store,
  bool linked = false,
}) async {
  final ms = DateTime.now()
      .add(Duration(days: active ? 300 : -3))
      .millisecondsSinceEpoch;
  final state = (linked ? _LinkedState.new : AppState.new)(
    accounts: AccountService(
      client: MockClient((req) async {
        if (req.url.path == '/v1/account/signin') {
          return http.Response(
            jsonEncode({
              'active': active,
              'expires_ms': ms,
              'subscription_url': active
                  ? 'https://api.test/v1/sub/dev_abc'
                  : null,
              'device': active
                  ? {'id': 'dev_abc', 'kind': 'phone', 'name': 'x'}
                  : null,
              'device_token': active ? 'tok' : null,
              'device_limit': 5,
            }),
            200,
          );
        }
        return http.Response('', 503);
      }),
    ),
    provisioning: ProvisioningService(
      client: MockClient((_) async => http.Response('', 503)),
      catalogSources: [Uri.parse('https://mirror.test/catalog')],
    ),
  );
  if (store != null) state.storeEntitlementForTesting(store);
  await tester.pumpWidget(const SizedBox());
  unawaited(state.signInWithAccountNumber('8236387788950319'));
  for (var i = 0; i < 30; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(state.accountSignedIn, isTrue);
  return state;
}

void main() {
  // Settings is a lazy ListView; a tall surface builds every section.
  setUp(() async {
    final view = TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .views
        .first;
    view.physicalSize = const Size(1000, 4000);
    view.devicePixelRatio = 1;
    addTearDown(view.resetPhysicalSize);
    addTearDown(view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    // A fresh vault also drops the per-key gates: work a previous test left
    // on its own clock must not queue this one behind it.
    SecretPrefs.installKeyVaultForTesting(MemorySecureKeyVault());
    await PremiumSub.clear();
    await const AccountStore().clear();
    Hip.reducedMotion = true;
  });

  tearDown(() => Hip.reducedMotion = false);

  testWidgets('a signed-out store subscriber gets a restore, never a trial', (
    tester,
  ) async {
    final state = _PausedState();
    await tester.pumpWidget(_settings(state, <HipScreen>[]));
    await tester.pump();

    expect(find.byType(PremiumSalesCard), findsNothing);
    expect(find.text(S.storePausedTitle('App Store')), findsOneWidget);
    await tester.tap(find.text(S.pwRestore));
    await tester.pump();
    expect(state.restores, 1);
  });

  testWidgets('the Account number row is there with no store behind it', (
    tester,
  ) async {
    final went = <HipScreen>[];
    final state = AppState();
    await tester.pumpWidget(_settings(state, went));
    await tester.pump();

    // A bare state has no store catalog: nothing may be offered for sale.
    expect(state.plansOffered, isFalse);
    expect(find.byType(PremiumSalesCard), findsNothing);
    expect(find.text(S.tPremium), findsNothing);

    if (!kAccountSignIn) {
      expect(find.text(S.accountNumberTitle), findsNothing);
      expect(find.text(S.setAccountNumberSub), findsNothing);
      return;
    }

    // The section and its one row show all the same.
    expect(find.text(S.setAccount.toUpperCase()), findsOneWidget);
    expect(find.text(S.accountNumberTitle), findsOneWidget);
    expect(find.text(S.setAccountNumberSub), findsOneWidget);
    final header = tester.widget<SettingsSectionHeader>(
      find.ancestor(
        of: find.text(S.setAccount.toUpperCase()),
        matching: find.byType(SettingsSectionHeader),
      ),
    );
    expect(header.icon, Icons.person_outline);

    await tester.tap(find.text(S.accountNumberTitle));
    expect(went, [HipScreen.account]);
  });

  testWidgets('signed in, one Premium row leads to the account', (
    tester,
  ) async {
    final state = await _signedIn(tester, active: true);
    expect(state.canLinkDevices, isTrue);

    final went = <HipScreen>[];
    await tester.pumpWidget(_settings(state, went));
    await tester.pump();

    // The Premium row says how long the account runs, never that it
    // renews.
    expect(find.text(S.tPremium), findsOneWidget);
    expect(find.textContaining('Active until'), findsOneWidget);
    expect(find.textContaining('renews'), findsNothing);
    // The card that sells stays away from someone who is in.
    expect(find.byType(PremiumSalesCard), findsNothing);
    if (!kAccountSignIn) return;

    // One story: the number, its time and its devices live behind the one
    // row, so neither a second number row nor Linked devices shows.
    expect(find.text(S.accountNumberTitle), findsNothing);
    expect(find.text(S.setLinkedDevices), findsNothing);
    await tester.tap(find.text(S.tPremium));
    expect(went, [HipScreen.account]);
  });

  testWidgets('a store subscription in force keeps its own rows', (
    tester,
  ) async {
    final state = await _signedIn(
      tester,
      active: true,
      store: Premium(
        status: PremiumStatus.active,
        plan: PremiumPlan.yearly,
        renews: DateTime.now().add(const Duration(days: 400)),
      ),
    );
    expect(state.premium.source, PremiumSource.store);

    final went = <HipScreen>[];
    await tester.pumpWidget(_settings(state, went));
    await tester.pump();

    expect(find.text(S.tPremium), findsOneWidget);
    expect(find.textContaining('renews'), findsOneWidget);
    expect(find.textContaining('•••• 0319'),
        kAccountSignIn ? findsOneWidget : findsNothing);
    await tester.tap(find.text(S.tPremium));
    expect(went, [HipScreen.premium]);
  });

  testWidgets('with no store behind the app, an account out of time says so', (
    tester,
  ) async {
    final state = await _signedIn(tester, active: false);
    expect(state.plansOffered, isFalse);

    await tester.pumpWidget(_settings(state, <HipScreen>[]));
    await tester.pump();

    expect(find.text(S.tPremium), findsOneWidget);
    expect(find.text(S.accountOutOfTime), findsOneWidget);
  });

  testWidgets('Premium manage keeps the store page for a store subscription', (
    tester,
  ) async {
    final state = await _signedIn(
      tester,
      active: true,
      store: Premium(
        status: PremiumStatus.active,
        plan: PremiumPlan.monthly,
        renews: DateTime.now().add(const Duration(days: 5)),
      ),
    );
    expect(state.premium.source, PremiumSource.account);
    expect(state.hasStoreEntitlement, isTrue);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PremiumManageScreen(state: state, nav: _nav(<HipScreen>[])),
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('Manage in'), findsOneWidget);
    expect(find.text(S.pwRestore), findsNothing);
    expect(
      find.text(S.accountExplain),
      kAccountSignIn ? findsOneWidget : findsNothing,
    );
    expect(
      find.text(S.accountNumberTitle),
      kAccountSignIn ? findsOneWidget : findsNothing,
    );
  });

  testWidgets('Premium manage says a linked store adds time to the number', (
    tester,
  ) async {
    final state = await _signedIn(tester, active: true, linked: true);
    expect(state.premium.source, PremiumSource.account);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PremiumManageScreen(state: state, nav: _nav(<HipScreen>[])),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.text(S.accountExplainStore('App Store')),
      kAccountSignIn ? findsOneWidget : findsNothing,
    );
    expect(find.text(S.accountExplain), findsNothing);
  });

  testWidgets('without a store subscription the store page stays away', (
    tester,
  ) async {
    final state = await _signedIn(tester, active: true);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PremiumManageScreen(state: state, nav: _nav(<HipScreen>[])),
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('Manage in'), findsNothing);
    expect(find.text(S.pwRestore), findsNothing);
  });
}
