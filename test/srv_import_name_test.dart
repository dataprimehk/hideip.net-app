import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hideip_vpn/core/app_telemetry.dart';
import 'package:hideip_vpn/core/ip_lookup.dart';
import 'package:hideip_vpn/core/ping.dart';
import 'package:hideip_vpn/core/share_link_parser.dart';
import 'package:hideip_vpn/state/app_state.dart';
import 'package:hideip_vpn/ui/redesign/hip.dart';
import 'package:hideip_vpn/ui/redesign/import_screen.dart';
import 'package:hideip_vpn/ui/redesign/shell.dart';
import 'package:hideip_vpn/ui/strings.dart';

const _uuid = '11111111-1111-1111-1111-111111111111';

String _link(String host, [String name = '']) =>
    'vless://$_uuid@$host:443?security=none${name.isEmpty ? '' : '#$name'}';

class _State extends AppState {
  @override
  Future<void> pingAll() async {}
}

HipNav _nav(List<String> log) => HipNav(
  go: (s, [_]) => log.add('go:${s.name}'),
  back: () => log.add('back'),
  ctx: () => null,
  showSheet: <T>(List<Widget> children) async => null,
  openDetail: (_) {},
  openImport: () {},
  openImportWith: (_) {},
  openPaywall: ({required HipScreen from, String? locId}) {},
  claimBack: (_) {},
  releaseBack: (_) {},
);

IpLookupData _berlin(String host) =>
    IpLookupData(ip: host, cc: 'DE', country: 'Germany', city: 'Berlin');

Future<void> _wait(WidgetTester tester, [int ms = 60]) async {
  await Future<void>.delayed(Duration(milliseconds: ms));
  await tester.pump();
}

/// Pastes [link], runs the import and lands on the result card.
Future<void> _import(WidgetTester tester, String link) async {
  await tester.enterText(find.byType(TextField), link);
  await _wait(tester);
  await tester.tap(find.text(S.eImport));
  await _wait(tester, 1800);
  expect(find.text(S.e6AddOnly), findsOneWidget);
}

/// The name field on the result card (the input field is gone by then).
TextField _nameField(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField));

void main() {
  late List<String> geoAsked;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    IpLookup.lookupOverride = (_) async => null;
    AppTelemetry.send = (_) async => false;
    Hip.reducedMotion = true;
    geoAsked = [];
  });
  tearDown(() {
    IpLookup.lookupOverride = null;
    Hip.reducedMotion = false;
  });

  Future<_State> pump(
    WidgetTester tester,
    List<String> log, {
    List<String> existing = const [],
  }) async {
    final state = _State();
    if (existing.isNotEmpty) {
      await state.addProfiles([
        for (final l in existing) ShareLinkParser.parse(l)!,
      ], countFirstProfile: false);
    }
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ImportScreen(
            state: state,
            nav: _nav(log),
            hooks: ImportHooks(
              ping: (_, _) async => const PingOk(31),
              geo: (host) async {
                geoAsked.add(host);
                return _berlin(host);
              },
            ),
          ),
        ),
      ),
    );
    await _wait(tester);
    return state;
  }

  testWidgets(
    'a bare address is named from its place, and the name is editable',
    (tester) async {
      await tester.runAsync(() async {
        final log = <String>[];
        final state = await pump(tester, log);
        await _import(tester, _link('203.0.113.5'));

        expect(geoAsked, ['203.0.113.5']);
        expect(_nameField(tester).controller!.text, 'Berlin, Germany');
        expect(find.text(S.srvNamedFromPlace), findsOneWidget);
        expect(
          find.text(S.e5NamedIt('Berlin, Germany')),
          findsNothing,
          reason: 'the steps are gone once the card is up',
        );

        await tester.tap(find.text(S.e6AddOnly));
        await _wait(tester, 200);

        final p = state.profiles.single;
        expect(p.name, 'Berlin, Germany');
        expect(
          p.customName,
          isNull,
          reason: 'left as suggested, nothing stored',
        );
        expect(p.cc, 'DE');
        expect(p.city, 'Berlin');
        expect(p.source, _link('203.0.113.5'));
        expect(state.locations.single.label, 'Berlin, Germany');
        expect(log, ['go:home']);
      });
    },
  );

  testWidgets(
    'a second server in the same place is numbered; a typed name is not',
    (tester) async {
      await tester.runAsync(() async {
        final log = <String>[];
        final state = await pump(tester, log, existing: [_link('203.0.113.1')]);
        // The one already there was placed the same way.
        await state.setServerLocation(0, cc: 'DE', city: 'Berlin');
        expect(state.locations.single.label, 'Berlin, Germany');

        await _import(tester, _link('203.0.113.2'));
        expect(_nameField(tester).controller!.text, 'Berlin, Germany #2');

        await tester.enterText(find.byType(TextField), 'Home');
        await tester.tap(find.text(S.e6AddOnly));
        await _wait(tester, 200);

        final p = state.profiles.last;
        expect(p.customName, 'Home');
        expect(
          p.name,
          'Berlin, Germany #2',
          reason: 'the suggestion stays the parsed label underneath',
        );
        expect(state.locations.last.label, 'Home');
      });
    },
  );

  testWidgets('a link that names its place needs no lookup', (tester) async {
    await tester.runAsync(() async {
      final log = <String>[];
      final state = await pump(tester, log);
      await _import(tester, _link('203.0.113.5', 'ch-zur-reality-03'));

      expect(geoAsked, isEmpty);
      expect(_nameField(tester).controller!.text, 'Zurich');
      await tester.tap(find.text(S.e6AddOnly));
      await _wait(tester, 200);
      expect(state.profiles.single.name, 'ch-zur-reality-03');
      expect(state.profiles.single.customName, isNull);
      expect(state.locations.single.label, 'Zurich');
    });
  });
}
