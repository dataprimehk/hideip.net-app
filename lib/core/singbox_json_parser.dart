import 'proxy_profile.dart';
import 'wg_import.dart';
import 'share_link_parser.dart';

/// Parses a sing-box JSON subscription body (a JSON object with an `outbounds`
/// array) into [ProxyProfile]s.
///
/// Each supported outbound is passed through almost verbatim as the profile's
/// [ProxyProfile.outbound], with its `tag` stripped: tags are re-assigned at
/// config build time (see proxy_profile.dart). Non-proxy outbounds (`direct`,
/// `dns`, `block`, selectors, etc.) are ignored, not counted as failures.
///
/// ShadowTLS chains: an outbound may reference another via `detour`. The
/// referenced outbound is carried in [ProxyProfile.extraOutbounds] keeping its
/// tag, and the referencing outbound keeps its `detour` string (mirrors how the
/// share-link parser represents `ss detour -> shadowtls-out`).
class SingboxJsonParser {
  static const _supported = {
    'vless',
    'vmess',
    'shadowsocks',
    'trojan',
    'hysteria2',
    'tuic',
    'anytls',
    'socks',
    'http',
    'shadowtls',
  };

  static List<ProxyProfile> parse(
    Map<String, dynamic> doc, {
    required List<String> errors,
  }) {
    final outbounds = doc['outbounds'] is List ? doc['outbounds'] as List : const [];

    // Index every outbound by tag so detour references can be resolved, and
    // remember which tags are chain targets: an outbound another one detours
    // into (e.g. the shadowtls half of an ss chain) is not a usable server on
    // its own and must not surface as a second, phantom profile.
    final byTag = <String, Map<String, dynamic>>{};
    final chainTargets = <String>{};
    for (final o in outbounds) {
      if (o is Map) {
        final tag = o['tag'];
        if (tag is String && tag.isNotEmpty) {
          byTag[tag] = o.map((k, v) => MapEntry(k.toString(), v));
        }
        final detour = o['detour'];
        if (detour is String && detour.isNotEmpty) chainTargets.add(detour);
      }
    }

    final out = <ProxyProfile>[];
    for (final raw in outbounds) {
      if (raw is! Map) continue;
      final o = raw.map((k, v) => MapEntry(k.toString(), v));
      final type = (o['type'] ?? '').toString().toLowerCase();
      if (!_supported.contains(type)) continue; // ignore direct/dns/etc.
      final ownTag = (o['tag'] ?? '').toString();
      if (ownTag.isNotEmpty && chainTargets.contains(ownTag)) continue;

      final tag = (o['tag'] ?? '').toString();
      try {
        out.add(_one(o, type, byTag));
      } catch (e) {
        final label = tag.isNotEmpty ? tag : type;
        errors.add('$label -> ${e is ProfileParseException ? e.message : e}');
      }
    }
    final endpoints = doc['endpoints'];
    if (endpoints is List) {
      for (final raw in endpoints) {
        if (raw is! Map || raw['type'] != 'wireguard') continue;
        try {
          out.add(_wireguard(raw));
        } catch (_) {
          errors.add('WireGuard -> Invalid endpoint configuration.');
        }
      }
    }
    return out;
  }

  static ProxyProfile _wireguard(Map raw) {
    final peers = raw['peers'];
    if (peers is! List || peers.isEmpty || raw['address'] is! List) {
      throw const ProfileParseException('WireGuard endpoint needs addresses and peers');
    }
    // Reuse the file parser's key, port and whole-device route checks. Build
    // only client fields; never import a system interface, listen port or name.
    String field(Object? value) {
      final text = value is List ? value.join(', ') : (value ?? '').toString();
      if (text.contains('\n') || text.contains('\r')) {
        throw const ProfileParseException('Invalid WireGuard field');
      }
      return text;
    }
    final b = StringBuffer('[Interface]\n');
    b.writeln('PrivateKey = ${field(raw['private_key'])}');
    b.writeln('Address = ${field(raw['address'])}');
    b.writeln('MTU = ${field(raw['mtu'])}');
    for (final peer in peers) {
      if (peer is! Map || peer['address'] == null || peer['port'] == null) {
        throw const ProfileParseException('WireGuard peer needs an endpoint');
      }
      final host = field(peer['address']);
      b.writeln('[Peer]');
      b.writeln('PublicKey = ${field(peer['public_key'])}');
      b.writeln('PresharedKey = ${field(peer['pre_shared_key'])}');
      b.writeln('AllowedIPs = ${field(peer['allowed_ips'])}');
      b.writeln('Endpoint = ${host.contains(':') ? '[$host]' : host}:${field(peer['port'])}');
      b.writeln('PersistentKeepalive = ${field(peer['persistent_keepalive_interval'])}');
    }
    final p = WgImport.parseConfig(b.toString());
    final built = (p.outbound['peers'] as List).cast<Map<String, dynamic>>();
    for (var i = 0; i < peers.length; i++) {
      final reserved = (peers[i] as Map)['reserved'];
      if (reserved != null) {
        if (reserved is! List || reserved.length != 3 ||
            reserved.any((v) => v is! int || v < 0 || v > 255)) {
          throw const ProfileParseException('Invalid WireGuard reserved bytes');
        }
        built[i]['reserved'] = List<int>.from(reserved);
      }
    }
    return p.copyWith(name: (raw['tag'] ?? p.name).toString());
  }

  static ProxyProfile _one(
    Map<String, dynamic> o,
    String type,
    Map<String, Map<String, dynamic>> byTag,
  ) {
    final server = (o['server'] ?? '').toString();
    final port = _int(o['server_port']);

    // A detour-based chain (e.g. shadowsocks -> shadowtls-out): the dialed
    // endpoint lives on the referenced outbound, not this one.
    final detour = (o['detour'] ?? '').toString();
    final extra = <Map<String, dynamic>>[];
    String effServer = server;
    int effPort = port;
    if (detour.isNotEmpty && byTag.containsKey(detour)) {
      final ref = byTag[detour]!;
      extra.add(ref); // keep its tag; it is added as-is
      if (effServer.isEmpty) effServer = (ref['server'] ?? '').toString();
      if (effPort == 0) effPort = _int(ref['server_port']);
    }

    if (effServer.isEmpty || effPort == 0) {
      throw const ProfileParseException('missing server/server_port');
    }

    final tag = (o['tag'] ?? '').toString();
    final name = tag.isNotEmpty ? tag : '$effServer:$effPort';

    // The outbound we store is this map without its own tag (re-assigned at
    // build time). detour references stay intact so chains rebuild correctly.
    final outbound = Map<String, dynamic>.from(o)..remove('tag');
    if (type == 'hysteria2' && outbound['server_ports'] is List) {
      outbound['server_ports'] = ShareLinkParser.parseHysteriaPorts((outbound['server_ports'] as List).join(','));
    }

    return ProxyProfile(
      name: name,
      protocol: type,
      server: effServer,
      port: effPort,
      outbound: outbound,
      extraOutbounds: extra,
    );
  }

  static int _int(Object? v) {
    if (v is int) return v;
    return int.tryParse((v ?? '').toString()) ?? 0;
  }
}
