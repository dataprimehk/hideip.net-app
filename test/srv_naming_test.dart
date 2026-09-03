import 'package:flutter_test/flutter_test.dart';

import 'package:hideip_vpn/core/ip_lookup.dart';
import 'package:hideip_vpn/core/location.dart';
import 'package:hideip_vpn/core/proxy_profile.dart';
import 'package:hideip_vpn/core/srv_naming.dart';
import 'package:hideip_vpn/core/srv_suggest.dart';
import 'package:hideip_vpn/core/wg_import.dart';

ProxyProfile _bare(String host, {String? name, String protocol = 'vless'}) =>
    ProxyProfile(
      name: name ?? '$host:443',
      protocol: protocol,
      server: host,
      port: 443,
      outbound: {'type': protocol},
    );

IpLookupData _geo(String host, {String? cc, String? country, String? city}) =>
    IpLookupData(ip: host, cc: cc, country: country, city: city);

/// Imports [hosts] one after another, each named against the labels of the
/// ones before it, the way the import screen does.
List<ProxyProfile> _importAll(
  List<String> hosts,
  IpLookupData? Function(String host) lookup, {
  List<ProxyProfile> existing = const [],
}) {
  final list = [...existing];
  for (final h in hosts) {
    final taken = Location.deriveAll(list).map((l) => l.label);
    list.add(srvNameFromPlace(_bare(h), geo: lookup(h), taken: taken));
  }
  return list;
}

