import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hideip_vpn/core/ip_lookup.dart';
import 'package:hideip_vpn/state/app_state.dart';
import 'package:hideip_vpn/ui/redesign/ascii/ascii_core.dart';
import 'package:hideip_vpn/ui/redesign/ascii/ob3_ascii.dart';
import 'package:hideip_vpn/ui/redesign/hip.dart';
import 'package:hideip_vpn/ui/redesign/onboarding_screen.dart';
import 'package:hideip_vpn/ui/redesign/shell.dart';
import 'package:hideip_vpn/ui/strings.dart';

/// What the screen asked the navigator to do.
class _NavLog {
  final List<HipScreen> went = [];
  Object? ctx;
  HipScreen? paywallFrom;
  bool imported = false;
}

HipNav _navFor(_NavLog log) => HipNav(
      go: (screen, [ctx]) => log.went.add(screen),
      back: () {},
      ctx: () => log.ctx,
      showSheet: <T>(List<Widget> children) => Future<T?>.value(null),
      openDetail: (_) {},
      openImport: () => log.imported = true,
      openImportWith: (_) {},
      openPaywall: ({required HipScreen from, String? locId}) =>
          log.paywallFrom = from,
      claimBack: (_) {},
      releaseBack: (_) {},
    );

Future<void> _pumpOnboarding(
  WidgetTester tester, {
  required AppState state,
  required HipNav nav,
  bool disableAnimations = true,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(disableAnimations: disableAnimations),
        // The shell puts every screen inside a Scaffold; the ink responses
        // need that Material ancestor.
        child: Scaffold(
          backgroundColor: Hip.dark,
          body: OnboardingScreen(state: state, nav: nav),
        ),
      ),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 16));
}

