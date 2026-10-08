import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hideip_vpn/core/premium.dart';
import 'package:hideip_vpn/ui/redesign/hip.dart';
import 'package:hideip_vpn/ui/redesign/paywall_screen.dart';
import 'package:hideip_vpn/ui/strings.dart';

/// A phone the app ships to: the logical screen plus the insets the system
/// keeps for itself (status bar, gesture bar / home indicator).
class _Phone {
  final String name;
  final Size size;
  final double dpr;
  final double top;
  final double bottom;
  const _Phone(this.name, this.size, this.dpr,
      {required this.top, required this.bottom});
}

const _phones = [
  _Phone('Pixel 6a', Size(412, 915), 2.625, top: 24, bottom: 24),
  _Phone('iPhone 14', Size(390, 844), 3, top: 47, bottom: 34),
];

Widget _paywall(PremiumPlan plan, {String? city, int? freeMbps}) => MaterialApp(
      home: Scaffold(
          backgroundColor: Hip.dark,
          body: PaywallLayout(
            onClose: () {},
            offer: PaywallOffer(
              yearly: PlanInfo.yearly,
              monthly: PlanInfo.monthly,
              plan: plan,
              onPlan: (_) {},
              city: city,
              locationCount: 12,
              trialEnds: 'Sep 7, 2026',
              storeName: 'App Store',
              onBuy: () {},
              onRestore: () {},
              onTerms: () {},
              onPrivacy: () {},
              freeMbps: freeMbps,
            ),
          )),
    );

/// Pins the view to one phone for the length of a test.
void _use(WidgetTester tester, _Phone phone) {
  tester.view.devicePixelRatio = phone.dpr;
  tester.view.physicalSize = phone.size * phone.dpr;
  tester.view.padding = FakeViewPadding(
    top: phone.top * phone.dpr,
    bottom: phone.bottom * phone.dpr,
  );
  addTearDown(tester.view.reset);
}

/// On screen and drawn: inside the phone, with a size worth looking at.
void _expectOnScreen(WidgetTester tester, Finder finder, _Phone phone) {
  expect(finder, findsOneWidget);
  final rect = tester.getRect(finder);
  expect(rect.width, greaterThan(0));
  expect(rect.height, greaterThan(0));
  expect(rect.top, greaterThanOrEqualTo(0));
  expect(rect.left, greaterThanOrEqualTo(0));
  expect(rect.right, lessThanOrEqualTo(phone.size.width));
  expect(rect.bottom, lessThanOrEqualTo(phone.size.height));
}

/// How far the offer could be scrolled. The design lays the paywall out as
/// one flex column that fills the screen (app.css `.pw-body`), so on a phone
/// this app ships to the answer has to be zero.
double _scrollableBy(WidgetTester tester) =>
    tester.state<ScrollableState>(find.byType(Scrollable)).position
        .maxScrollExtent;

/// The real faces, so the measurements are the ones the phone makes. The
/// test stand-in font draws every glyph as a square of the font size, which
/// wraps this screen where Inter would not.
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(_loadFonts);

  for (final phone in _phones) {
    group('the paywall fits a ${phone.name}', () {
      testWidgets('nothing overflows and nothing scrolls', (tester) async {
        _use(tester, phone);
        await tester.pumpWidget(_paywall(PremiumPlan.yearly));

        expect(tester.takeException(), isNull);
        expect(_scrollableBy(tester), 0);
      });

      testWidgets('the brand badge and the button are both on screen',
          (tester) async {
        _use(tester, phone);
        await tester.pumpWidget(_paywall(PremiumPlan.yearly));

        _expectOnScreen(tester, find.byType(PaywallBrandBadge), phone);
        _expectOnScreen(tester, find.text(S.pwCtaTrial), phone);
        // The badge is the lockup, and the lockup is the wordmark: the old
        // gradient Premium pill has no place at the top of this screen.
        expect(find.byType(PremiumBadge), findsNothing);
      });

      testWidgets('the monthly plan fits too', (tester) async {
        _use(tester, phone);
        await tester.pumpWidget(_paywall(PremiumPlan.monthly));

        expect(tester.takeException(), isNull);
        expect(_scrollableBy(tester), 0);
        _expectOnScreen(tester, find.text(S.pwCtaBuy), phone);
      });

      testWidgets('the free line under the title does not push it off',
          (tester) async {
        _use(tester, phone);
        await tester.pumpWidget(
            _paywall(PremiumPlan.yearly, city: 'Amsterdam', freeMbps: 10));

        expect(find.text(S.pwSubFree(10)), findsOneWidget);
        expect(find.text(S.pwSub), findsNothing);
        expect(tester.takeException(), isNull);
        expect(_scrollableBy(tester), 0);
        _expectOnScreen(tester, find.text(S.pwCtaTrial), phone);
      });

      testWidgets('a city headline does not push the button off',
          (tester) async {
        _use(tester, phone);
        await tester.pumpWidget(_paywall(PremiumPlan.yearly, city: 'Amsterdam'));

        expect(tester.takeException(), isNull);
        expect(_scrollableBy(tester), 0);
        _expectOnScreen(tester, find.text(S.pwCtaTrial), phone);
      });
    });
  }
}