void main() {
  group('the suggestion', () {
    test('reads City, Country; Country; then the host', () {
      expect(
        SrvNaming.suggest(city: 'Berlin', country: 'Germany', host: 'h'),
        'Berlin, Germany',
      );
      expect(SrvNaming.suggest(country: 'Germany', host: 'h'), 'Germany');
      expect(
        SrvNaming.suggest(city: ' ', country: 'Germany', host: 'h'),
        'Germany',
      );
      expect(SrvNaming.suggest(host: '203.0.113.5'), '203.0.113.5');
    });

    test('knows the parsers\' placeholders', () {
      expect(
        SrvNaming.isFallback('203.0.113.5:443', host: '203.0.113.5', port: 443),
        isTrue,
      );
      expect(
        SrvNaming.isFallback(
          'WireGuard wg.example.com',
          host: 'wg.example.com',
          port: 51820,
        ),
        isTrue,
      );
      expect(SrvNaming.isFallback('', host: 'h', port: 1), isTrue);
      expect(SrvNaming.isFallback('Attic', host: 'h', port: 1), isFalse);
    });
  });

  group('numbering', () {
    test('the first duplicate is #2 and the count carries on', () {
      expect(SrvNaming.numbered('Berlin, Germany', []), 'Berlin, Germany');
      expect(
        SrvNaming.numbered('Berlin, Germany', ['Berlin, Germany']),
        'Berlin, Germany #2',
      );
      expect(
        SrvNaming.numbered('Berlin, Germany', [
          'Berlin, Germany',
          'Berlin, Germany #2',
        ]),
        'Berlin, Germany #3',
      );
    });

    test('a gap left by a removed server is filled first', () {
      expect(
        SrvNaming.numbered('Germany', ['Germany', 'Germany #3']),
        'Germany #2',
      );
      expect(
        SrvNaming.numbered('Germany', ['Germany #2']),
        'Germany',
        reason: 'the bare name itself is free again',
      );
    });

    test('only a numbered form of the same base counts', () {
      expect(
        SrvNaming.numbered('Germany', [
          'Germany #x',
          'Germany 2',
          'Germany, DE',
        ]),
        'Germany',
      );
      expect(
        SrvNaming.isSuggested('Berlin, Germany #2', 'Berlin, Germany'),
        isTrue,
      );
      expect(
        SrvNaming.isSuggested('Berlin, Germany #1', 'Berlin, Germany'),
        isFalse,
      );
      expect(SrvNaming.isSuggested('Berlin', 'Berlin, Germany'), isFalse);
    });
  });

  group('naming an import from its place', () {
    test('two Berlin servers read Berlin, Germany and Berlin, Germany #2', () {
      final list = _importAll([
        '203.0.113.1',
        '203.0.113.2',
      ], (h) => _geo(h, cc: 'DE', country: 'Germany', city: 'Berlin'));
      expect(list.map((p) => p.name), [
        'Berlin, Germany',
        'Berlin, Germany #2',
      ]);
      expect(list.map((p) => p.city), ['Berlin', 'Berlin']);
      expect(list.map((p) => p.cc), ['DE', 'DE']);
      // The labels keep the numbers, and the flags are the same.
      final locs = Location.deriveAll(list);
      expect(locs.map((l) => l.label), [
        'Berlin, Germany',
        'Berlin, Germany #2',
      ]);
      expect(locs.map((l) => l.cc), ['DE', 'DE']);
    });

    test('three servers with only a country count up', () {
      final list = _importAll([
        '203.0.113.1',
        '203.0.113.2',
        '203.0.113.3',
      ], (h) => _geo(h, cc: 'DE', country: 'Germany'));
      expect(list.map((p) => p.name), ['Germany', 'Germany #2', 'Germany #3']);
      expect(Location.deriveAll(list).map((l) => l.label), [
        'Germany',
        'Germany #2',
        'Germany #3',
      ]);
    });

    test(
      'a city and a country-only server in the same country do not collide',
      () {
        final list = _importAll(
          ['203.0.113.1', '203.0.113.2'],
          (h) => h.endsWith('1')
              ? _geo(h, cc: 'DE', country: 'Germany', city: 'Berlin')
              : _geo(h, cc: 'DE', country: 'Germany'),
        );
        expect(list.map((p) => p.name), ['Berlin, Germany', 'Germany']);
      },
    );

    test('a name the user typed is never numbered', () {
      // Two servers the user called Berlin themselves.
      final mine = [
        _bare('203.0.113.1').copyWith(customName: 'Berlin, Germany'),
        _bare('203.0.113.2').copyWith(customName: 'Berlin, Germany'),
      ];
      expect(Location.deriveAll(mine).map((l) => l.label), [
        'Berlin, Germany',
        'Berlin, Germany',
      ]);

      // A provider's own name stays as it came, with or without a lookup.
      final named = srvNameFromPlace(
        _bare('203.0.113.3', name: 'Berlin, Germany'),
        geo: _geo('203.0.113.3', cc: 'DE', country: 'Germany', city: 'Berlin'),
        taken: ['Berlin, Germany'],
      );
      expect(named.name, 'Berlin, Germany');
      expect(named.cc, 'DE', reason: 'the place is still kept for the flag');

      // A WireGuard file that names itself in the comment.
      final wg = srvNameFromPlace(
        _bare('wg.example.com', name: 'Attic', protocol: WgImport.protocol),
        geo: _geo('wg.example.com', cc: 'DE', country: 'Germany'),
        taken: ['Attic'],
      );
      expect(wg.name, 'Attic');
    });

    test('with no answer the host stays as the last resort', () {
      final list = _importAll(['203.0.113.9'], (_) => null);
      expect(list.single.name, '203.0.113.9:443');
      expect(list.single.cc, isNull);
      expect(Location.deriveAll(list).single.label, '203.0.113.9:443');

      final unplaced = srvNameFromPlace(
        _bare('203.0.113.9'),
        geo: _geo('203.0.113.9', country: 'Somewhere'),
        taken: const [],
      );
      expect(
        unplaced.name,
        '203.0.113.9:443',
        reason: 'a country without a code is no place',
      );
    });

    test('the country name comes from the answer, then from the table', () {
      final fromAnswer = srvNameFromPlace(
        _bare('203.0.113.1'),
        geo: _geo('203.0.113.1', cc: 'DE', country: 'Deutschland'),
        taken: const [],
      );
      expect(fromAnswer.name, 'Deutschland');
      final fromTable = srvNameFromPlace(
        _bare('203.0.113.2'),
        geo: _geo('203.0.113.2', cc: 'NL'),
        taken: const [],
      );
      expect(fromTable.name, 'Netherlands');
    });
  });
}
