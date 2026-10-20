import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hideip_vpn/core/secret_prefs.dart';
import 'package:hideip_vpn/state/app_state.dart';
import 'package:hideip_vpn/ui/redesign/hip.dart';
import 'package:hideip_vpn/ui/redesign/home_hero.dart';
import 'package:hideip_vpn/ui/strings.dart';
import 'package:hideip_vpn/vpn_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/account_fakes.dart';

class _ConnectedState extends AppState {
  @override
  bool get isConnected => true;
  @override
  Duration get sessionLength =>
      const Duration(hours: 12, minutes: 34, seconds: 56);
  @override
  VpnStats get stats => const VpnStats(
    uplink: 12345678,
    downlink: 98765432,
    uplinkTotal: 0,
    downlinkTotal: 0,
  );
  @override
  Future<void> pingAll() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    for (final name in ['Inter', 'Onest', 'Geist', 'JetBrainsMono']) {
      await (FontLoader(
        name,
      )..addFont(rootBundle.load('assets/fonts/$name-Variable.ttf'))).load();
    }
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SecretPrefs.installKeyVaultForTesting(MemorySecureKeyVault());
    Hip.reducedMotion = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });
  tearDown(() => Hip.reducedMotion = false);

  for (final screen in [const Size(390, 844), const Size(320, 568)]) {
    for (final scale in [1.0, 2.0, 3.2]) {
      testWidgets('connected Home remains usable at $screen with text $scale', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = screen;
        tester.view.padding = const FakeViewPadding(top: 59, bottom: 34);
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final state = _ConnectedState();
        await state.addLink(
          'vless://11111111-1111-1111-1111-111111111111@203.0.113.1:443?security=none#nl-ams-01',
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListenableBuilder(
                listenable: state,
                builder: (context, _) =>
                    HomeHeroScreen(state: state, nav: fakeNav()),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        final segment = tester.renderObject<RenderParagraph>(
          find.text(S.homeSegServers),
        );
        expect(
          segment.getBoxesForSelection(
            TextSelection(baseOffset: 0, extentOffset: S.homeSegServers.length),
          ),
          hasLength(1),
        );

        // The primary action remains on screen and its entire label fits.
        final action = find.text(S.tDisconnect);
        expect(action.hitTestable(), findsOneWidget);
        final text = tester.renderObject<RenderParagraph>(action);
        final button = tester.getRect(
          find.ancestor(of: action, matching: find.byType(HipCta)),
        );
        expect(text.didExceedMaxLines, isFalse);
        expect(tester.getRect(action).height, lessThanOrEqualTo(button.height));

        // Neither a long session nor high transfer rates lose their values.
        final session = find.byType(HomeSessionCard);
        await tester.ensureVisible(session);
        await tester.pump();
        expect(find.text(fmtDur(state.sessionLength)), findsOneWidget);
        expect(tester.takeException(), isNull);

        final locations = find.descendant(
          of: find.byType(HipSectionLabel),
          matching: find.text(S.homeAllLocations),
        );
        await tester.ensureVisible(locations);
        await tester.pump();
        expect(locations.hitTestable(), findsOneWidget);
        if (scale > 1.6) {
          expect(tester.getRect(locations).top, greaterThanOrEqualTo(59));
        }
        expect(tester.takeException(), isNull);

        final search = find.byType(TextField);
        await tester.ensureVisible(search);
        await tester.showKeyboard(search);
        await tester.pump();
        tester.view.viewInsets = const FakeViewPadding(bottom: 260);
        await tester.pump();
        await tester.enterText(search, 'Amsterdam');
        await tester.pump();
        expect(tester.takeException(), isNull);
        final fieldText = tester.widget<TextField>(search).style!;
        expect(
          MediaQuery.textScalerOf(
            tester.element(search),
          ).scale(fieldText.fontSize!),
          greaterThanOrEqualTo(fieldText.fontSize! * scale),
        );
        tester.view.viewInsets = FakeViewPadding.zero;
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();
        if (scale == 3.2) {
          await tester.ensureVisible(find.text(S.homeSegMap));
          await tester.tap(find.text(S.homeSegMap));
          await tester.pump();
          expect(tester.takeException(), isNull);
          expect(action.hitTestable(), findsOneWidget);
        }
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
        state.dispose();
      });
    }
  }
  for (final scale in [2.0, 3.2]) {
    testWidgets('large text keeps a badged server name complete at $scale', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 568);
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: HipListGroup(
                children: [
                  HipListRow(
                    leading: const HipFlag(cc: 'NL'),
                    title: 'Amsterdam',
                    titleBadge: const HipBrandTag(),
                    subtitle: 'Netherlands',
                    trailing: const HipBars(level: 4),
                    onTap: () {},
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      final name = tester.renderObject<RenderParagraph>(find.text('Amsterdam'));
      expect(name.didExceedMaxLines, isFalse);
      final badge = tester.getRect(find.byType(HipBrandTag));
      expect(
        badge.top,
        greaterThanOrEqualTo(tester.getRect(find.text('Amsterdam')).bottom),
      );
      expect(tester.takeException(), isNull);
    });
  }
}
