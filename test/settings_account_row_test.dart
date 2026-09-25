import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hideip_vpn/core/account_service.dart';
import 'package:hideip_vpn/core/account_store.dart';
import 'package:hideip_vpn/core/provisioning.dart';
import 'package:hideip_vpn/core/secret_prefs.dart';
import 'package:hideip_vpn/state/app_state.dart';
import 'package:hideip_vpn/ui/redesign/hip.dart';
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

  testWidgets('signed in, the row shows the last four digits', (tester) async {
    final ms = DateTime.now()
        .add(const Duration(days: 30))
        .millisecondsSinceEpoch;
    final state = AppState(
      accounts: AccountService(
        client: MockClient((req) async {
          if (req.url.path == '/v1/account/signin') {
            return http.Response(
              jsonEncode({
                'active': true,
                'expires_ms': ms,
                'subscription_url': 'https://api.test/v1/sub/dev_abc',
                'device': {'id': 'dev_abc', 'kind': 'phone', 'name': 'x'},
                'device_token': 'tok',
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
    await tester.pumpWidget(const SizedBox());
    unawaited(state.signInWithAccountNumber('8236387788950319'));
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(state.accountSignedIn, isTrue);

    await tester.pumpWidget(_settings(state, <HipScreen>[]));
    await tester.pump();

    expect(find.textContaining('•••• 0319'), findsOneWidget);
    expect(find.textContaining(S.setAccountNumberSignedIn), findsOneWidget);
    // The Premium row is back, and it says how long the account runs,
    // never that it renews.
    expect(find.text(S.tPremium), findsOneWidget);
    expect(find.textContaining('Active until'), findsOneWidget);
    expect(find.textContaining('renews'), findsNothing);
    // The card that sells stays away from someone who is in.
    expect(find.byType(PremiumSalesCard), findsNothing);
  });
}
