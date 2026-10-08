import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hideip_vpn/core/camera_permission.dart';
import 'package:hideip_vpn/core/location.dart';
import 'package:hideip_vpn/core/proxy_profile.dart';
import 'package:hideip_vpn/core/secret_prefs.dart';
import 'package:hideip_vpn/core/srv_countries.dart';
import 'package:hideip_vpn/state/app_state.dart';
import 'package:hideip_vpn/ui/redesign/hip.dart';
import 'package:hideip_vpn/ui/redesign/hip_sheet.dart';
import 'package:hideip_vpn/ui/redesign/home_hero.dart';
import 'package:hideip_vpn/ui/redesign/import_screen.dart';
import 'package:hideip_vpn/ui/redesign/locations_screen.dart';
import 'package:hideip_vpn/ui/redesign/qr_popup.dart';
import 'package:hideip_vpn/ui/redesign/shell.dart';
import 'package:hideip_vpn/ui/redesign/srv_location_picker.dart';
import 'package:hideip_vpn/ui/redesign/system_bars.dart';
import 'package:hideip_vpn/ui/strings.dart';

// Android 15 and later always draw an app that targets SDK 35+ edge to edge:
// the status bar and the navigation bar sit over the app and reach Flutter
// as padding, and the keyboard as a view inset. These tests lay the key
// screens and the sheet out in that window and check nothing ends up under
// a bar or the keyboard. They are layout evidence, not a device check.

/// A Pixel 6a sized window.
const _w = 412.0;
const _h = 915.0;
const _status = 24.0;

/// Three-button navigation, and the strip gesture navigation leaves.
const _buttons = 48.0;
const _gestures = 24.0;

/// Gboard with its suggestion strip on that phone, roughly.
const _keyboard = 300.0;

Future<void> _loadFonts() async {
  for (final family in const {
    'Inter': 'assets/fonts/Inter-Variable.ttf',
    'Onest': 'assets/fonts/Onest-Variable.ttf',
    'JetBrainsMono': 'assets/fonts/JetBrainsMono-Variable.ttf',
  }.entries) {
    final loader = FontLoader(family.key)
      ..addFont(rootBundle.load(family.value));
    await loader.load();
  }
}

/// The window as the engine reports it: the bars are view padding, and the
/// padding is whatever part of them the keyboard leaves uncovered.
void _phone(
  WidgetTester tester, {
  double nav = _buttons,
  double ime = 0,
  Size size = const Size(_w, _h),
}) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  tester.view.viewPadding = FakeViewPadding(top: _status, bottom: nav);
  tester.view.padding = FakeViewPadding(
    top: _status,
    bottom: (nav - ime).clamp(0, nav),
  );
  tester.view.viewInsets = FakeViewPadding(bottom: ime);
  addTearDown(tester.view.reset);
}

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

/// Every style the framework sent to the platform, newest last.
final _sent = <Map<String, dynamic>>[];

Map<String, dynamic> get _lastStyle => _sent.last;

