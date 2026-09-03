import 'package:flutter_test/flutter_test.dart';

import 'package:hideip_vpn/core/location.dart';
import 'package:hideip_vpn/core/proxy_profile.dart';
import 'package:hideip_vpn/ui/redesign/hero_search.dart';

Location _loc(
  String name, {
  String protocol = 'vless',
  String server = '203.0.113.9',
  Map<String, dynamic> outbound = const {'type': 'vless'},
  String? customName,
  bool locked = false,
  int index = 0,
}) =>
    Location.derive(
      ProxyProfile(
        name: name,
        protocol: protocol,
        server: server,
        port: 443,
        outbound: outbound,
        customName: customName,
      ),
      index,
    ).copyWith(locked: locked);

const _reality = <String, dynamic>{
  'type': 'vless',
  'tls': {
    'enabled': true,
    'reality': {'enabled': true},
  },
};

void main() {
  final berlin = _loc('de-ber-reality-01',
      outbound: _reality, server: 'ber1.example.net');
  final home = _loc('wg-home',
      protocol: 'wireguard',
      outbound: const {'type': 'wireguard'},
      server: '198.51.100.7',
      customName: 'Office box');
  final fra = _loc('fra | @quietproxy',
      protocol: 'shadowsocks',
      outbound: const {'type': 'shadowsocks'},
      server: 'fra.quiet.example');

  group('what a location is found by', () {
    test('the protocol, long and short', () {
      expect(HeroSearch.matches(berlin, 'vless'), isTrue);
      expect(HeroSearch.matches(berlin, 'VLESS'), isTrue);
      expect(HeroSearch.matches(home, 'wireguard'), isTrue);
      expect(HeroSearch.matches(home, 'wg'), isTrue);
      expect(HeroSearch.matches(fra, 'shadowsocks'), isTrue);
      expect(HeroSearch.matches(fra, 'ss'), isTrue);
      expect(HeroSearch.matches(berlin, 'wireguard'), isFalse);
    });

    test('the transport word from the protocol label', () {
      expect(HeroSearch.matches(berlin, 'reality'), isTrue);
      expect(HeroSearch.matches(home, 'reality'), isFalse);
    });

    test('the parsed city, country and code', () {
      expect(HeroSearch.matches(berlin, 'berlin'), isTrue);
      expect(HeroSearch.matches(berlin, 'Germany'), isTrue);
      expect(HeroSearch.matches(berlin, 'de'), isTrue);
      expect(HeroSearch.matches(fra, 'frankfurt'), isTrue);
    });

    test('a piece of the host', () {
      expect(HeroSearch.matches(berlin, 'ber1.exa'), isTrue);
      expect(HeroSearch.matches(home, '198.51'), isTrue);
      expect(HeroSearch.matches(fra, 'quiet.example'), isTrue);
    });

    test('the name the user typed, and the raw one', () {
      expect(HeroSearch.matches(home, 'office'), isTrue);
      expect(HeroSearch.matches(home, 'Office box'), isTrue);
      expect(HeroSearch.matches(home, 'wg-home'), isTrue);
      expect(HeroSearch.matches(berlin, 'reality-01'), isTrue);
    });

    test('the provider handle, with or without the at sign', () {
      expect(HeroSearch.matches(fra, 'quietproxy'), isTrue);
      expect(HeroSearch.matches(fra, '@quiet'), isTrue);
      expect(HeroSearch.matches(berlin, 'quietproxy'), isFalse);
    });

    test('every word of a two word query has to match', () {
      expect(HeroSearch.matches(berlin, 'berlin vless'), isTrue);
      expect(HeroSearch.matches(berlin, 'vless   berlin'), isTrue);
      expect(HeroSearch.matches(berlin, 'berlin wireguard'), isFalse);
      expect(HeroSearch.matches(home, 'office wg'), isTrue);
    });

    test('an empty query finds everything', () {
      expect(HeroSearch.matches(berlin, ''), isTrue);
      expect(HeroSearch.matches(berlin, '   '), isTrue);
    });
  });

  group('the result order', () {
    test('open servers lead, locked ones follow, each in their order', () {
      final lockedBerlin =
          _loc('de-ber-02', server: '203.0.113.20', locked: true, index: 1);
      final lockedMunich =
          _loc('de-muc-01', server: '203.0.113.21', locked: true, index: 2);
      final hits = HeroSearch.filter(
        [home, berlin],
        [lockedMunich, lockedBerlin],
        'de',
      );
      expect(hits.map((l) => l.rawName).toList(),
          ['de-ber-reality-01', 'de-muc-01', 'de-ber-02']);
      expect(hits.first.locked, isFalse);
      expect(hits.last.locked, isTrue);
    });

    test('nothing matching is an empty list, not an error', () {
      expect(HeroSearch.filter([berlin, home], [fra], 'tokyo'), isEmpty);
    });
  });
}
