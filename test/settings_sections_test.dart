import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hideip_vpn/core/notifications.dart';
import 'package:hideip_vpn/core/ui_prefs.dart';
import 'package:hideip_vpn/state/app_state.dart';
import 'package:hideip_vpn/ui/redesign/hip.dart';
import 'package:hideip_vpn/ui/brand.dart';
import 'package:hideip_vpn/ui/redesign/settings_screen.dart';
import 'package:hideip_vpn/ui/redesign/shell.dart';
import 'package:hideip_vpn/ui/strings.dart';

Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child)));

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

Widget _notifications(
  NotifPerm perm, {
  bool connAlerts = true,
  bool votingNotifs = false,
  ValueChanged<bool>? onConnAlerts,
  ValueChanged<bool>? onVoting,
  VoidCallback? onPrePrompt,
  VoidCallback? onOpenSettings,
}) =>
    _host(NotificationRows(
      perm: perm,
      connAlerts: connAlerts,
      votingNotifs: votingNotifs,
      onConnAlerts: onConnAlerts ?? (_) {},
      onVoting: onVoting ?? (_) {},
      onPrePrompt: onPrePrompt ?? () {},
      onOpenSettings: onOpenSettings ?? () {},
    ));

void main() {
  group('notifications, three permission states', () {
    testWidgets('allowed shows both switches and what they do',
        (tester) async {
      await tester.pumpWidget(_notifications(NotifPerm.granted));

      expect(find.text('Connection alerts'), findsOneWidget);
      expect(find.text('Tell you if the VPN drops'), findsOneWidget);
      expect(find.text('Voting updates'), findsOneWidget);
      expect(find.text('When a location you voted for becomes available'),
          findsOneWidget);
      expect(find.byType(HipToggle), findsNWidgets(2));
      expect(find.text('Open settings'), findsNothing);
    });

    testWidgets('refused replaces both switches with one line and one action',
        (tester) async {
      await tester.pumpWidget(_notifications(NotifPerm.denied));

      expect(find.text('Notifications are turned off in system settings.'),
          findsNWidgets(2));
      expect(find.text('Open settings'), findsNWidgets(2));
      expect(find.byType(HipToggle), findsNothing);
      expect(find.text('Tell you if the VPN drops'), findsNothing);
    });

    testWidgets('refused walks the user into system settings', (tester) async {
      var opened = 0;
      await tester.pumpWidget(
          _notifications(NotifPerm.denied, onOpenSettings: () => opened++));

      await tester.tap(find.text('Open settings').first);
      expect(opened, 1);
    });

    testWidgets('never asked explains before the system dialog',
        (tester) async {
      var prompted = 0;
      var written = 0;
      await tester.pumpWidget(_notifications(
        NotifPerm.ask,
        onPrePrompt: () => prompted++,
        onVoting: (_) => written++,
      ));

      // The second toggle is Voting updates.
      await tester.tap(find.byType(HipToggle).last);
      expect(prompted, 1);
      expect(written, 0, reason: 'the preference waits for the answer');
    });

    testWidgets('turning voting updates off never re-asks', (tester) async {
      var prompted = 0;
      bool? written;
      await tester.pumpWidget(_notifications(
        NotifPerm.ask,
        votingNotifs: true,
        onPrePrompt: () => prompted++,
        onVoting: (v) => written = v,
      ));

      await tester.tap(find.byType(HipToggle).last);
      expect(prompted, 0);
      expect(written, isFalse);
    });
  });

  group('theme', () {
    testWidgets('the segment offers all three modes', (tester) async {
      await tester.pumpWidget(_host(
          ThemeSegment(mode: AppThemeMode.system, onChanged: (_) {})));

      expect(find.text('Light'), findsOneWidget);
      expect(find.text('Dark'), findsOneWidget);
      expect(find.text('System'), findsOneWidget);
    });

    testWidgets('picking one reports it', (tester) async {
      final picked = <AppThemeMode>[];
      await tester.pumpWidget(_host(
          ThemeSegment(mode: AppThemeMode.system, onChanged: picked.add)));

      await tester.tap(find.text('Dark'));
      await tester.tap(find.text('Light'));
      expect(picked, [AppThemeMode.dark, AppThemeMode.light]);
    });

    testWidgets('the mode it is given is the one it shows', (tester) async {
      var mode = AppThemeMode.system;
      await tester.pumpWidget(_host(StatefulBuilder(
        builder: (context, setState) => ThemeSegment(
          mode: mode,
          onChanged: (m) => setState(() => mode = m),
        ),
      )));

      await tester.tap(find.text('Dark'));
      await tester.pumpAndSettle();
      expect(mode, AppThemeMode.dark);
    });
  });

  group('speed mode against the device limit', () {
    Widget speedRow({
      required bool deviceLimit,
      required bool start,
      required VoidCallback onLimit,
      List<bool>? writes,
    }) {
      var on = start;
      return _host(StatefulBuilder(
        builder: (context, setState) => HipListGroup(children: [
          SpeedModeRow(
            speedMode: on,
            deviceLimit: deviceLimit,
            onDeviceLimit: onLimit,
            onChanged: (v) {
              writes?.add(v);
              setState(() => on = v);
            },
          ),
        ]),
      ));
    }

    testWidgets('a sixth device explains instead of flipping the switch',
        (tester) async {
      var raised = 0;
      final writes = <bool>[];
      await tester.pumpWidget(speedRow(
        deviceLimit: true,
        start: false,
        onLimit: () => raised++,
        writes: writes,
      ));

      await tester.tap(find.byType(HipToggle));
      await tester.pumpAndSettle();

      expect(raised, 1);
      expect(writes, isEmpty, reason: 'nothing is written on a full account');
      expect(tester.widget<HipToggle>(find.byType(HipToggle)).on, isFalse,
          reason: 'the switch does not move and spring back');
    });

    testWidgets('a full account reads as off even when the intent was on',
        (tester) async {
      await tester.pumpWidget(speedRow(
        deviceLimit: true,
        start: true,
        onLimit: () {},
      ));

      expect(tester.widget<HipToggle>(find.byType(HipToggle)).on, isFalse);
    });

    testWidgets('with a slot free the switch works normally', (tester) async {
      final writes = <bool>[];
      await tester.pumpWidget(speedRow(
        deviceLimit: false,
        start: false,
        onLimit: () => fail('no limit to report'),
        writes: writes,
      ));

      await tester.tap(find.byType(HipToggle));
      await tester.pumpAndSettle();

      expect(writes, [true]);
      expect(tester.widget<HipToggle>(find.byType(HipToggle)).on, isTrue);
    });
  });

  group('the card that sells', () {
    testWidgets('states the price and what happens after the free week',
        (tester) async {
      await tester.pumpWidget(_host(
          PremiumSalesCard(yearlyPrice: r'$29.99', onTap: () {})));

      expect(find.text('Every location, stealth by default.'), findsOneWidget);
      expect(
          find.text(
              'All hideip.net locations, Speed mode, no logs, no account.'),
          findsOneWidget);
      expect(find.text('Try 7 days free'), findsOneWidget);
      expect(find.textContaining(r'Then $29.99 per year. Cancel anytime.'),
          findsOneWidget);
    });
  });

  group('the billing line puts its date in mono', () {
    List<TextSpan> runs(InlineSpan span) =>
        (span as TextSpan).children!.cast<TextSpan>();

    test('the sentence stays in the body face, the date does not', () {
      final line = runs(monoWithin(
          S.setPremiumTrial('Sep 5, 2026'), const ['Sep 5, 2026']));

      expect(line.map((r) => r.text).join(), 'Free trial; ends Sep 5, 2026');
      expect(line.first.text, 'Free trial; ends ');
      expect(line.first.style!.fontFamily, Brand.bodyFont);
      expect(line.last.text, 'Sep 5, 2026');
      expect(line.last.style!.fontFamily, Brand.monoFont);
    });

    test('the plan name is a word, so it keeps the body face', () {
      final line = runs(monoWithin(
          S.setPremiumActive('Yearly', 'Sep 5, 2026'), const ['Sep 5, 2026']));

      expect(line.map((r) => r.text).join(), 'Yearly plan; renews Sep 5, 2026');
      expect(line.first.style!.fontFamily, Brand.bodyFont);
      expect(line.last.style!.fontFamily, Brand.monoFont);
    });

    test('a line with no number is one plain run', () {
      final line = runs(monoWithin(S.setPremiumEnded, const []));

      expect(line, hasLength(1));
      expect(line.single.text, 'Subscription ended; not renewing');
      expect(line.single.style!.fontFamily, Brand.bodyFont);
    });

    test('a date in front of the sentence still comes out mono', () {
      // What a translation is free to do with the same constant.
      final line = runs(monoWithin('Sep 5, 2026 is when it renews',
          const ['Sep 5, 2026']));

      expect(line.first.text, 'Sep 5, 2026');
      expect(line.first.style!.fontFamily, Brand.monoFont);
      expect(line.last.text, ' is when it renews');
      expect(line.last.style!.fontFamily, Brand.bodyFont);
    });

    test('a fragment the line does not contain is skipped', () {
      final line = runs(monoWithin(S.setPremiumNone, const ['Sep 5, 2026']));

      expect(line, hasLength(1));
      expect(line.single.text, 'Not subscribed; 7 days free to start');
    });
  });

  group('section headers', () {
    // Settings is a lazy ListView: on a phone-sized test surface the
    // sections below the fold are never built, so the tree is inspected on
    // a tall one.
    setUp(() {
      final view = TestWidgetsFlutterBinding.ensureInitialized()
          .platformDispatcher
          .views
          .first;
      view.physicalSize = const Size(1000, 4000);
      view.devicePixelRatio = 1;
      addTearDown(view.resetPhysicalSize);
      addTearDown(view.resetDevicePixelRatio);
    });

    Widget settings() => MaterialApp(
          home:
              Scaffold(body: SettingsScreen(state: AppState(), nav: _nav())),
        );

    testWidgets('every section label carries its icon, in the muted tone',
        (tester) async {
      Hip.reducedMotion = true;
      addTearDown(() => Hip.reducedMotion = false);
      await tester.pumpWidget(settings());
      await tester.pump();

      // Account is conditional on an offered subscription, which a bare
      // AppState never has; the sections below always show.
      const sections = {
        S.setInterface: Icons.tune_outlined,
        S.setConnection: Icons.bolt_outlined,
        S.setNotifications: Icons.notifications_outlined,
        S.setPrivacySection: Icons.privacy_tip_outlined,
        S.setConnections: Icons.dns_outlined,
        S.setHelp: Icons.help_outline,
      };
      for (final entry in sections.entries) {
        final header = tester.widget<SettingsSectionHeader>(find.ancestor(
          of: find.text(entry.key.toUpperCase()),
          matching: find.byType(SettingsSectionHeader),
        ));
        expect(header.icon, entry.value, reason: entry.key);
      }
    });

    testWidgets('the row count in every unconditional section is unchanged',
        (tester) async {
      Hip.reducedMotion = true;
      addTearDown(() => Hip.reducedMotion = false);
      await tester.pumpWidget(settings());
      await tester.pump();

      // Interface: theme row plus the advanced-view toggle.
      expect(find.text(S.setTheme), findsOneWidget);
      expect(find.text(S.setAdvanced), findsOneWidget);
      // Connection: auto-connect and kill switch always show; speed mode
      // and routing are conditional and are not part of this count.
      expect(find.text(S.setAutoConnect), findsOneWidget);
      expect(find.text(S.tKill), findsOneWidget);
      // Notifications: exactly two rows, whatever the permission state.
      expect(find.text(S.notifConnTitle), findsOneWidget);
      expect(find.text(S.notifVoteTitle), findsOneWidget);
      // Privacy: still the one row it always was.
      expect(find.text(S.setUsage), findsOneWidget);
      // Connections: add and manage.
      expect(find.text(S.tAddConn), findsOneWidget);
      expect(find.text(S.setManageServers), findsOneWidget);
      // Help: replay intro, privacy policy, terms.
      expect(find.text(S.setIntroAgain), findsOneWidget);
      expect(find.text(S.setPrivacyPolicy), findsOneWidget);
      expect(find.text(S.setTerms), findsOneWidget);
    });
  });
}
