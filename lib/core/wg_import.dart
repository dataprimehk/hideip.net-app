import 'dart:convert';

import 'proxy_profile.dart';
import 'wg_keys.dart';
import 'wg_profile.dart' show wgMtu;

/// Turns a user's own WireGuard configuration into a [ProxyProfile].
///
/// This is the bring-your-own path and it is deliberately separate from
/// [WgProfile] and [WgSingboxConfig], which model the peer the hideip.net
/// backend issues for Speed mode. The two differ in more than plumbing: Speed
/// mode generates the private key on the device and never lets it leave, while
/// an imported configuration arrives with a key somebody else already chose.
/// Keeping the paths apart means an import is never mistaken for a provisioned
/// peer, so a lapsed subscription cannot remove a server the user brought.
///
/// Two shapes are accepted:
///  * the `[Interface]` / `[Peer]` file every WireGuard tool writes, which is
///    what the generator on hideip.net hands out, and
///  * the `wireguard://key@host:port?publickey=...` link other clients share.
class WgImport {
  WgImport._();

  /// The value [ProxyProfile.protocol] carries for an imported tunnel.
  static const String protocol = 'wireguard';

  /// Schemes [parseLink] answers to. Mirrored into
  /// [ShareLinkParser.supportedSchemes] so the importer's whitelist and the
  /// deep-link whitelist stay one rule.
  static const Set<String> linkSchemes = {'wireguard', 'wg'};

  static final RegExp _section = RegExp(r'^\[([A-Za-z]+)\]$');

  /// Whether [raw] is a WireGuard configuration file rather than a link.
  ///
  /// Both section headers are required. One alone appears often enough in
  /// other text (a Clash document, a provider's notes) that accepting it would
  /// pull unrelated pastes into this parser and report the wrong error.
  static bool looksLikeConfig(String raw) {
    var hasInterface = false;
    var hasPeer = false;
    for (final line in const LineSplitter().convert(raw)) {
      final match = _section.firstMatch(line.trim());
      if (match == null) continue;
      switch (match.group(1)!.toLowerCase()) {
        case 'interface':
          hasInterface = true;
        case 'peer':
          hasPeer = true;
      }
      if (hasInterface && hasPeer) return true;
    }
    return false;
  }

