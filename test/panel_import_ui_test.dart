import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hideip_vpn/core/ip_lookup.dart';
import 'package:hideip_vpn/core/ping.dart';
import 'package:hideip_vpn/core/sub_info.dart';
import 'package:hideip_vpn/core/subscription.dart';
import 'package:hideip_vpn/core/user_subscription.dart';
import 'package:hideip_vpn/state/app_state.dart';
import 'package:hideip_vpn/ui/redesign/hip.dart';
import 'package:hideip_vpn/ui/redesign/import_screen.dart';
import 'package:hideip_vpn/ui/redesign/shell.dart';
import 'package:hideip_vpn/ui/strings.dart';

class QuietState extends AppState {
  @override
  Future<void> pingAll() async {}
}

HipNav nav() => HipNav(
  go: (_, [_]) {},
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
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Hip.reducedMotion = true;
    IpLookup.lookupOverride = (_) async => null;
  });
  tearDown(() {
    Hip.reducedMotion = false;
    IpLookup.lookupOverride = null;
  });
  testWidgets(
    'partial import shows skipped types and commits the subscription name',
    (tester) async {
      await tester.runAsync(() async {
        final state = QuietState();
        const url = 'https://provider.example/sub';
        final parsed = Subscription.parse(
          'vless://id@example.com:443#de-fra-01\nvless://id@example.com:443?type=xhttp',
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ImportScreen(
                state: state,
                nav: nav(),
                initialText: url,
                initialName: 'My provider',
                hooks: ImportHooks(
                  ping: (_, _) async => const PingOk(20),
                  fetchSubscription: (_) async => SubFetch(
                    profiles: parsed.profiles
                        .map((p) => p.copyWith(subUrl: url))
                        .toList(),
                    info: null,
                    parsed: parsed,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text(S.eImport));
        await Future<void>.delayed(const Duration(milliseconds: 1800));
        await tester.pump();
        expect(find.text(S.subscriptionSkipped(parsed)), findsOneWidget);
        await tester.tap(find.text(S.e6AddOnly));
        await Future<void>.delayed(const Duration(milliseconds: 150));
        await tester.pump();
        expect(state.profiles.length, 1);
        expect((await SubInfoStore.load())[url]?.title, 'My provider');
        await tester.pumpWidget(const SizedBox());
        state.dispose();
      });
    },
  );
  testWidgets('single unsupported transport has a named localized error', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final state = QuietState();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ImportScreen(
              state: state,
              nav: nav(),
              initialText: 'vless://id@example.com:443?type=xhttp',
            ),
          ),
        ),
      );
      await tester.tap(find.text(S.eImport));
      await tester.pump();
      expect(find.text(S.unsupportedProfile('xhttp')), findsOneWidget);
      expect(state.profiles, isEmpty);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    });
  });
}
