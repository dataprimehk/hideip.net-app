import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hideip_vpn/core/secret_prefs.dart';
import 'package:hideip_vpn/state/app_state.dart';
import 'package:hideip_vpn/ui/redesign/hero_compact.dart';
import 'package:hideip_vpn/ui/redesign/hip.dart';
import 'package:hideip_vpn/ui/redesign/home_hero.dart';
import 'package:hideip_vpn/ui/redesign/home_status_card.dart';
import 'package:hideip_vpn/ui/redesign/shell.dart';
import 'package:hideip_vpn/ui/strings.dart';

const _uuid = '11111111-1111-1111-1111-111111111111';

String _link(String host, String name) =>
    'vless://$_uuid@$host:443?security=none#$name';

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

Future<AppState> _threeServers() async {
  final state = AppState();
  await state.addLink(_link('203.0.113.1', 'de-ber-01'));
  await state.addLink(_link('203.0.113.2', 'nl-ams-01'));
  await state.addLink(_link('203.0.113.3', 'ch-zur-01'));
  return state;
}

/// Home the way the shell hosts it: a Scaffold, which is what gives the
/// keyboard inset back to the body.
Widget _host(AppState state) => MaterialApp(
      home: Scaffold(body: HomeHeroScreen(state: state, nav: _nav())),
    );

/// A short phone, and the height its keyboard takes.
const _screen = Size(320, 568);
const _keyboard = 260.0;

/// The real faces, so the measurements are the ones the phone makes. The
/// test stand-in font draws every glyph as a square of the font size, which
/// overflows the header at large text where Inter would not.
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

void _usePhone(WidgetTester tester, {double textScale = 1}) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = _screen;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

/// One step past the fold and the settling rebuild after it.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
  await tester.pump(const Duration(milliseconds: 100));
}

/// Focus first, the inset after: the fold starts on focus and the keyboard
/// slides up beside it, so by the time the inset is fully there the hero has
/// already made room. (Both platforms animate the inset; the fold is quicker.)
Future<void> _raiseKeyboard(WidgetTester tester) async {
  await tester.showKeyboard(find.byType(TextField));
  await _settle(tester);
  tester.view.viewInsets = const FakeViewPadding(bottom: _keyboard);
  await tester.pump();
}