  /// Parse a `[Interface]` / `[Peer]` configuration.
  ///
  /// Throws [ProfileParseException] naming the field at fault. A WireGuard
  /// tunnel that comes up but carries nothing is the worst outcome here, so
  /// anything that would produce one is refused at import instead.
  static ProxyProfile parseConfig(String raw) {
    Map<String, String>? iface;
    final peers = <Map<String, String>>[];
    Map<String, String>? current;
    String? name;

    for (final rawLine in const LineSplitter().convert(raw)) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#') || line.startsWith(';')) {
        name ??= _nameFromComment(line);
        continue;
      }
      final section = _section.firstMatch(line);
      if (section != null) {
        switch (section.group(1)!.toLowerCase()) {
          case 'interface':
            iface = current = <String, String>{};
          case 'peer':
            current = <String, String>{};
            peers.add(current);
          default:
            // An unknown section's keys belong to nothing we build.
            current = null;
        }
        continue;
      }
      if (current == null) continue;
      final eq = line.indexOf('=');
      if (eq <= 0) continue;
      // wg-quick allows a trailing comment on a value line.
      final hash = line.indexOf('#', eq);
      final value =
          (hash < 0 ? line.substring(eq + 1) : line.substring(eq + 1, hash))
              .trim();
      current[line.substring(0, eq).trim().toLowerCase()] = value;
    }

    if (iface == null) {
      throw const ProfileParseException('WireGuard config has no [Interface]');
    }
    if (peers.isEmpty) {
      throw const ProfileParseException('WireGuard config has no [Peer]');
    }

    final privateKey = iface['privatekey'] ?? '';
    if (!WgKeys.isValidKey(privateKey)) {
      throw const ProfileParseException(
          'WireGuard [Interface] PrivateKey is missing or malformed');
    }
    final address = _csv(iface['address']);
    if (address.isEmpty) {
      throw const ProfileParseException(
          'WireGuard [Interface] Address is missing');
    }

    final built = <Map<String, dynamic>>[];
    String? host;
    int? port;
    var carriesDefaultRoute = false;

    for (final peer in peers) {
      final endpoint = peer['endpoint'] ?? '';
      final publicKey = peer['publickey'] ?? '';
      // A peer with no Endpoint is one that dials us. Legal in WireGuard,
      // useless in a client profile, so it is skipped rather than refused.
      if (endpoint.isEmpty) continue;
      if (!WgKeys.isValidKey(publicKey)) {
        throw const ProfileParseException(
            'WireGuard [Peer] PublicKey is missing or malformed');
      }
      final (peerHost, peerPort) = _hostPort(endpoint);
      final allowedIps = _csv(peer['allowedips']);
      if (allowedIps.any(_isDefaultRoute)) carriesDefaultRoute = true;

      final entry = <String, dynamic>{
        'address': peerHost,
        'port': peerPort,
        'public_key': publicKey,
        'allowed_ips': allowedIps,
      };
      final psk = peer['presharedkey'];
      if (psk != null && psk.isNotEmpty) {
        if (!WgKeys.isValidKey(psk)) {
          throw const ProfileParseException(
              'WireGuard [Peer] PresharedKey is malformed');
        }
        entry['pre_shared_key'] = psk;
      }
      // Mobile carriers drop idle UDP flows quickly; without a keepalive the
      // tunnel goes quiet and only wakes on the next outbound packet.
      entry['persistent_keepalive_interval'] =
          int.tryParse(peer['persistentkeepalive'] ?? '') ?? 25;

      built.add(entry);
      host ??= peerHost;
      port ??= peerPort;
    }

    if (built.isEmpty || host == null || port == null) {
      throw const ProfileParseException(
          'WireGuard config has no [Peer] with an Endpoint');
    }
    if (!carriesDefaultRoute) {
      // Selecting a server in this app routes the whole device through it.
      // A peer that only accepts a narrow subnet would leave every other
      // destination with nowhere to go: the tunnel connects and nothing
      // loads. Refusing with the reason beats shipping that.
      throw const ProfileParseException(
          'WireGuard AllowedIPs does not cover 0.0.0.0/0 or ::/0, so this '
          'config cannot carry the whole device');
    }

    return _profile(
      name: name ?? 'WireGuard $host',
      host: host,
      port: port,
      address: address,
      privateKey: privateKey,
      mtu: _mtu(iface['mtu']),
      peers: built,
    );
  }

  /// Parse `wireguard://<private key>@host:port?publickey=...&address=...`.
  ///
  /// There is no standard for this link, so both placements of the private key
  /// seen in the wild are accepted: in the userinfo, or as a query parameter.
  static ProxyProfile parseLink(String raw) {
    final Uri uri;
    try {
      uri = Uri.parse(raw.trim());
    } catch (_) {
      throw const ProfileParseException('malformed wireguard:// link');
    }
    final q = uri.queryParameters;

    final privateKey = Uri.decodeComponent(uri.userInfo).isNotEmpty
        ? Uri.decodeComponent(uri.userInfo)
        : (q['privatekey'] ?? q['secret'] ?? '');
    if (!WgKeys.isValidKey(privateKey)) {
      throw const ProfileParseException(
          'wireguard:// link carries no usable private key');
    }
    final publicKey = q['publickey'] ?? q['peer'] ?? '';
    if (!WgKeys.isValidKey(publicKey)) {
      throw const ProfileParseException(
          'wireguard:// link carries no usable peer public key');
    }
    if (uri.host.isEmpty) {
      throw const ProfileParseException('wireguard:// link has no host');
    }
    if (!uri.hasPort || uri.port == 0) {
      throw const ProfileParseException('wireguard:// link has no port');
    }
    final address = _csv(q['address'] ?? q['ip']);
    if (address.isEmpty) {
      throw const ProfileParseException(
          'wireguard:// link has no address for this device');
    }

    final allowedIps = _csv(q['allowedips']);
    final peer = <String, dynamic>{
      'address': uri.host,
      'port': uri.port,
      'public_key': publicKey,
      // Unlike the file, a link that omits AllowedIPs means the whole
      // internet: every client that emits this form sends full-tunnel links.
      'allowed_ips':
          allowedIps.isEmpty ? const ['0.0.0.0/0', '::/0'] : allowedIps,
      'persistent_keepalive_interval':
          int.tryParse(q['keepalive'] ?? q['persistentkeepalive'] ?? '') ?? 25,
    };
    final psk = q['presharedkey'];
    if (psk != null && psk.isNotEmpty) {
      if (!WgKeys.isValidKey(psk)) {
        throw const ProfileParseException(
            'wireguard:// link has a malformed pre-shared key');
      }
      peer['pre_shared_key'] = psk;
    }
    if (!(peer['allowed_ips'] as List).cast<String>().any(_isDefaultRoute)) {
      throw const ProfileParseException(
          'WireGuard AllowedIPs does not cover 0.0.0.0/0 or ::/0, so this '
          'config cannot carry the whole device');
    }

    final name = uri.fragment.isEmpty
        ? 'WireGuard ${uri.host}'
        : Uri.decodeComponent(uri.fragment);

    return _profile(
      name: name,
      host: uri.host,
      port: uri.port,
      address: address,
      privateKey: privateKey,
      mtu: _mtu(q['mtu']),
      peers: [peer],
    );
  }

  /// The `[Interface]` / `[Peer]` file for an imported tunnel, rebuilt from
  /// the profile, for editing it in place.
  ///
  /// It is the same file that was imported, with two honest differences: a
  /// `DNS` line is not carried over at import (see [_profile]) so it cannot
  /// come back here, and the MTU is the one the tunnel actually runs with
  /// rather than the one the file declared. A name that was only ever the
  /// fallback (`WireGuard <host>`) is left off, since it was never in the
  /// file either.
  static String toConfig(ProxyProfile p) {
    final o = p.outbound;
    final b = StringBuffer();
    if (p.name.isNotEmpty && p.name != 'WireGuard ${p.server}') {
      b.writeln('# Name = ${p.name}');
    }
    b.writeln('[Interface]');
    b.writeln('PrivateKey = ${o['private_key'] ?? ''}');
    b.writeln('Address = ${_joined(o['address'])}');
    if (o['mtu'] is int) b.writeln('MTU = ${o['mtu']}');
    final peers = o['peers'];
    if (peers is List) {
      for (final raw in peers) {
        if (raw is! Map) continue;
        b.writeln();
        b.writeln('[Peer]');
        b.writeln('PublicKey = ${raw['public_key'] ?? ''}');
        final psk = raw['pre_shared_key'];
        if (psk is String && psk.isNotEmpty) b.writeln('PresharedKey = $psk');
        b.writeln('AllowedIPs = ${_joined(raw['allowed_ips'])}');
        final host = raw['address']?.toString() ?? '';
        final port = raw['port']?.toString() ?? '';
        b.writeln('Endpoint = ${host.contains(':') ? '[$host]' : host}:$port');
        final keepalive = raw['persistent_keepalive_interval'];
        if (keepalive is int) b.writeln('PersistentKeepalive = $keepalive');
      }
    }
    return b.toString();
  }

  static String _joined(Object? list) =>
      list is List ? list.map((e) => e.toString()).join(', ') : '';

  static ProxyProfile _profile({
    required String name,
    required String host,
    required int port,
    required List<String> address,
    required String privateKey,
    required int mtu,
    required List<Map<String, dynamic>> peers,
  }) =>
      ProxyProfile(
        name: name,
        protocol: protocol,
        server: host,
        port: port,
        // A sing-box `endpoints[]` entry, not an outbound: see
        // [ProxyProfile.isEndpoint]. `system: false` keeps the implementation
        // in userspace, because a kernel interface would collide with the TUN
        // the platform already handed us and needs privileges an app lacks.
        //
        // The `[Interface] DNS` line is deliberately not carried over. DNS is
        // configured once for the whole app in [SingboxConfig], and since
        // route.final points at this endpoint those queries already exit at
        // the peer. A config whose resolver only exists inside the tunnel is
        // the one case that loses, and inventing a second DNS path here would
        // cost more than it buys.
        outbound: {
          'type': 'wireguard',
          'system': false,
          'address': address,
          'private_key': privateKey,
          'mtu': mtu,
          'peers': peers,
        },
        isEndpoint: true,
      );

  /// The MTU the tunnel actually uses.
  ///
  /// Capped at [wgMtu] whatever the file says, which is the same lesson the
  /// TUN inbound and [WgProfile.effectiveMtu] already carry: an MTU sized for
  /// the physical link leaves no room for encapsulation, so large packets are
  /// dropped somewhere in the middle of the path. Small HTTP requests still
  /// pass, which makes it look like the tunnel works, while HTTPS bursts and
  /// speed tests stall. Most WireGuard files say 1420 for exactly the setup we
  /// do not have.
  static int _mtu(String? declared) {
    final value = int.tryParse(declared ?? '') ?? 0;
    return value <= 0 || value > wgMtu ? wgMtu : value;
  }

  static bool _isDefaultRoute(String cidr) {
    final v = cidr.trim();
    return v == '0.0.0.0/0' || v == '::/0' || v == '0::/0';
  }

  static List<String> _csv(String? value) => (value ?? '')
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList(growable: false);

  static (String, int) _hostPort(String value) {
    final v = value.trim();
    if (v.startsWith('[')) {
      final close = v.indexOf(']');
      if (close < 0 || close + 2 > v.length) {
        throw const ProfileParseException('malformed WireGuard Endpoint');
      }
      final port = int.tryParse(v.substring(close + 2)) ?? 0;
      if (port <= 0 || port > 65535) {
        throw const ProfileParseException('malformed WireGuard Endpoint port');
      }
      return (v.substring(1, close), port);
    }
    final idx = v.lastIndexOf(':');
    if (idx <= 0) {
      throw const ProfileParseException(
          'WireGuard Endpoint needs a host and a port');
    }
    final port = int.tryParse(v.substring(idx + 1)) ?? 0;
    if (port <= 0 || port > 65535) {
      throw const ProfileParseException('malformed WireGuard Endpoint port');
    }
    return (v.substring(0, idx), port);
  }

  /// A leading `# Name = Berlin` or `# Berlin` becomes the server's label,
  /// which is the only place a WireGuard file can carry one.
  static String? _nameFromComment(String line) {
    var text = line.substring(1).trim();
    if (text.isEmpty) return null;
    final eq = text.indexOf('=');
    if (eq > 0 &&
        const {'name', 'label', 'title'}
            .contains(text.substring(0, eq).trim().toLowerCase())) {
      text = text.substring(eq + 1).trim();
    }
    if (text.isEmpty || text.length > 60) return null;
    // Generators write banners like "# Do not edit"; a label is not a sentence.
    return text.contains(' ') && text.split(' ').length > 6 ? null : text;
  }
}
