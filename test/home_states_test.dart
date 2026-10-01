import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hideip_vpn/state/app_state.dart';
import 'package:hideip_vpn/ui/redesign/hip.dart';
import 'package:hideip_vpn/ui/redesign/hip_sheet.dart';
import 'package:hideip_vpn/ui/redesign/home_banners.dart';
import 'package:hideip_vpn/ui/redesign/home_hero.dart';
import 'package:hideip_vpn/ui/redesign/home_status_card.dart';
import 'package:hideip_vpn/ui/strings.dart';
import 'package:hideip_vpn/vpn_controller.dart';

/// Each pinned Home state from the Screen Atlas, built from the plain values
/// the screen would hand its pieces. The pieces take values rather than the
/// app state precisely so every state is one pump away.
Widget host(Widget child) => MaterialApp(
      home: Scaffold(body: Center(child: child)),
    );

/// Whether a call to action is live. A disabled one still renders (the Atlas
/// keeps Connect visible offline, with the reason under it); what changes is
/// that it no longer does anything.
bool ctaEnabled(WidgetTester tester, String label) {
  final cta = tester.widget<HipCta>(
    find.byWidgetPredicate((w) => w is HipCta && w.label == label),
  );
  return cta.onTap != null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // The copy affordance writes to the system clipboard; in a test the
    // channel needs an answer for the write to complete.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
    // Freezes the pulsing dot and the handshake spinner, so a pump is enough
    // and no test has to wait on a loop that never ends.
    Hip.reducedMotion = true;
  });
  tearDown(() => Hip.reducedMotion = false);

  // --- B0 -----------------------------------------------------------------
  testWidgets('B0 explains the empty Home and offers no Connect',
      (tester) async {
    await tester.pumpWidget(host(Column(children: [
      const HomeEmptyBlock(),
      HomeCtaBar(
        empty: true,
        connected: false,
        disconnecting: false,
        connecting: false,
        offline: false,
        denied: false,
        onConnect: () {},
        onCancel: () {},
        onDisconnect: () {},
        onAdd: () {},
        onSeePremium: () {},
      ),
    ])));

    expect(find.text(S.b0Title), findsOneWidget);
    expect(find.text(S.b0Body), findsOneWidget);
    expect(find.text(S.tAddConn), findsOneWidget);
    expect(find.text(S.b0SeePremium), findsOneWidget);
    // The contract: no server means nothing to connect to, so the action is
    // not offered at all.
    expect(find.text(S.tConnect), findsNothing);
  });

  testWidgets('B0 offers account sign-in as one quiet line when asked',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(host(HomeEmptyBlock(onSignIn: () => taps++)));
    expect(find.text(S.accountSignInLink), findsOneWidget);
    await tester.tap(find.text(S.accountSignInLink));
    expect(taps, 1);

    // Without a callback (already signed in, or sign-in switched off) the
    // block is the plain explanation.
    await tester.pumpWidget(host(const HomeEmptyBlock()));
    expect(find.text(S.accountSignInLink), findsNothing);
  });

  // --- B1 -----------------------------------------------------------------
  testWidgets('B1 shows the real address as exposed', (tester) async {
    await tester.pumpWidget(host(const HomeStatusCard(
      tone: StatusTone.risk,
      status: S.tExposed,
      ip: '151.241.151.103',
      context: 'Telekom Srbija · Belgrade, RS',
    )));

    expect(find.text(S.tExposed.toUpperCase()), findsOneWidget);
    expect(find.text('151.241.151.103'), findsOneWidget);
    expect(find.text('Telekom Srbija · Belgrade, RS'), findsOneWidget);
    expect(find.text(S.b16Slow), findsNothing);
  });

  testWidgets('B1 copy icon turns into a check for a moment', (tester) async {
    await tester.pumpWidget(host(const HomeStatusCard(
      tone: StatusTone.risk,
      status: S.tExposed,
      ip: '151.241.151.103',
      context: 'Telekom Srbija · Belgrade, RS',
    )));

    expect(find.byIcon(Icons.copy_outlined), findsOneWidget);
    await tester.tap(find.byIcon(Icons.copy_outlined));
    await tester.pump();
    await tester.pump();
    expect(find.byIcon(Icons.check), findsOneWidget);
    // The check is a confirmation, not a state: it steps back on its own.
    await tester.pump(const Duration(milliseconds: 1500));
    expect(find.byIcon(Icons.copy_outlined), findsOneWidget);
  });

  // --- B2 -----------------------------------------------------------------
  testWidgets('B2 keeps the call to action live so it can be cancelled',
      (tester) async {
    var cancelled = false;
    await tester.pumpWidget(host(Column(children: [
      const HomeStatusCard(
        tone: StatusTone.busy,
        status: S.tConnecting,
        ip: '151.241.151.103',
        context: 'Telekom Srbija · Belgrade, RS',
      ),
      HomeCtaBar(
        empty: false,
        connected: false,
        disconnecting: false,
        connecting: true,
        offline: false,
        denied: false,
        onConnect: () {},
        onCancel: () => cancelled = true,
        onDisconnect: () {},
        onAdd: () {},
        onSeePremium: () {},
      ),
    ])));

    expect(find.text(S.tConnecting.toUpperCase()), findsOneWidget);
    expect(ctaEnabled(tester, S.tConnecting), isTrue);
    await tester.tap(find.text(S.tConnecting));
    expect(cancelled, isTrue);
  });

  // --- B3, B4, B5 ---------------------------------------------------------
  testWidgets('B3 names the tunnel in words and times the session',
      (tester) async {
    await tester.pumpWidget(host(Column(children: [
      const HomeStatusCard(
        tone: StatusTone.safe,
        status: S.tProtected,
        ip: '185.130.47.77',
        context: 'Frankfurt, Germany',
      ),
      HomeSessionCard(
        stats: const VpnStats(downlink: 6396313, uplink: 219136, downlinkTotal: 0, uplinkTotal: 0),
        duration: const Duration(minutes: 4, seconds: 7),
        chip: S.tunnelStealth(S.tVless),
        fast: false,
        advanced: false,
      ),
    ])));

    expect(find.text(S.tProtected.toUpperCase()), findsOneWidget);
    expect(find.text('Stealth · VLESS'), findsOneWidget);
    expect(find.text(fmtDur(const Duration(minutes: 4, seconds: 7))),
        findsOneWidget);
  });

  testWidgets('B4 says Speed mode and WireGuard as a pair', (tester) async {
    await tester.pumpWidget(host(HomeSessionCard(
      stats: const VpnStats(downlink: 6396313, uplink: 219136, downlinkTotal: 0, uplinkTotal: 0),
      duration: const Duration(minutes: 12),
      chip: S.tunnelSpeed,
      fast: true,
      advanced: false,
    )));

    expect(find.text('Speed mode · WireGuard'), findsOneWidget);
    expect(find.byIcon(Icons.bolt), findsOneWidget);
  });

  testWidgets('B5 states the fallback calmly on the card', (tester) async {
    await tester.pumpWidget(host(HomeSessionCard(
      stats: const VpnStats(downlink: 1048576, uplink: 4096, downlinkTotal: 0, uplinkTotal: 0),
      duration: const Duration(minutes: 2, seconds: 30),
      chip: S.tunnelBlocked,
      fast: false,
      advanced: false,
    )));

    expect(find.text('Stealth · WireGuard blocked here'), findsOneWidget);
    // A fallback is the app working as designed: no alarm, no bolt.
    expect(find.byIcon(Icons.bolt), findsNothing);
  });

  // --- B6 -----------------------------------------------------------------
  testWidgets('B6 leads with Try again and sells last', (tester) async {
    ConnectFailedChoice? picked;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => TextButton(
            onPressed: () async {
              picked = await showHipSheet<ConnectFailedChoice>(
                ctx,
                children: const [ConnectFailedSheet(offerPlans: true)],
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text(S.b6Title), findsOneWidget);
    expect(find.text(S.aTryAgain), findsOneWidget);
    expect(find.text(S.b6Another), findsOneWidget);
    expect(find.text(S.aSeePlans), findsOneWidget);

    await tester.tap(find.text(S.aTryAgain));
    await tester.pumpAndSettle();
    expect(picked, ConnectFailedChoice.retry);
  });

  testWidgets('B6 without a subscription is the only one that offers plans',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => TextButton(
            onPressed: () => showHipSheet<ConnectFailedChoice>(
              ctx,
              children: const [ConnectFailedSheet(offerPlans: false)],
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text(S.aSeePlans), findsNothing);
  });

  // --- B7 -----------------------------------------------------------------
  testWidgets('B7 sells Speed mode once and can be waved away',
      (tester) async {
    var dismissed = false;
    var opened = false;
    await tester.pumpWidget(host(HomeUpsellRow(
      onTap: () => opened = true,
      onDismiss: () => dismissed = true,
    )));

    expect(find.text(S.b7Title), findsOneWidget);
    expect(find.text(S.b7Body), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    expect(dismissed, isTrue);
    expect(opened, isFalse);
  });

  // --- B8 -----------------------------------------------------------------
  testWidgets('B8 puts the value first and the price second', (tester) async {
    await tester.pumpWidget(host(HomeTrialBanner(
      price: r'$29.99',
      onKeep: () {},
    )));

    expect(find.text(S.b8Title), findsOneWidget);
    expect(find.text(S.b8Action), findsOneWidget);
    expect(
      find.byWidgetPredicate((w) =>
          w is RichText && w.text.toPlainText().contains(r'$29.99')),
      findsOneWidget,
    );
  });

  // --- B9 -----------------------------------------------------------------
  testWidgets('B9 offers the clipboard link and imports nothing on its own',
      (tester) async {
    var added = false;
    var dismissed = false;
    await tester.pumpWidget(host(HomeClipboardBanner(
      preview: 'vless://…@quietproxy.example',
      onAdd: () => added = true,
      onDismiss: () => dismissed = true,
    )));

    expect(find.text(S.b9Line), findsOneWidget);
    expect(find.text('vless://…@quietproxy.example'), findsOneWidget);
    expect(added, isFalse);

    await tester.tap(find.text(S.b9Add));
    expect(added, isTrue);
    await tester.tap(find.byIcon(Icons.close));
    expect(dismissed, isTrue);
  });

  // --- B13 ----------------------------------------------------------------
  testWidgets('B13 explains the one system permission before the first tap',
      (tester) async {
    bool? go;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => TextButton(
            onPressed: () async {
              go = await showHipSheet<bool>(ctx,
                  children: const [VpnPrimerSheet()]);
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text(S.b13Title), findsOneWidget);
    expect(find.text(S.b13Body), findsOneWidget);
    expect(find.text(S.aContinue), findsOneWidget);
    expect(find.text(S.aNotNow), findsOneWidget);

    await tester.tap(find.text(S.aNotNow));
    await tester.pumpAndSettle();
    expect(go, isFalse);
  });

  // --- B14 ----------------------------------------------------------------
  testWidgets('B14 names the declined permission and the way out',
      (tester) async {
    var opened = false;
    await tester.pumpWidget(host(Column(children: [
      HomeDeniedBanner(onOpenSettings: () => opened = true),
      HomeCtaBar(
        empty: false,
        connected: false,
        disconnecting: false,
        connecting: false,
        offline: false,
        denied: true,
        onConnect: () {},
        onCancel: () {},
        onDisconnect: () {},
        onAdd: () {},
        onSeePremium: () {},
      ),
    ])));

    expect(find.text(S.b14Line), findsOneWidget);
    expect(find.text(S.aOpenSettings), findsOneWidget);
    expect(ctaEnabled(tester, S.tConnect), isFalse);

    await tester.tap(find.text(S.aOpenSettings));
    expect(opened, isTrue);
  });

  // --- B15 ----------------------------------------------------------------
  testWidgets('B15 turns the card neutral and states why Connect is off',
      (tester) async {
    await tester.pumpWidget(host(Column(children: [
      const HomeStatusCard(
        tone: StatusTone.off,
        status: S.b15Status,
        context: S.b15Context,
      ),
      HomeCtaBar(
        empty: false,
        connected: false,
        disconnecting: false,
        connecting: false,
        offline: true,
        denied: false,
        onConnect: () {},
        onCancel: () {},
        onDisconnect: () {},
        onAdd: () {},
        onSeePremium: () {},
      ),
    ])));

    expect(find.text(S.b15Status.toUpperCase()), findsOneWidget);
    expect(find.text(S.b15Context), findsOneWidget);
    expect(find.text(S.b15CtaNote), findsOneWidget);
    // Without a network there is no address to show and nothing to connect.
    expect(find.byIcon(Icons.copy_outlined), findsNothing);
    expect(ctaEnabled(tester, S.tConnect), isFalse);
  });

  // --- B16 ----------------------------------------------------------------
  testWidgets('B16 adds the handshake line ten seconds in', (tester) async {
    await tester.pumpWidget(host(const _SlowHarness()));

    expect(find.text(S.b16Slow), findsNothing);
    await tester.pump(const Duration(seconds: 9));
    expect(find.text(S.b16Slow), findsNothing);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text(S.b16Slow), findsOneWidget);
    // The card still says what it said; the line is an addition, not a swap.
    expect(find.text(S.tConnecting.toUpperCase()), findsOneWidget);
  });
}

/// A connect that has not landed. Mirrors the ten second timer the state
/// layer runs, so the card can be checked before and after it fires.
class _SlowHarness extends StatefulWidget {
  const _SlowHarness();

  @override
  State<_SlowHarness> createState() => _SlowHarnessState();
}

class _SlowHarnessState extends State<_SlowHarness> {
  bool _slow = false;
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer(const Duration(seconds: 10), () {
      if (mounted) setState(() => _slow = true);
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => HomeStatusCard(
        tone: StatusTone.busy,
        status: S.tConnecting,
        ip: '151.241.151.103',
        context: 'Telekom Srbija · Belgrade, RS',
        slowLine: _slow ? S.b16Slow : null,
      );
}
