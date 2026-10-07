import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hideip_vpn/core/share_link_parser.dart';
import 'package:hideip_vpn/core/proxy_profile.dart';
import 'package:hideip_vpn/core/subscription.dart';
import 'package:hideip_vpn/core/import_payload.dart';

Map<String, String> fixture(String name) => {
  for (final l in File('test/fixtures/panels/$name.tsv').readAsLinesSync())
    if (l.contains('\t'))
      l.substring(0, l.indexOf('\t')): l.substring(l.indexOf('\t') + 1),
};
void main() {
  final xui = fixture('3x-ui');
  final hid = fixture('hiddify');
  final pg =
      jsonDecode(
            File('test/fixtures/panels/pasarguard.json').readAsStringSync(),
          )
          as Map<String, dynamic>;
  final rejected = {
    'vless_reality_xhttp',
    'vless_mlkem_xhttp_tls',
    'vless_kcp',
    'vless_tcp_http',
    'vmess_xhttp_tls',
  };
  for (final e in xui.entries) {
    test('3x-ui ${e.key}', () {
      if (rejected.contains(e.key)) {
        expect(
          () => ShareLinkParser.parse(e.value),
          throwsA(isA<ProfileParseException>()),
        );
      } else {
        final p = ShareLinkParser.parse(e.value)!;
        expect(p.server, startsWith('203.0.113.'));
        if (e.key.contains('httpupgrade')) {
          expect(p.outbound['transport'], containsPair('type', 'httpupgrade'));
        }
        if (e.key == 'ss2022_aes256_multi') {
          expect(
            p.outbound['password'],
            'c2VydmVyUFNLc2VydmVyUFNLc2VydmVyUFNLc2VydmU=:dXNlcisvUFNLdXNlclBTS3VzZXJQU0t1c2VyUFNLdXM=',
          );
        }
        if (e.key == 'ss2022_chacha_single') {
          expect(
            p.outbound['password'],
            'Y2hhY2hhK3VzZXJQU0t1c2VyUFNLdXNlclBTS3VzPT0=',
          );
        }
      }
    });
  }
  test('3x-ui base64 subscription keeps only supported profiles', () {
    final r = Subscription.parse(
      File('test/fixtures/panels/3x-ui-base64.txt').readAsStringSync(),
    );
    expect(r.profiles.length, xui.length - rejected.length);
    expect(r.errors.length, rejected.length);
  });
  final hidRejected = {
    'vless-http-hiddify-core',
    'vless-xhttp-hiddify-core',
    'vless-tcp-xray',
    'vless-http-xray',
    'vless-grpc-xray',
    'vless-httpupgrade-xray',
    'vless-xhttp-xray',
    'vless-ws-xray',
    'vmess-http',
    'vmess-xhttp',
    'hysteria-v1',
    'wg',
    'ssh',
    'naive',
    'mieru',
    'snell',
    'hy2-port-ranges',
  };
  for (final e in hid.entries) {
    test('Hiddify ${e.key}', () {
      if (hidRejected.contains(e.key)) {
        expect(
          () => ShareLinkParser.parse(e.value),
          throwsA(isA<ProfileParseException>()),
        );
      } else if (e.key == 'comment-usage' || e.key == 'trojan-fake-usage') {
        expect(ShareLinkParser.parse(e.value), isNull);
      } else {
        final p = ShareLinkParser.parse(e.value)!;
        if (e.key.contains('httpupgrade')) {
          expect(p.outbound['transport'], containsPair('type', 'httpupgrade'));
        }
        if (e.key == 'ss2022-uot') {
          expect(p.outbound['udp_over_tcp'], containsPair('enabled', true));
        }
      }
    });
  }
  test('PasarGuard Clash with URLs imports same servers as plain template', () {
    final a = Subscription.parse(pg['clash_default'] as String);
    final b = Subscription.parse(pg['clash_no_url'] as String);
    expect(a.profiles, isNotEmpty);
    expect(a.profiles.length, b.profiles.length);
  });
  test('PasarGuard sing-box WireGuard becomes a safe userspace endpoint', () {
    final r = Subscription.parse(pg['singbox'] as String);
    expect(r.profiles.length, 5);
    final p = r.profiles.singleWhere((p) => p.protocol == 'wireguard');
    expect(p.isEndpoint, isTrue);
    expect(p.outbound['system'], false);
    expect(p.outbound.containsKey('name'), false);
    expect(p.outbound['mtu'], 1280);
    expect((p.outbound['peers'] as List).single, containsPair('port', 51820));
  });
  test('endpoint-only minified JSON is recognized', () {
    final doc = jsonDecode(pg['singbox'] as String) as Map<String, dynamic>;
    doc.remove('outbounds');
    expect(
      classifyImportPayload(jsonEncode(doc))?.kind,
      ImportPayloadKind.subscriptionBlob,
    );
    expect(
      Subscription.parse(jsonEncode(doc)).profiles.single.isEndpoint,
      true,
    );
  });
  for (final param in ['mport', 'mports']) {
    test('Hysteria2 $param maps validated ranges to core syntax', () {
      final p = ShareLinkParser.parse(
        'hysteria2://pw@example.com:443?$param=20000-30000,443',
      )!;
      expect(p.outbound['server_ports'], ['20000:30000', '443']);
      expect(
        () => ShareLinkParser.parse(
          'hy2://pw@example.com:443?$param=70000-80000',
        ),
        throwsA(isA<ProfileParseException>()),
      );
    });
  }
  for (final type in ['xhttp', 'splithttp', 'kcp', 'mkcp', 'invented']) {
    test('unknown transport $type never becomes TCP', () {
      for (final scheme in ['vless', 'trojan']) {
        expect(
          () =>
              ShareLinkParser.parse('$scheme://id@example.com:443?type=$type'),
          throwsA(isA<ProfileParseException>()),
        );
      }
    });
  }
  test('core supports plain QUIC but not Xray QUIC obfuscation', () {
    expect(
      ShareLinkParser.parse(
        'vless://id@example.com:443?type=quic&security=tls',
      )!.outbound['transport'],
      {'type': 'quic'},
    );
    expect(
      () => ShareLinkParser.parse(
        'vless://id@example.com:443?type=quic&quicSecurity=aes-128-gcm&key=secret',
      ),
      throwsA(isA<ProfileParseException>()),
    );
  });
  test(
    'metadata records are skipped without suppressing real local proxies',
    () {
      for (final l in [
        'vless://id@0.0.0.0:1#App%20not%20supported',
        'trojan://pw@127.0.0.1:1#Usage',
      ]) {
        expect(Subscription.parse(l).profiles, isEmpty);
      }
      expect(
        ShareLinkParser.parse('trojan://pw@127.0.0.1:443#Home'),
        isNotNull,
      );
    },
  );

  final pgRejected = {'vless-xhttp-reality', 'vless-tcp-http-header', 'vless-kcp', 'vless-mlkem'};
  for (final e in (pg['links'] as Map).entries) {
    test('PasarGuard generated link ${e.key}', () {
      if (pgRejected.contains(e.key)) {
        expect(() => ShareLinkParser.parse(e.value as String), throwsA(isA<ProfileParseException>()));
      } else {
        final p = ShareLinkParser.parse(e.value as String)!;
        expect(p.server, isNotEmpty);
        if (e.key == 'vmess-httpupgrade') {
          expect(p.outbound['transport'], containsPair('type', 'httpupgrade'));
        }
        if (e.key == 'hy2-obfs-hop') {
          expect(p.outbound['server_ports'], ['20000:30000']);
        }
      }
    });
  }
  for (final key in ['links_base64', 'plain_body', 'b64_body_start', 'b64_body_end', 'plain_body_start']) {
    test('PasarGuard $key imports supported entries around banners', () {
      final result = Subscription.parse(pg[key] as String);
      expect(result.profiles.length, (pg['links'] as Map).length - pgRejected.length);
    });
  }
  test('Hiddify base64 body has the same supported profiles as individual links', () {
    final parsed = Subscription.parse(File('test/fixtures/panels/hiddify-base64.txt').readAsStringSync());
    expect(parsed.profiles.length, hid.length - hidRejected.length - 2);
    expect(parsed.placeholders, 1);
  });
}
