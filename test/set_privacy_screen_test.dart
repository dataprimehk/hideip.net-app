import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hideip_vpn/state/app_state.dart';
import 'package:hideip_vpn/ui/redesign/hip.dart';
import 'package:hideip_vpn/ui/redesign/settings_screen.dart';
import 'package:hideip_vpn/ui/redesign/shell.dart';
import 'package:hideip_vpn/ui/strings.dart';

HipNav _nav() => HipNav(
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

/// Mirrors the one thing the real shell (`shell.dart`) does above every
/// screen: rebuild on every [AppState] change. Settings itself does not
/// listen; in the app the shell's `ListenableBuilder` covers it even while a
/// pushed route sits on top, which is what lets the row you left behind
/// already be current by the time you come back to it.
Widget _host(AppState state, HipNav nav) => MaterialApp(
      home: ListenableBuilder(
        listenable: state,
        builder: (context, child) =>
            Scaffold(body: SettingsScreen(state: state, nav: nav)),
      ),
    );

void main() {
  // Settings is a lazy ListView: on a phone-sized test surface the Privacy
  // row sits below the fold and is never built, so the tree is inspected on
  // a tall one.
  setUp(() {
    Hip.reducedMotion = true;
    final view = TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .views
        .first;
    view.physicalSize = const Size(1000, 4000);
    view.devicePixelRatio = 1;
    addTearDown(view.resetPhysicalSize);
    addTearDown(view.resetDevicePixelRatio);
  });
  tearDown(() => Hip.reducedMotion = false);

  testWidgets('the Privacy row states the toggle state and opens the screen',
      (tester) async {
    final state = AppState();
    await tester.pumpWidget(_host(state, _nav()));
    await tester.pump();

    expect(state.prefs.usageCounts, isTrue,
        reason: 'the default the app ships with');
    // The Privacy row itself, not the unrelated "Privacy Policy" row that
    // stays in Help: both carry the toggle's own words nowhere in Settings.
    expect(find.text(S.setPrivacyRowSub(true)), findsOneWidget);
    expect(find.text(S.setUsage), findsNothing,
        reason: 'the toggle itself moved to the Privacy screen');

    await tester.tap(find.text(S.setPrivacySection));
    await tester.pumpAndSettle();

    expect(find.text(S.setPrivacyExplain), findsOneWidget);
    expect(find.text(S.setPrivacyPolicy), findsOneWidget);
    expect(find.text(S.setUsage), findsOneWidget);
    expect(find.text(S.setUsageSub), findsOneWidget);
  });

  testWidgets('toggling on the Privacy screen updates the Settings subtitle',
      (tester) async {
    final state = AppState();
    await tester.pumpWidget(_host(state, _nav()));
    await tester.pump();

    await tester.tap(find.text(S.setPrivacySection));
    await tester.pumpAndSettle();

    expect(tester.widget<HipToggle>(find.byType(HipToggle)).on, isTrue);
    await tester.tap(find.byType(HipToggle));
    await tester.pump();

    expect(state.prefs.usageCounts, isFalse);
    expect(tester.widget<HipToggle>(find.byType(HipToggle)).on, isFalse);
    expect(find.text(S.setPrivacyRowSub(false)), findsNothing,
        reason: 'the Settings row is a route below, offstage until back');

    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pumpAndSettle();

    expect(find.text(S.setPrivacyRowSub(false)), findsOneWidget);
    expect(find.text(S.setPrivacyRowSub(true)), findsNothing);
  });
}
