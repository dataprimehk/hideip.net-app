import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hideip_vpn/core/ip_lookup.dart';
import 'package:hideip_vpn/core/location.dart';
import 'package:hideip_vpn/core/proxy_profile.dart';
import 'package:hideip_vpn/core/share_link_parser.dart';
import 'package:hideip_vpn/core/srv_countries.dart';
import 'package:hideip_vpn/state/app_state.dart';
import 'package:hideip_vpn/ui/redesign/detail_screen.dart';
import 'package:hideip_vpn/ui/redesign/hip.dart';
import 'package:hideip_vpn/ui/redesign/srv_location_picker.dart';
import 'package:hideip_vpn/ui/strings.dart';

const _uuid = '11111111-1111-1111-1111-111111111111';

String _link(String host, [String name = '']) =>
    'vless://$_uuid@$host:443?security=none${name.isEmpty ? '' : '#$name'}';

ProxyProfile _profile(
  String name, {
  String host = '203.0.113.5',
  String? cc,
  String? city,
  String? ccOverride,
  String? cityOverride,
}) => ProxyProfile(
  name: name,
  protocol: 'vless',
  server: host,
  port: 443,
  outbound: const {'type': 'vless'},
  cc: cc,
  city: city,
  ccOverride: ccOverride,
  cityOverride: cityOverride,
);

class _State extends AppState {
  @override
  Future<void> pingAll() async {}
}