/// The sheet's card itself, without the keyboard padding under it.
Rect _card(WidgetTester tester) => tester.getRect(
  find
      .descendant(of: find.byType(HipSheet), matching: find.byType(Container))
      .first,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(_loadFonts);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SecretPrefs.installKeyVaultForTesting(MemorySecureKeyVault());
    _sent.clear();
    // Forget the style in effect, so the next frame sends its own.
    SystemChrome.handleAppLifecycleStateChanged(AppLifecycleState.detached);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'SystemChrome.setSystemUIOverlayStyle') {
            _sent.add(Map<String, dynamic>.from(call.arguments as Map));
          }
          return null;
        });
    Hip.reducedMotion = true;
  });
  tearDown(() {
    Hip.reducedMotion = false;
    Hip.dm = false;
  });

  group('bar styles', () {
    test('a light surface gets dark icons, a dark one light icons', () {
      final light = hipBars(darkTop: false, bottom: Hip.surface);
      expect(light.statusBarIconBrightness, Brightness.dark);
      expect(light.systemNavigationBarIconBrightness, Brightness.dark);
      expect(light.statusBarColor, Colors.transparent);
      // Below Android 15 the bar is painted; it continues the surface.
      expect(light.systemNavigationBarColor, Hip.surface);

      final dark = hipBars(darkTop: true, bottom: Hip.dark);
      expect(dark.statusBarIconBrightness, Brightness.light);
      expect(dark.statusBarBrightness, Brightness.dark);
      expect(dark.systemNavigationBarIconBrightness, Brightness.light);
      expect(dark.systemNavigationBarColor, Hip.dark);
    });

    test('Home under the hero, over the light list, splits the two bars', () {
      // Light mode Home: dark hero at the top, light surface at the bottom.
      final home = hipBars(darkTop: true, bottom: Hip.surface);
      expect(home.statusBarIconBrightness, Brightness.light);
      expect(home.systemNavigationBarIconBrightness, Brightness.dark);
      // Map mode ends on the hero colour instead.
      final map = hipBars(darkTop: true, bottom: Hip.hero);
      expect(map.systemNavigationBarIconBrightness, Brightness.light);
    });

    test('dark mode surfaces read as dark', () {
      Hip.dm = true;
      for (final c in [Hip.surface, Hip.card, Hip.hero]) {
        expect(
          hipBars(darkTop: true, bottom: c).systemNavigationBarIconBrightness,
          Brightness.light,
        );
      }
    });
  });

  group('the sheet', () {
    Future<void> openSheet(
      WidgetTester tester,
      List<Widget> children, {
      required SystemUiOverlayStyle screen,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: AnnotatedRegion<SystemUiOverlayStyle>(
            value: screen,
            child: Scaffold(
              backgroundColor: Hip.hero,
              body: Builder(
                builder: (context) => Center(
                  child: TextButton(
                    onPressed: () =>
                        showHipSheet<void>(context, children: children),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    List<Widget> body() => [
      const HipSheetTitle('Title'),
      const HipSheetBody('A body of a sentence or two.'),
      HipSheetActions(
        children: [
          HipCta('Primary', onTap: () {}),
          HipCta('Quiet', quiet: true, onTap: () {}),
        ],
      ),
    ];

    for (final nav in [_buttons, _gestures]) {
      testWidgets('reaches the bottom edge and keeps its actions over the '
          '${nav == _buttons ? 'buttons' : 'gesture strip'}', (tester) async {
        _phone(tester, nav: nav);
        await openSheet(
          tester,
          body(),
          screen: hipBars(darkTop: true, bottom: Hip.hero),
        );

        final card = _card(tester);
        expect(card.bottom, _h, reason: 'the card runs under the bar');
        final last = tester.getRect(find.widgetWithText(HipCta, 'Quiet'));
        expect(last.bottom, lessThanOrEqualTo(_h - nav));
      });
    }

    testWidgets('claims the navigation bar but leaves the status bar alone', (
      tester,
    ) async {
      _phone(tester);
      await openSheet(
        tester,
        body(),
        screen: hipBars(darkTop: true, bottom: Hip.hero),
      );
      // The screen behind is dark top to bottom; the light card that now
      // meets the navigation bar asks for dark buttons there.
      expect(_lastStyle['statusBarIconBrightness'], 'Brightness.light');
      expect(
        _lastStyle['systemNavigationBarIconBrightness'],
        'Brightness.dark',
      );
    });

    testWidgets('in dark mode the card keeps light buttons', (tester) async {
      Hip.dm = true;
      _phone(tester);
      await openSheet(
        tester,
        body(),
        screen: hipBars(darkTop: true, bottom: Hip.surface),
      );
      expect(
        _lastStyle['systemNavigationBarIconBrightness'],
        'Brightness.light',
      );
    });
  });

  group('the location picker sheet', () {
    Future<List<SrvCountry>> countries() async => const [
      SrvCountry('DE', 'Germany'),
      SrvCountry('FR', 'France'),
      SrvCountry('NL', 'Netherlands'),
    ];

    Future<void> open(WidgetTester tester, {bool overridden = false}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => showSrvLocationPicker(
                    context,
                    cc: overridden ? 'FR' : null,
                    city: overridden ? 'Lyon' : null,
                    overridden: overridden,
                    loadCountries: countries,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    // Before the body could scroll, the overridden picker (three actions)
    // overflowed by 43px at this size and lost Cancel under the keyboard.
    for (final overridden in [false, true]) {
      testWidgets('rides above the keyboard without losing its actions'
          '${overridden ? ' (overridden)' : ''}', (tester) async {
        _phone(tester);
        await open(tester, overridden: overridden);

        await tester.showKeyboard(find.byType(TextField).last);
        _phone(tester, ime: _keyboard);
        await tester.pumpAndSettle();

        expect(
          tester.takeException(),
          isNull,
          reason: 'nothing overflows with the keyboard up',
        );
        const kbTop = _h - _keyboard;
        final city = tester.getRect(find.byType(TextField).last);
        expect(
          city.bottom,
          lessThanOrEqualTo(kbTop),
          reason: 'the field being typed in is above the keyboard',
        );

        // With the keyboard up the last action may need a scroll, but it is
        // reachable and lands above the keyboard, not under it.
        final cancel = find.widgetWithText(HipCta, S.aCancel);
        await tester.ensureVisible(cancel);
        await tester.pumpAndSettle();
        final rect = tester.getRect(cancel);
        expect(rect.bottom, lessThanOrEqualTo(kbTop));
        expect(rect.top, greaterThanOrEqualTo(_status));
      });
    }

    testWidgets('large text on a short phone scrolls instead of cutting off', (
      tester,
    ) async {
      // (At 320dp and 1.6x a long action label overflows sideways inside
      // HipCta, which is a width problem of the button, not of the insets.)
      const short = Size(360, 640);
      _phone(tester, size: short);
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await open(tester, overridden: true);
      await tester.showKeyboard(find.byType(TextField).first);
      _phone(tester, size: short, ime: 260);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final search = tester.getRect(find.byType(TextField).first);
      expect(search.bottom, lessThanOrEqualTo(short.height - 260));
      final cancel = find.widgetWithText(HipCta, S.aCancel);
      await tester.ensureVisible(cancel);
      await tester.pumpAndSettle();
      expect(
        tester.getRect(cancel).bottom,
        lessThanOrEqualTo(short.height - 260),
      );
    });

    testWidgets('with the keyboard down the actions clear the buttons', (
      tester,
    ) async {
      _phone(tester);
      await open(tester, overridden: true);
      expect(tester.takeException(), isNull);
      final cancel = find.widgetWithText(HipCta, S.aCancel);
      await tester.ensureVisible(cancel);
      await tester.pumpAndSettle();
      expect(tester.getRect(cancel).bottom, lessThanOrEqualTo(_h - _buttons));
    });
  });

  group('screens over the navigation bar', () {
    const uuid = '11111111-1111-1111-1111-111111111111';

    for (final nav in [_buttons, _gestures]) {
      final mode = nav == _buttons ? 'buttons' : 'gesture strip';

      testWidgets('Home keeps Connect above the $mode', (tester) async {
        _phone(tester, nav: nav);
        final state = AppState();
        await state.addLink(
          'vless://$uuid@203.0.113.1:443?security=none#de-ber-01',
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: HomeHeroScreen(state: state, nav: _nav()),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(tester.takeException(), isNull);
        final cta = tester.getRect(find.byType(HomeCtaBar));
        expect(cta.bottom, lessThanOrEqualTo(_h - nav));
        // And the hero starts under the status bar, not behind it.
        expect(
          tester.getTopLeft(find.byType(HipWordmark)).dy,
          greaterThanOrEqualTo(_status),
        );
      });

      testWidgets('Locations keeps Add connection above the $mode', (
        tester,
      ) async {
        _phone(tester, nav: nav);
        final own = Location.derive(
          const ProxyProfile(
            name: 'ch-zur-01',
            protocol: 'vless',
            server: '198.51.100.10',
            port: 443,
            outbound: {'type': 'vless'},
          ),
          0,
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: LocationsBody(
                mix: Mix.byo,
                advanced: false,
                subscribed: false,
                showManagedSection: false,
                managedGroup: ManagedGroup.locked,
                managed: const [],
                locked: const [],
                userLocations: [own],
                allLockedShown: false,
                winner: null,
                selectedId: null,
                autoCity: null,
                autoMs: null,
                autoManaged: false,
                pingOf: (_) => null,
                levelOf: (_) => 0,
                nameOf: (l) => l.city,
                subInfoOf: (_) => null,
                onBack: () {},
                onSelect: (_) {},
                onManage: (_) {},
                onLockedTap: (_, _) {},
                onShowAll: () {},
                onSeePlans: () {},
                onAdd: () {},
                onDismissWinner: () {},
                onWinner: (_) {},
              ),
            ),
          ),
        );
        await tester.pump();
        final add = tester.getRect(find.widgetWithText(HipCta, S.tAddConn));
        expect(add.bottom, lessThanOrEqualTo(_h - nav));
        expect(
          tester.getTopLeft(find.text(S.tLocations)).dy,
          greaterThanOrEqualTo(_status),
        );
      });
    }

    Future<void> pumpImport(WidgetTester tester, {ImportHooks? hooks}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ImportScreen(
              state: AppState(),
              nav: _nav(),
              hooks: hooks ?? const ImportHooks(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets(
      'Import keeps its button above the buttons, then the keyboard',
      (tester) async {
        _phone(tester);
        await pumpImport(tester);
        final cta = find.widgetWithText(HipCta, S.eImport);
        expect(tester.getRect(cta).bottom, lessThanOrEqualTo(_h - _buttons));

        await tester.showKeyboard(find.byType(TextField).first);
        _phone(tester, ime: _keyboard);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(tester.getRect(cta).bottom, lessThanOrEqualTo(_h - _keyboard));
        expect(
          tester.getRect(find.byType(TextField).first).bottom,
          lessThanOrEqualTo(_h - _keyboard),
        );
      },
    );

    testWidgets('the import scanner sets light buttons over its dark panel', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: AnnotatedRegion<SystemUiOverlayStyle>(
            value: hipBars(darkTop: false, bottom: Hip.surface),
            child: Scaffold(
              body: Stack(
                children: [
                  QrPopup(
                    onCode: (_) {},
                    onClose: () {},
                    onPasteInstead: () {},
                    camStatus: () async => CamPerm.granted,
                    readerBuilder: (context, {required onCode}) =>
                        const SizedBox.expand(),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        _lastStyle['statusBarIconBrightness'],
        'Brightness.dark',
        reason: 'the light import screen still owns the status bar',
      );
      expect(
        _lastStyle['systemNavigationBarIconBrightness'],
        'Brightness.light',
      );
    });
  });
}