Future<void> _dropKeyboard(WidgetTester tester) async {
  FocusManager.instance.primaryFocus?.unfocus();
  tester.view.viewInsets = FakeViewPadding.zero;
  await _settle(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(_loadFonts);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // Each widget test runs in its own fake-async zone. SecretPrefs keeps
    // static write gates whose futures belong to the zone that made them,
    // and a later test awaiting one of those never resumes. A fresh vault
    // clears the gates, so every test starts with gates of its own.
    SecretPrefs.installKeyVaultForTesting(MemorySecureKeyVault());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
    // The ASCII engines behind the card draw one still frame; the fold
    // itself is immediate except where a test turns the motion back on.
    Hip.reducedMotion = true;
  });
  tearDown(() => Hip.reducedMotion = false);

  testWidgets(
      'large text on a short phone: the hero folds and a result stays in view',
      (tester) async {
    _usePhone(tester, textScale: 1.6);
    final state = await _threeServers();
    await tester.pumpWidget(_host(state));
    await tester.pump();

    // The full hero, with the Servers/Map switch and Connect under the list.
    expect(find.byType(HomeStatusCard), findsOneWidget);
    expect(find.text(S.homeSegMap), findsOneWidget);
    expect(find.text(S.tConnect), findsOneWidget);
    expect(find.byType(HeroCompactLine), findsNothing);

    await _raiseKeyboard(tester);

    // Folded: wordmark, the one-line state, the field. Nothing else.
    expect(find.byType(HipWordmark), findsOneWidget);
    expect(find.byType(HeroCompactLine), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byType(HomeStatusCard), findsNothing);
    expect(find.text(S.homeSegMap), findsNothing);
    expect(find.text(S.tConnect), findsNothing);

    await tester.enterText(find.byType(TextField), 'ber');
    await _settle(tester);

    // The result sits whole above the keyboard, and can be tapped.
    final row = find.text('Berlin');
    expect(row, findsOneWidget);
    final rect = tester.getRect(row);
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.bottom, lessThanOrEqualTo(_screen.height - _keyboard));
    expect(row.hitTestable(), findsOneWidget);
    expect(find.text('Amsterdam'), findsNothing);
    expect(tester.takeException(), isNull);

    await _dropKeyboard(tester);
  });

  testWidgets('picking a row from Recent and fastest does not move it',
      (tester) async {
    _usePhone(tester);
    final state = await _threeServers();
    await tester.pumpWidget(_host(state));
    await tester.pump();

    List<String> titles() {
      final rows = find.byType(HipListRow).evaluate().map((e) => e.widget);
      return [
        for (final r in rows.whereType<HipListRow>())
          if (r.title != S.tAuto && r.title != S.homeAllLocations) r.title,
      ];
    }

    final before = titles();
    expect(before.length, 3);
    // The last of the three: a pick pushes it to the front of the recents,
    // which used to lift it to the top of the list right under the finger.
    await tester.ensureVisible(find.text(before.last));
    await tester.pump();
    await tester.tap(find.text(before.last));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(titles(), before);
    expect(state.prefs.recents.first, isNotEmpty);
  });

  testWidgets('the fold animates and nothing overflows on the way',
      (tester) async {
    Hip.reducedMotion = false;
    _usePhone(tester, textScale: 1.6);
    final state = await _threeServers();
    await tester.pumpWidget(_host(state));
    await tester.pump();

    await tester.showKeyboard(find.byType(TextField));
    await tester.pump();
    // Mid-fold both sides are on screen, fading across each other.
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(HeroCompactLine), findsOneWidget);
    expect(find.byType(HomeStatusCard), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(HomeStatusCard), findsNothing);
    tester.view.viewInsets = const FakeViewPadding(bottom: _keyboard);
    await tester.pump();
    expect(tester.takeException(), isNull);

    await _dropKeyboard(tester);
    expect(find.byType(HomeStatusCard), findsOneWidget);
    expect(find.byType(HeroCompactLine), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('focus alone folds the hero, and losing it unfolds it',
      (tester) async {
    _usePhone(tester);
    final state = await _threeServers();
    await tester.pumpWidget(_host(state));
    await tester.pump();

    await _raiseKeyboard(tester);
    expect(find.byType(HeroCompactLine), findsOneWidget);
    expect(find.byType(HomeStatusCard), findsNothing);

    await _dropKeyboard(tester);
    expect(find.byType(HeroCompactLine), findsNothing);
    expect(find.byType(HomeStatusCard), findsOneWidget);
    expect(find.text(S.tConnect), findsOneWidget);
  });

  testWidgets(
      'the keyboard going down unfolds the hero and brings Connect back, '
      'the query still filters', (tester) async {
    _usePhone(tester);
    final state = await _threeServers();
    await tester.pumpWidget(_host(state));
    await tester.pump();

    await _raiseKeyboard(tester);
    await tester.enterText(find.byType(TextField), 'ams');
    expect(find.byType(HeroCompactLine), findsOneWidget);

    // The system drops the keyboard (back gesture, Done) and leaves the
    // field focused: the hero must not stay folded with no way back.
    tester.view.viewInsets = FakeViewPadding.zero;
    await _settle(tester);
    expect(find.byType(HeroCompactLine), findsNothing);
    expect(find.byType(HomeStatusCard), findsOneWidget);
    expect(find.text(S.tConnect), findsOneWidget);
    expect(find.text('Amsterdam'), findsOneWidget);
    expect(find.text('Berlin'), findsNothing);

    await tester.tap(find.byIcon(Icons.close));
    await _settle(tester);
    expect(find.text('Berlin'), findsOneWidget);
  });

  testWidgets('Cancel next to the field ends the search with the keyboard up',
      (tester) async {
    _usePhone(tester);
    final state = await _threeServers();
    await tester.pumpWidget(_host(state));
    await tester.pump();

    await _raiseKeyboard(tester);
    await tester.enterText(find.byType(TextField), 'ams');
    expect(find.byType(HeroCompactLine), findsOneWidget);
    expect(find.text(S.homeSearchCancel), findsOneWidget);

    await tester.tap(find.text(S.homeSearchCancel));
    // Losing the focus takes the keyboard down with it.
    tester.view.viewInsets = FakeViewPadding.zero;
    await _settle(tester);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, isEmpty);
    expect(field.focusNode!.hasFocus, isFalse);
    expect(find.byType(HeroCompactLine), findsNothing);
    expect(find.text(S.tConnect), findsOneWidget);
    expect(find.text('Berlin'), findsOneWidget);
  });

  testWidgets('picking a result ends the search and brings Connect back',
      (tester) async {
    _usePhone(tester);
    final state = await _threeServers();
    await tester.pumpWidget(_host(state));
    await tester.pump();

    await _raiseKeyboard(tester);
    await tester.enterText(find.byType(TextField), 'zur');
    await _settle(tester);
    expect(find.text('Zurich'), findsOneWidget);

    await tester.tap(find.text('Zurich'));
    tester.view.viewInsets = FakeViewPadding.zero;
    await _settle(tester);

    expect(state.selected?.name, 'ch-zur-01');
    expect(state.prefs.autoSelect, isFalse);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, isEmpty);
    expect(field.focusNode!.hasFocus, isFalse);
    expect(find.byType(HomeStatusCard), findsOneWidget);
    expect(find.text(S.tConnect), findsOneWidget);
  });
}
