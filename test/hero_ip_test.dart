import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hideip_vpn/core/haptics.dart';
import 'package:hideip_vpn/core/ip_lookup.dart';
import 'package:hideip_vpn/ui/redesign/hero_ip_sheet.dart';
import 'package:hideip_vpn/ui/redesign/hip.dart';
import 'package:hideip_vpn/ui/redesign/hip_sheet.dart';
import 'package:hideip_vpn/ui/redesign/home_status_card.dart';
import 'package:hideip_vpn/ui/strings.dart';

const _ip = '151.241.151.103';

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: Center(child: child)),
    );

/// A page with one button that raises the sheet, the way the hero does.
Widget _sheetHost(HeroIpDetails details, ValueChanged<String> onCopy) =>
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showHipSheet<void>(context, children: [
              HeroIpSheet(initial: details, onCopy: onCopy),
            ]),
            child: const Text('open'),
          ),
        ),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// What the last Clipboard.setData carried, read off the platform channel.
  String? clipboard;
  final pulses = <HapticKind, int>{};

  setUp(() {
    clipboard = null;
    pulses.clear();
    Haptics.sink = (k) => pulses[k] = (pulses[k] ?? 0) + 1;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    Hip.reducedMotion = true;
    HeroIpSheet.lookup = () async => null;
  });

  tearDown(() {
    Haptics.sink = null;
    Hip.reducedMotion = false;
    HeroIpSheet.lookup = IpLookup.locate;
  });

  group('the address row', () {
    testWidgets('a tap anywhere on the row copies, ticks, and shows a check',
        (tester) async {
      await tester.pumpWidget(_host(const HomeStatusCard(
        tone: StatusTone.risk,
        status: S.tExposed,
        ip: _ip,
        context: 'Telekom Srbija · Belgrade, RS',
      )));

      // The address itself, well away from the icon on the right.
      await tester.tap(find.text(_ip));
      await tester.pump();
      await tester.pump();

      expect(clipboard, _ip);
      expect(pulses[HapticKind.selection], 1);
      expect(find.byIcon(Icons.check), findsOneWidget);
      expect(find.byIcon(Icons.copy_outlined), findsNothing);

      // About 1.2 s later the icon is back to what it was.
      await tester.pump(const Duration(milliseconds: 1300));
      expect(find.byIcon(Icons.copy_outlined), findsOneWidget);
      expect(find.byIcon(Icons.check), findsNothing);
    });

    testWidgets('the status word is part of the target too', (tester) async {
      await tester.pumpWidget(_host(const HomeStatusCard(
        tone: StatusTone.safe,
        status: S.tProtected,
        ip: _ip,
        context: 'Frankfurt, Germany',
      )));
      await tester.tap(find.text(S.tProtected.toUpperCase()));
      await tester.pump();
      await tester.pump();
      expect(clipboard, _ip);
      await tester.pump(const Duration(milliseconds: 1300));
    });

    testWidgets('a long press opens what the hero hands in', (tester) async {
      var opened = 0;
      await tester.pumpWidget(_host(HomeStatusCard(
        tone: StatusTone.risk,
        status: S.tExposed,
        ip: _ip,
        context: 'Telekom Srbija · Belgrade, RS',
        onLongPress: () => opened++,
      )));

      await tester.longPress(find.text(_ip));
      await tester.pump();
      expect(opened, 1);
      expect(pulses[HapticKind.selection], 1);
      // A long press is not a copy.
      expect(clipboard, isNull);
      expect(find.byIcon(Icons.copy_outlined), findsOneWidget);
    });

    testWidgets('without an address there is nothing to copy or hold',
        (tester) async {
      await tester.pumpWidget(_host(const HomeStatusCard(
        tone: StatusTone.off,
        status: S.b15Status,
        context: S.b15Context,
      )));
      await tester.tap(find.text(S.b15Status.toUpperCase()));
      await tester.pump();
      expect(clipboard, isNull);
      expect(pulses, isEmpty);
      expect(find.byIcon(Icons.copy_outlined), findsNothing);
    });
  });

  group('the address sheet', () {
    testWidgets('shows what it was handed and leaves out what it was not',
        (tester) async {
      await tester.pumpWidget(_sheetHost(
        const HeroIpDetails(
            ip: _ip, city: 'Belgrade', country: 'Serbia', cc: 'RS'),
        (_) {},
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text(S.heroIpTitle), findsOneWidget);
      expect(find.text(S.heroIpAddress), findsOneWidget);
      expect(find.text(_ip), findsOneWidget);
      expect(find.text(S.heroIpCity), findsOneWidget);
      expect(find.text('Belgrade'), findsOneWidget);
      expect(find.text(S.heroIpCountry), findsOneWidget);
      expect(find.textContaining('Serbia'), findsOneWidget);
      expect(find.textContaining('RS'), findsOneWidget);
      // No network was known, so no Network row, and no dash in its place.
      expect(find.text(S.heroIpNetwork), findsNothing);
      expect(find.textContaining('-'), findsNothing);
      expect(find.text(S.homeCopyIp), findsOneWidget);
    });

    testWidgets('fills in what the lookup adds', (tester) async {
      HeroIpSheet.lookup = () async => const IpGeo(
            lat: 44.8,
            lon: 20.5,
            city: 'Belgrade',
            cc: 'RS',
            country: 'Serbia',
            isp: 'Telekom Srbija',
          );
      await tester.pumpWidget(_sheetHost(const HeroIpDetails(ip: _ip), (_) {}));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Belgrade'), findsOneWidget);
      expect(find.textContaining('Serbia'), findsOneWidget);
      expect(find.text(S.heroIpNetwork), findsOneWidget);
      expect(find.text('Telekom Srbija'), findsOneWidget);
    });

    testWidgets('the lookup placeholder city is not a city', (tester) async {
      HeroIpSheet.lookup = () async => const IpGeo(
            lat: 44.8,
            lon: 20.5,
            city: 'you',
            cc: 'RS',
          );
      await tester.pumpWidget(_sheetHost(const HeroIpDetails(ip: _ip), (_) {}));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text(S.heroIpCity), findsNothing);
      expect(find.text('you'), findsNothing);
      expect(find.text(S.heroIpCountry), findsOneWidget);
      expect(find.text('RS'), findsOneWidget);
    });

    testWidgets('Copy hands the address back and closes the sheet',
        (tester) async {
      String? copied;
      await tester.pumpWidget(_sheetHost(
        const HeroIpDetails(ip: _ip, city: 'Belgrade'),
        (ip) => copied = ip,
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text(S.homeCopyIp));
      await tester.pumpAndSettle();
      expect(copied, _ip);
      expect(find.byType(HeroIpSheet), findsNothing);
    });
  });
}
