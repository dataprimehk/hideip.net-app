import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:hideip_vpn/core/share_link_parser.dart';
import 'package:hideip_vpn/core/singbox_config.dart';
import 'package:hideip_vpn/core/wg_singbox.dart';
import 'package:hideip_vpn/core/wg_profile.dart';

void main() {
  test('proxy bootstrap uses system DNS, queries use encrypted tunnel DNS', () {
    final c = SingboxConfig.build(
      ShareLinkParser.parse('trojan://pw@example.com:443')!,
    );
    expect(jsonEncode(c), isNot(contains('223.5.5.5')));
    final servers = c['dns']['servers'] as List;
    expect(servers, contains(equals({'type': 'local', 'tag': 'local'})));
    expect(
      servers,
      contains(
        equals({
          'type': 'tls',
          'tag': 'remote',
          'server': '1.1.1.1',
          'detour': 'proxy',
        }),
      ),
    );
  });
  test('WireGuard with no DNS uses tunnel fallback', () {
    const server = WgServer(
      serverId: 'test',
      label: 'Test',
      countryCode: 'NL',
      city: 'Test',
      host: 'example.com',
      port: 51820,
      serverPubkey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
    );
    final profile = WgProfile(
      address: '10.0.0.2/32',
      dns: const [],
      mtu: 1280,
      persistentKeepalive: 25,
      allowedIps: const ['0.0.0.0/0'],
      servers: const [server],
      fetchedAt: DateTime(2026),
    );
    final c = WgSingboxConfig.build(
      profile: profile,
      server: server,
      privateKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
    );
    expect(jsonEncode(c), isNot(contains('223.5.5.5')));
    expect(c['dns']['final'], 'wg-dns-fallback');
    expect(
      c['dns']['servers'],
      contains(
        equals({
          'type': 'tls',
          'tag': 'wg-dns-fallback',
          'server': '1.1.1.1',
          'detour': WgSingboxConfig.endpointTag,
        }),
      ),
    );
  });
}