/// One tap plus enough time for the 300 ms handoff between beats.
Future<void> _tap(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    Hip.reducedMotion = false;
  });

  group('field maths', () {
    // The reference values come from the JavaScript in
    // `design/onboarding-v3/ob3-ascii.js`, evaluated on the same inputs. The
    // field is seeded noise, so drift here is drift nobody would ever see in
    // a log; it only shows up as a picture that is not the design.
    test('smoothstep matches the JavaScript on its edges and middle', () {
      expect(ob3Smoothstep(0.3, 0.9, 0.1), 0.0);
      expect(ob3Smoothstep(0.3, 0.9, 0.3), 0.0);
      expect(ob3Smoothstep(0.3, 0.9, 0.45), closeTo(0.15625, 1e-12));
      expect(ob3Smoothstep(0.3, 0.9, 0.6), closeTo(0.5, 1e-12));
      expect(ob3Smoothstep(0.3, 0.9, 0.9), 1.0);
      expect(ob3Smoothstep(0.3, 0.9, 1.5), 1.0);
    });

    test('centerMask keeps the middle quiet and the edges lit', () {
      // Dead centre sits inside the inner edge: the floor, 0.28.
      expect(ob3CenterMask(16, 9, 34, 20), closeTo(0.28, 1e-12));
      expect(ob3CenterMask(11, 6, 34, 20), closeTo(0.515817503462, 1e-9));
      expect(ob3CenterMask(20, 12, 34, 20), closeTo(0.298669420443, 1e-9));
      expect(ob3CenterMask(8, 4, 34, 20), closeTo(0.969336715388, 1e-9));
      // Corners saturate.
      expect(ob3CenterMask(0, 0, 34, 20), closeTo(1.0, 1e-12));
      expect(ob3CenterMask(33, 19, 34, 20), closeTo(1.0, 1e-12));
      // A taller field puts the same column further out.
      expect(ob3CenterMask(16, 9, 34, 52), closeTo(0.761859495516, 1e-9));
      expect(ob3CenterMask(10, 20, 34, 52), closeTo(0.469751569554, 1e-9));
    });

    test('the glyph thresholds fall exactly where the JavaScript puts them',
        () {
      expect(glyphExposed(0), '0'); // v = 0.000000
      expect(glyphExposed(0x11111111), '1'); // v = 0.066667
      expect(glyphExposed(0xB3000700), '1'); // v = 0.699219, last digit
      expect(glyphExposed(0xD9000000), '.'); // v = 0.847656
      expect(glyphExposed(0xE6000000), '░'); // v = 0.898438
      expect(glyphExposed(0xEC000000), '▒'); // v = 0.921875
      expect(glyphExposed(0xF5000000), ':'); // v = 0.957031
    });
  });

  group('the beat one proof line', () {
    IpGeo geo({String city = 'Belgrade', String? cc, String? isp}) =>
        IpGeo(lat: 44.79, lon: 20.45, city: city, cc: cc, isp: isp);

    test('the tail degrades one part at a time', () {
      // Everything known.
      expect(obGeoTail(geo(cc: 'RS', isp: 'Telekom Srbija')),
          'Telekom Srbija · Belgrade, RS');
      // No provider: the place still stands on its own.
      expect(obGeoTail(geo(cc: 'RS')), 'Belgrade, RS');
      // No country code.
      expect(obGeoTail(geo(isp: 'Telekom Srbija')), 'Telekom Srbija · Belgrade');
      expect(obGeoTail(geo()), 'Belgrade');
      // `you` is the map pin's placeholder, not a city name.
      expect(obGeoTail(geo(city: 'you', isp: 'Telekom Srbija')),
          'Telekom Srbija');
      // Nothing known at all: no tail rather than a padded one.
      expect(obGeoTail(geo(city: 'you')), isNull);
      expect(obGeoTail(null), isNull);
    });
  });

  group('onboarding v3', () {
    testWidgets('walks four states with the exact headlines', (tester) async {
      final log = _NavLog();
      await _pumpOnboarding(tester, state: AppState(), nav: _navFor(log));

      // A1
      expect(find.text(S.obB1Title), findsOneWidget);
      expect(find.text(S.obB1Note), findsOneWidget);
      await _tap(tester, S.obB1Cta);

      // A2
      expect(find.text(S.obB2Title), findsOneWidget);
      expect(find.text(S.obB2TechIp), findsOneWidget);
      expect(find.text(S.obB2TechPlace), findsOneWidget);
      await _tap(tester, S.obNext);

      // A3
      expect(find.text(S.obB3Title), findsOneWidget);
      expect(find.text(S.obB3TechValue), findsOneWidget);
      expect(find.text(S.obB3TechPort), findsOneWidget);
      await _tap(tester, S.obNext);

      // A4
      expect(find.text(S.obChoiceTitle), findsOneWidget);
      expect(find.text(S.obChoiceImport), findsOneWidget);
      expect(find.text(S.obExplore), findsOneWidget);
    });

    testWidgets('progress is three mono glyphs that fill up', (tester) async {
      final log = _NavLog();
      await _pumpOnboarding(tester, state: AppState(), nav: _navFor(log));

      expect(find.text('█'), findsOneWidget);
      expect(find.text('░'), findsNWidgets(2));

      await _tap(tester, S.obB1Cta);
      expect(find.text('█'), findsNWidgets(2));
      expect(find.text('░'), findsOneWidget);

      await _tap(tester, S.obNext);
      expect(find.text('█'), findsNWidgets(3));
      expect(find.text('░'), findsNothing);
    });

    testWidgets('beat one stays silent until the lookup has an address',
        (tester) async {
      final log = _NavLog();
      final state = AppState();
      await _pumpOnboarding(tester, state: state, nav: _navFor(log));
      // No public IP yet: the proof line is absent rather than invented.
      expect(state.publicIp, isNull);
      expect(find.text(S.obB1TechKey), findsNothing);
    });

    testWidgets('the choice screen leads home, and back walks the beats',
        (tester) async {
      final log = _NavLog();
      await _pumpOnboarding(tester, state: AppState(), nav: _navFor(log));
      await _tap(tester, S.obB1Cta);
      await _tap(tester, S.obNext);
      await _tap(tester, S.obNext);
      expect(find.text(S.obChoiceTitle), findsOneWidget);

      await tester.tap(find.byIcon(Icons.chevron_left));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(S.obB3Title), findsOneWidget);

      await _tap(tester, S.obNext);
      await tester.tap(find.text(S.obExplore));
      await tester.pump(const Duration(milliseconds: 400));
      expect(log.went, [HipScreen.home]);
    });

    testWidgets('the import option opens the importer', (tester) async {
      final log = _NavLog();
      await _pumpOnboarding(tester, state: AppState(), nav: _navFor(log));
      await _tap(tester, S.obB1Cta);
      await _tap(tester, S.obNext);
      await _tap(tester, S.obNext);
      await tester.tap(find.text(S.obChoiceImport));
      await tester.pump(const Duration(milliseconds: 400));
      expect(log.imported, isTrue);
    });

    testWidgets('the choice screen has a quiet way in with an account number',
        (tester) async {
      final log = _NavLog();
      final state = AppState();
      await _pumpOnboarding(tester, state: state, nav: _navFor(log));
      await _tap(tester, S.obB1Cta);
      await _tap(tester, S.obNext);
      await _tap(tester, S.obNext);
      expect(find.text(S.accountSignInLink), findsOneWidget);
      await tester.ensureVisible(find.text(S.accountSignInLink));
      await tester.tap(find.text(S.accountSignInLink));
      await tester.pump(const Duration(milliseconds: 400));
      expect(log.went, [HipScreen.account]);
      // Sign-in ends on Home, so the intro counts as seen.
      expect(state.prefs.onboarded, isTrue);
    });

    test('the intro no longer promises "no account" next to an account number',
        () {
      for (final line in [S.obB1Note, S.obChoiceNote, S.c2Anon]) {
        expect(line.toLowerCase(), isNot(contains('no account')));
      }
    });

    testWidgets('replay ends after the third beat, without the choice',
        (tester) async {
      final log = _NavLog()..ctx = const {'replay': true};
      await _pumpOnboarding(tester, state: AppState(), nav: _navFor(log));

      await _tap(tester, S.obB1Cta);
      await _tap(tester, S.obNext);
      // The last beat closes the replay instead of asking how to start.
      expect(find.text(S.obDone), findsOneWidget);
      await _tap(tester, S.obDone);

      expect(find.text(S.obChoiceTitle), findsNothing);
      expect(log.went, [HipScreen.home]);
    });

    testWidgets('a bare true context replays too', (tester) async {
      final log = _NavLog()..ctx = true;
      await _pumpOnboarding(tester, state: AppState(), nav: _navFor(log));
      await _tap(tester, S.obB1Cta);
      await _tap(tester, S.obNext);
      expect(find.text(S.obDone), findsOneWidget);
    });

    testWidgets('disableAnimations starts no ticker', (tester) async {
      final log = _NavLog();
      await _pumpOnboarding(tester, state: AppState(), nav: _navFor(log));
      // Nothing is animating: no frame callback is registered at all.
      expect(tester.binding.transientCallbackCount, 0);

      await _tap(tester, S.obB1Cta);
      expect(find.text(S.obB2Title), findsOneWidget);
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('with motion allowed the field runs and then tears down',
        (tester) async {
      final log = _NavLog();
      await _pumpOnboarding(
        tester,
        state: AppState(),
        nav: _navFor(log),
        disableAnimations: false,
      );
      // The ASCII ticker is live; onboarding never idles out.
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull);

      // Replacing the screen has to stop every clock it started.
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.binding.transientCallbackCount, 0);
    });
  });
}