/// Lets the fire-and-forget lookups land.
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    IpLookup.lookupOverride = (_) async => null;
  });
  tearDown(() => IpLookup.lookupOverride = null);

  group('the lookup body', () {
    test('carries the city whether or not it was placed', () {
      final placed = parseIpLookupBody(
        '{"ip":"203.0.113.5","cc":"de","country":"Germany","city":"Berlin",'
        '"latitude":52.5,"longitude":13.4}',
      )!;
      expect(placed.cc, 'DE');
      expect(placed.country, 'Germany');
      expect(placed.city, 'Berlin');
      expect(placed.geo?.city, 'Berlin');

      final named = parseIpLookupBody(
        '{"ip":"203.0.113.5","cc":"DE","country":"Germany","city":"Berlin"}',
      )!;
      expect(named.geo, isNull);
      expect(named.city, 'Berlin');
    });
  });

  group('Location.derive', () {
    test('a placeholder name gives way to the looked-up place', () {
      final l = Location.derive(
        _profile('203.0.113.5:443', cc: 'DE', city: 'Berlin'),
        0,
      );
      expect(l.label, 'Berlin, Germany');
      expect(l.cc, 'DE');
      expect(l.country, 'Germany');
      expect(l.placeCity, 'Berlin');
      expect(l.placeLabel, 'Berlin, Germany');
      expect((l.lat, l.lon), (52.5, 13.4), reason: 'the pin is on the city');

      final countryOnly = Location.derive(
        _profile('203.0.113.5:443', cc: 'DE'),
        0,
      );
      expect(countryOnly.label, 'Germany');
      expect(countryOnly.placeLabel, 'Germany');
      expect(
        (countryOnly.lat, countryOnly.lon),
        (51.0, 10.0),
        reason: 'without a city the pin is on the country',
      );
    });

    test(
      'a provider name without tokens keeps its words and gains the flag',
      () {
        final l = Location.derive(
          _profile('Fast node 7', cc: 'DE', city: 'Berlin'),
          0,
        );
        expect(l.label, 'Fast node 7');
        expect(l.cc, 'DE');
        expect(l.placeLabel, 'Berlin, Germany');
      },
    );

    test('a suggested name keeps its number instead of being re-read', () {
      final l = Location.derive(
        _profile('Berlin, Germany #2', cc: 'DE', city: 'Berlin'),
        0,
      );
      expect(l.label, 'Berlin, Germany #2');
      expect(l.cc, 'DE');
      expect(l.placeCity, 'Berlin');
    });

    test('the user\'s own place wins over the name and the lookup', () {
      final l = Location.derive(
        _profile(
          'de-fra-01',
          cc: 'DE',
          city: 'Frankfurt',
          ccOverride: 'NL',
          cityOverride: 'Amsterdam',
        ),
        0,
      );
      expect(l.cc, 'NL');
      expect(l.country, 'Netherlands');
      expect(l.placeCity, 'Amsterdam');
      expect((l.lat, l.lon), (52.4, 4.9));
      expect(
        l.label,
        'de-fra-01',
        reason: 'the provider\'s name is not rewritten',
      );

      final unnamed = Location.derive(
        _profile(
          '203.0.113.5:443',
          ccOverride: 'nl',
          cityOverride: 'Amsterdam',
        ),
        0,
      );
      expect(unnamed.label, 'Amsterdam, Netherlands');
      expect(unnamed.cc, 'NL');
    });

    test('the place in words for the older paths', () {
      expect(
        Location.derive(_profile('de-fra-01'), 0).placeLabel,
        'Frankfurt, Germany',
      );
      expect(Location.derive(_profile('de-node'), 0).placeLabel, 'Germany');
      expect(Location.derive(_profile('node'), 0).placeLabel, '');
      expect(Location.derive(_profile('node'), 0).placed, isFalse);
    });

    test('country names can be learnt for codes the table lacks', () {
      expect(Location.countryName('bg'), 'BG');
      Location.learnCountryNames({'BG': 'Bulgaria'});
      expect(Location.countryName('bg'), 'Bulgaria');
      expect(Location.countryName('de'), 'Germany');
      expect(
        Location.derive(_profile('203.0.113.5:443', cc: 'BG'), 0).label,
        'Bulgaria',
      );
    });
  });

  group('AppState', () {
    test('the lookup stores the city beside the country', () async {
      IpLookup.lookupOverride = (host) async =>
          IpLookupData(ip: host, cc: 'DE', country: 'Germany', city: 'Berlin');
      final state = _State();
      await state.addLink(_link('203.0.113.5'));
      await _settle();
      final p = state.profiles.first;
      expect(p.cc, 'DE');
      expect(p.city, 'Berlin');
      expect(state.locations.first.label, 'Berlin, Germany');
    });

    test('setServerLocation overrides the lookup and can be undone', () async {
      IpLookup.lookupOverride = (host) async =>
          IpLookupData(ip: host, cc: 'DE', country: 'Germany', city: 'Berlin');
      final state = _State();
      await state.addLink(_link('203.0.113.5'));
      await _settle();

      await state.setServerLocation(0, cc: 'fr', city: ' Lyon ');
      var l = state.locations.first;
      expect(l.cc, 'FR');
      expect(l.placeLabel, 'Lyon, France');
      expect(
        l.label,
        'Lyon, France',
        reason: 'a placeholder name follows the place',
      );
      expect(l.profile.cc, 'DE', reason: 'the lookup is kept underneath');

      await state.setServerLocation(0);
      l = state.locations.first;
      expect(l.cc, 'DE');
      expect(l.placeLabel, 'Berlin, Germany');
      expect(l.profile.ccOverride, isNull);
    });

    test('a name the user or the provider gave is left alone', () async {
      final state = _State();
      await state.addLink(_link('203.0.113.5', 'Fast node 7'));
      await state.addLink(_link('203.0.113.6'));
      await state.renameServer(1, 'Attic');
      await state.setServerLocation(0, cc: 'FR');
      await state.setServerLocation(1, cc: 'FR', city: 'Paris');
      expect(state.locations[0].label, 'Fast node 7');
      expect(state.locations[0].cc, 'FR');
      expect(state.locations[1].label, 'Attic');
      expect(
        state.locations[1].profile.name,
        'Paris, France',
        reason: 'the suggested name underneath still follows the place',
      );
    });

    test('a managed server takes no override', () async {
      final state = _State();
      await state.addProfiles([
        ShareLinkParser.parse(
          _link('203.0.113.5', 'de-fra-01'),
        )!.copyWith(premium: true),
      ], countFirstProfile: false);
      await state.setServerLocation(0, cc: 'FR');
      expect(state.profiles.first.ccOverride, isNull);
    });

    test(
      'an edit keeps the override; a self-placing name drops the lookup',
      () async {
        final state = _State();
        await state.addProfiles([
          ShareLinkParser.parse(
            _link('203.0.113.5'),
          )!.copyWith(cc: 'DE', city: 'Berlin'),
        ], countFirstProfile: false);
        await state.setServerLocation(0, cc: 'FR', city: 'Lyon');

        await state.replaceProfile(
          0,
          ShareLinkParser.parse(_link('203.0.113.5', 'Other'))!,
        );
        var p = state.profiles.first;
        expect(p.ccOverride, 'FR');
        expect(p.cityOverride, 'Lyon');
        expect(p.cc, 'DE');
        expect(p.city, 'Berlin');

        await state.setServerLocation(0);
        await state.replaceProfile(
          0,
          ShareLinkParser.parse(_link('203.0.113.5', 'nl-ams-01'))!,
        );
        p = state.profiles.first;
        expect(p.cc, isNull, reason: 'the name now places the server itself');
        expect(state.locations.first.cc, 'NL');
      },
    );

    test('the new fields round trip through the stored extras', () {
      final p = _profile(
        'x',
        cc: 'DE',
        city: 'Berlin',
        ccOverride: 'FR',
        cityOverride: 'Lyon',
      );
      final back = _profile('x', cc: 'DE').withStoredExtras(p.storedExtras);
      expect(back.city, 'Berlin');
      expect(back.ccOverride, 'FR');
      expect(back.cityOverride, 'Lyon');
      expect(_profile('x').storedExtras, isEmpty);
    });
  });

  group('the detail screen', () {
    testWidgets('shows the place and opens the picker from the row', (
      tester,
    ) async {
      var opened = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ManageServerSection(
              name: 'Berlin, Germany',
              rawName: 'Berlin, Germany',
              fromSubscription: false,
              onRename: (_) {},
              place: 'Berlin, Germany',
              onLocation: () => opened++,
            ),
          ),
        ),
      );
      expect(find.text(S.srvLocation), findsOneWidget);
      expect(find.text('Berlin, Germany'), findsWidgets);
      await tester.tap(find.text(S.srvLocation));
      await tester.pump();
      expect(opened, 1);
    });
  });

  group('the location picker', () {
    setUp(() => Hip.reducedMotion = true);
    tearDown(() => Hip.reducedMotion = false);

    Future<List<SrvCountry>> countries() async => const [
      SrvCountry('DE', 'Germany'),
      SrvCountry('FR', 'France'),
      SrvCountry('NL', 'Netherlands'),
    ];

    Widget picker({
      String? cc,
      String? city,
      bool overridden = false,
      required ValueChanged<SrvPlace> onDone,
    }) => MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SrvLocationPicker(
            cc: cc,
            city: city,
            overridden: overridden,
            onDone: onDone,
            onCancel: () {},
            loadCountries: countries,
          ),
        ),
      ),
    );

    Future<void> loaded(WidgetTester tester) async {
      for (var i = 0; i < 10 && find.text('France').evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    testWidgets('a country is searched, chosen and saved with a city', (
      tester,
    ) async {
      SrvPlace? result;
      await tester.pumpWidget(picker(onDone: (p) => result = p));
      await loaded(tester);

      // Nothing chosen yet: Save waits.
      expect(
        tester.widget<HipCta>(find.widgetWithText(HipCta, S.gSave)).onTap,
        isNull,
      );
      expect(find.text(S.srvUseDetected), findsNothing);

      await tester.enterText(find.byType(TextField).first, 'fran');
      await tester.pump();
      expect(find.text('France'), findsOneWidget);
      expect(find.text('Germany'), findsNothing);

      await tester.tap(find.text('France'));
      await tester.pump();
      await tester.enterText(find.byType(TextField).last, 'Lyon');
      await tester.tap(find.text(S.gSave));
      await tester.pump();

      expect(result?.cc, 'FR');
      expect(result?.city, 'Lyon');
    });

    testWidgets('an overridden server can go back to the detected place', (
      tester,
    ) async {
      SrvPlace? result;
      await tester.pumpWidget(
        picker(
          cc: 'FR',
          city: 'Lyon',
          overridden: true,
          onDone: (p) => result = p,
        ),
      );
      await loaded(tester);
      expect(
        find.byIcon(Icons.check),
        findsOneWidget,
        reason: 'the current country is marked',
      );
      expect(
        tester.widget<TextField>(find.byType(TextField).last).controller!.text,
        'Lyon',
      );
      await tester.tap(find.text(S.srvUseDetected));
      await tester.pump();
      expect(result, isNotNull);
      expect(result!.cc, isNull);
    });
  });
}
