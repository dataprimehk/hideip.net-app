import 'dart:convert';

import 'proxy_profile.dart';
import 'wg_import.dart';

/// Parses a single proxy share link (`vless://`, `vmess://`, `ss://`,
/// `trojan://`, `hysteria2://`, `tuic://`, `anytls://`, `socks://`,
/// `http(s)://` proxy; ShadowTLS via `ss://` plugin) into a [ProxyProfile]
/// whose [ProxyProfile.outbound] is a sing-box (1.13.x) outbound object.
///
/// A user's own WireGuard configuration is handled too, either as a
/// `wireguard://` link or as the whole `[Interface]` / `[Peer]` file; that one
/// produces an `endpoints[]` entry instead. See [WgImport].
///
/// Throws [ProfileParseException] on anything it cannot understand.
class ShareLinkParser {
  /// Every scheme [parse] dispatches on. Anything deciding whether a payload
  /// is importable at all (the importer's detection, an incoming deep link)
  /// whitelists against this one set, so a protocol added below reaches all
  /// of those paths at once and none of them can drift into accepting a
  /// scheme the parser would refuse.
  static const Set<String> supportedSchemes = {
    'vless',
    'vmess',
    'ss',
    'trojan',
    'hysteria2',
    'hy2',
    'tuic',
    'anytls',
    'socks',
    'socks5',
    'socks5h',
    'http',
    'https',
    'wireguard',
    'wg',
  };

  /// Parse a single trimmed link. Returns null for empty/comment lines so
  /// callers iterating a subscription can skip them cleanly.
  static ProxyProfile? parse(String raw) {
    final link = raw.trim();
    if (link.isEmpty) return null;
    // A WireGuard file is a whole document rather than a link, and it may open
    // with a comment, so it is recognized before the comment-line skip below.
    // One line of a subscription can never satisfy the check, which needs both
    // an [Interface] and a [Peer] header.
    if (WgImport.looksLikeConfig(link)) return WgImport.parseConfig(link);
    if (link.startsWith('#') || link.startsWith('//')) return null;
    final scheme = link.split('://').first.toLowerCase();
    if (isPanelPlaceholder(link)) return null;
    switch (scheme) {
      case 'vless':
        return _parseVless(link);
      case 'vmess':
        return _parseVmess(link);
      case 'ss':
        return _parseShadowsocks(link);
      case 'trojan':
        return _parseTrojan(link);
      case 'hysteria2':
      case 'hy2':
        return _parseHysteria2(link);
      case 'tuic':
        return _parseTuic(link);
      case 'anytls':
        return _parseAnyTls(link);
      case 'socks':
      case 'socks5':
      case 'socks5h':
        return _parseSocks(link);
      case 'http':
      case 'https':
        return _parseHttp(link);
      case 'wireguard':
      case 'wg':
        return WgImport.parseLink(link);
      default:
        throw ProfileParseException('Unsupported scheme "$scheme"');
    }
  }

  // ---------------------------------------------------------------------------
  // vless://uuid@host:port?type=&security=&sni=&flow=...#name
  // ---------------------------------------------------------------------------
  static ProxyProfile _parseVless(String link) {
    final uri = _uri(link);
    final uuid = _userInfo(uri, 'vless');
    final q = uri.queryParameters;

    final outbound = <String, dynamic>{
      'type': 'vless',
      'server': _host(uri),
      'server_port': _port(uri),
      'uuid': uuid,
    };
    final flow = q['flow'];
    if (flow != null && flow.isNotEmpty) outbound['flow'] = flow;
    if ((q['encryption'] ?? 'none') != 'none') {
      if (q['encryption']!.isNotEmpty) {
        throw const UnsupportedProfileException('VLESS encryption (ML-KEM)');
      }
    }

    final tls = _buildTls(q, defaultSni: _host(uri));
    if (tls != null) outbound['tls'] = tls;

    final transport = _buildTransport(q);
    if (transport != null) outbound['transport'] = transport;

    return _profile('vless', uri, outbound);
  }

  // ---------------------------------------------------------------------------
  // vmess://<base64 json>   (the v2rayN JSON variant; also handles raw json)
  // ---------------------------------------------------------------------------
  static ProxyProfile _parseVmess(String link) {
    final body = link.substring('vmess://'.length).trim();
    Map<String, dynamic> j;
    try {
      final decoded = utf8.decode(base64.decode(_padBase64(body)));
      j = jsonDecode(decoded) as Map<String, dynamic>;
    } catch (_) {
      throw const ProfileParseException('vmess: body is not base64 JSON');
    }

    String s(String k) => (j[k] ?? '').toString();
    final host = s('add');
    final port = int.tryParse(s('port')) ?? 0;
    if (host.isEmpty || port == 0) {
      throw const ProfileParseException('vmess: missing add/port');
    }

    final outbound = <String, dynamic>{
      'type': 'vmess',
      'server': host,
      'server_port': port,
      'uuid': s('id'),
      'security': s('scy').isEmpty ? 'auto' : s('scy'),
      'alter_id': int.tryParse(s('aid')) ?? 0,
    };

    // TLS
    if (s('tls') == 'tls') {
      final sni = s('sni').isNotEmpty ? s('sni') : (s('host').isNotEmpty ? s('host') : host);
      outbound['tls'] = <String, dynamic>{
        'enabled': true,
        'server_name': sni,
        if (s('alpn').isNotEmpty) 'alpn': s('alpn').split(','),
        if (s('fp').isNotEmpty) 'utls': {'enabled': true, 'fingerprint': s('fp')},
      };
    }

    // Transport: vmess JSON uses net=ws/grpc/h2/tcp, path, host
    final transport = _vmessTransport(j);
    if (transport != null) outbound['transport'] = transport;

    final name = s('ps').isNotEmpty ? s('ps') : '$host:$port';
    return ProxyProfile(
      name: name,
      protocol: 'vmess',
      server: host,
      port: port,
      outbound: outbound,
    );
  }

  // ---------------------------------------------------------------------------
  // ss://<base64(method:pass)>@host:port#name   OR
  // ss://<base64(method:pass@host:port)>#name   (legacy fully-encoded form)
  // ---------------------------------------------------------------------------
  static ProxyProfile _parseShadowsocks(String link) {
    var body = link.substring('ss://'.length);
    String? fragment;
    final hashIdx = body.indexOf('#');
    if (hashIdx >= 0) {
      fragment = Uri.decodeComponent(body.substring(hashIdx + 1));
      body = body.substring(0, hashIdx);
    }
    // Capture the query (may carry a ShadowTLS plugin) before stripping it.
    String? query;
    final qIdx = body.indexOf('?');
    if (qIdx >= 0) {
      query = body.substring(qIdx + 1);
      body = body.substring(0, qIdx);
    }

    String method, password, host;
    int port;

    if (body.contains('@')) {
      // SIP002: ss://base64(method:pass)@host:port
      final atIdx = body.lastIndexOf('@');
      final userPart = body.substring(0, atIdx);
      final hostPart = body.substring(atIdx + 1).replaceFirst(RegExp(r'/$'), '');
      final decodedUser = Uri.decodeComponent(userPart);
      final creds = decodedUser.contains(':')
          ? decodedUser
          : utf8.decode(base64.decode(_padBase64(decodedUser)));
      final ci = creds.indexOf(':');
      if (ci < 0) throw const ProfileParseException('ss: bad credentials');
      method = creds.substring(0, ci);
      password = creds.substring(ci + 1);
      final hp = _splitHostPort(hostPart);
      host = hp.$1;
      port = hp.$2;
    } else {
      // Legacy: ss://base64(method:pass@host:port)
      final decoded = utf8.decode(base64.decode(_padBase64(body)));
      final atIdx = decoded.lastIndexOf('@');
      if (atIdx < 0) throw const ProfileParseException('ss: bad legacy link');
      final creds = decoded.substring(0, atIdx);
      final hostPart = decoded.substring(atIdx + 1);
      final ci = creds.indexOf(':');
      if (ci < 0) throw const ProfileParseException('ss: bad credentials');
      method = creds.substring(0, ci);
      password = creds.substring(ci + 1);
      final hp = _splitHostPort(hostPart);
      host = hp.$1;
      port = hp.$2;
    }

    // 3x-ui emits an empty server PSK for the single-key ChaCha20 method.
    if (method == '2022-blake3-chacha20-poly1305' && password.startsWith(':')) {
      password = password.substring(1);
    }
    final ssOutbound = <String, dynamic>{
      'type': 'shadowsocks',
      'server': host,
      'server_port': port,
      'method': method,
      'password': password,
      if (_isTrue(Uri.splitQueryString(query ?? '')['uot']))
        'udp_over_tcp': {'enabled': true},
    };

    // ShadowTLS: ss link carries ?plugin=shadow-tls;host=...;password=...;version=3
    // sing-box models this as a `shadowtls` outbound that the shadowsocks
    // outbound detours into. We chain them and expose the SS as `proxy-ss`.
    final stls = _parseShadowTlsPlugin(query);
    if (stls != null) {
      stls['server'] = host;
      stls['server_port'] = port;
      // SS rides on top of the ShadowTLS tunnel rather than dialing directly.
      ssOutbound.remove('server');
      ssOutbound.remove('server_port');
      ssOutbound['detour'] = 'shadowtls-out';
      stls['tag'] = 'shadowtls-out';
      return ProxyProfile(
        name: fragment ?? '$host:$port',
        protocol: 'shadowtls',
        server: host,
        port: port,
        outbound: ssOutbound,
        extraOutbounds: [stls],
      );
    }

    return ProxyProfile(
      name: fragment ?? '$host:$port',
      protocol: 'shadowsocks',
      server: host,
      port: port,
      outbound: ssOutbound,
    );
  }

  // ---------------------------------------------------------------------------
  // trojan://password@host:port?sni=&type=...#name
  // ---------------------------------------------------------------------------
  static ProxyProfile _parseTrojan(String link) {
    final uri = _uri(link);
    final password = _userInfo(uri, 'trojan');
    final q = uri.queryParameters;

    final outbound = <String, dynamic>{
      'type': 'trojan',
      'server': _host(uri),
      'server_port': _port(uri),
      'password': password,
    };
    // Trojan is TLS by default; build TLS even if security param absent.
    final tls = _buildTls(q, defaultSni: _host(uri), forceEnabled: true);
    if (tls != null) outbound['tls'] = tls;

    final transport = _buildTransport(q);
    if (transport != null) outbound['transport'] = transport;

    return _profile('trojan', uri, outbound);
  }

  // ---------------------------------------------------------------------------
  // hysteria2://password@host:port?sni=&obfs=&obfs-password=&insecure=#name
  // ---------------------------------------------------------------------------
  static ProxyProfile _parseHysteria2(String link) {
    final uri = _uri(link);
    final password = _userInfo(uri, 'hysteria2');
    final q = uri.queryParameters;

    final outbound = <String, dynamic>{
      'type': 'hysteria2',
      'server': _host(uri),
      'server_port': _port(uri),
      'password': password,
    };

    final ports = q['mport'] ?? q['mports'];
    if (ports != null && ports.isNotEmpty) {
      outbound['server_ports'] = parseHysteriaPorts(ports);
    }

    final obfs = q['obfs'];
    if (obfs != null && obfs.isNotEmpty) {
      outbound['obfs'] = {
        'type': obfs,
        if ((q['obfs-password'] ?? '').isNotEmpty) 'password': q['obfs-password'],
      };
    }

    final sni = q['sni'] ?? q['peer'] ?? _host(uri);
    final insecure = _isTrue(q['insecure']);
    outbound['tls'] = <String, dynamic>{
      'enabled': true,
      'server_name': sni,
      if (insecure) 'insecure': true,
      if ((q['alpn'] ?? '').isNotEmpty) 'alpn': q['alpn']!.split(','),
    };

    return _profile('hysteria2', uri, outbound);
  }

  // ---------------------------------------------------------------------------
  // tuic://uuid:password@host:port?sni=&congestion_control=&alpn=#name
  // ---------------------------------------------------------------------------
  static ProxyProfile _parseTuic(String link) {
    final uri = _uri(link);
    final info = uri.userInfo;
    if (info.isEmpty) throw const ProfileParseException('tuic: missing uuid:password');
    final ci = info.indexOf(':');
    final uuid = Uri.decodeComponent(ci >= 0 ? info.substring(0, ci) : info);
    final password = ci >= 0 ? Uri.decodeComponent(info.substring(ci + 1)) : '';
    final q = uri.queryParameters;

    final outbound = <String, dynamic>{
      'type': 'tuic',
      'server': _host(uri),
      'server_port': _port(uri),
      'uuid': uuid,
      'password': password,
    };
    final cc = q['congestion_control'] ?? q['congestion'];
    if (cc != null && cc.isNotEmpty) outbound['congestion_control'] = cc;
    if ((q['udp_relay_mode'] ?? '').isNotEmpty) {
      outbound['udp_relay_mode'] = q['udp_relay_mode'];
    }

    final sni = q['sni'] ?? q['peer'] ?? _host(uri);
    outbound['tls'] = <String, dynamic>{
      'enabled': true,
      'server_name': sni,
      if (_isTrue(q['allow_insecure']) || _isTrue(q['insecure'])) 'insecure': true,
      if ((q['alpn'] ?? '').isNotEmpty) 'alpn': q['alpn']!.split(','),
    };

    return _profile('tuic', uri, outbound);
  }

  // ---------------------------------------------------------------------------
  // anytls://password@host:port?sni=&insecure=&alpn=#name
  // Anti-censorship protocol that pads/packs frames to defeat packet-size DPI.
  // ---------------------------------------------------------------------------
  static ProxyProfile _parseAnyTls(String link) {
    final uri = _uri(link);
    final password = _userInfo(uri, 'anytls');
    final q = uri.queryParameters;

    final outbound = <String, dynamic>{
      'type': 'anytls',
      'server': _host(uri),
      'server_port': _port(uri),
      'password': password,
    };
    // AnyTLS is always TLS-wrapped.
    final sni = q['sni'] ?? q['peer'] ?? _host(uri);
    final tls = <String, dynamic>{
      'enabled': true,
      'server_name': sni,
      if (_isTrue(q['insecure']) || _isTrue(q['allowInsecure'])) 'insecure': true,
      if ((q['alpn'] ?? '').isNotEmpty) 'alpn': q['alpn']!.split(','),
    };
    final fp = q['fp'];
    if (fp != null && fp.isNotEmpty) {
      tls['utls'] = {'enabled': true, 'fingerprint': fp};
    }
    outbound['tls'] = tls;

    return _profile('anytls', uri, outbound);
  }

  // ---------------------------------------------------------------------------
  // socks://[user:pass@]host:port#name   (also socks5/socks5h)
  // Generic SOCKS proxy. No transport encryption of its own.
  // ---------------------------------------------------------------------------
  static ProxyProfile _parseSocks(String link) {
    final uri = _uri(link);
    final outbound = <String, dynamic>{
      'type': 'socks',
      'server': _host(uri),
      'server_port': _port(uri),
      'version': '5',
    };
    final (user, pass) = _userPass(uri);
    if (user != null) {
      outbound['username'] = user;
      if (pass != null) outbound['password'] = pass;
    }
    return _profile('socks', uri, outbound);
  }

  // ---------------------------------------------------------------------------
  // http://[user:pass@]host:port#name  /  https:// (TLS to the proxy)
  // Generic HTTP(S) CONNECT proxy. Common for bought datacenter/residential proxies.
  // ---------------------------------------------------------------------------
  static ProxyProfile _parseHttp(String link) {
    final uri = _uri(link);
    final outbound = <String, dynamic>{
      'type': 'http',
      'server': _host(uri),
      'server_port': _port(uri),
    };
    final (user, pass) = _userPass(uri);
    if (user != null) {
      outbound['username'] = user;
      if (pass != null) outbound['password'] = pass;
    }
    if (uri.scheme.toLowerCase() == 'https') {
      outbound['tls'] = {'enabled': true, 'server_name': _host(uri)};
    }
    return _profile('http', uri, outbound);
  }

  /// Parses a ShadowTLS plugin string from an `ss://` link query, e.g.
  /// `plugin=shadow-tls;host=cloudflare.com;password=PASS;version=3`.
  /// Returns a sing-box `shadowtls` outbound (without server/port, which the
  /// caller fills in), or null when no shadow-tls plugin is present.
  static Map<String, dynamic>? _parseShadowTlsPlugin(String? query) {
    if (query == null || query.isEmpty) return null;
    final params = Uri.splitQueryString(query);
    final plugin = params['plugin'];
    if (plugin == null || !plugin.toLowerCase().contains('shadow-tls')) {
      return null;
    }
    // Plugin opts are ';'-separated key=value pairs after the plugin name.
    final opts = <String, String>{};
    for (final part in plugin.split(';')) {
      final eq = part.indexOf('=');
      if (eq > 0) opts[part.substring(0, eq).trim()] = part.substring(eq + 1).trim();
    }
    final host = opts['host'] ?? params['host'] ?? '';
    final version = int.tryParse(opts['version'] ?? params['version'] ?? '3') ?? 3;
    final stls = <String, dynamic>{
      'type': 'shadowtls',
      'version': version,
      'tls': {'enabled': true, 'server_name': host},
    };
    final pw = opts['password'] ?? params['password'];
    if (pw != null && pw.isNotEmpty) stls['password'] = pw;
    return stls;
  }

  // ===========================================================================
  // Shared helpers
  // ===========================================================================

  /// Builds a sing-box TLS object from URL query params. Returns null when TLS
  /// is not requested (and [forceEnabled] is false).
  static Map<String, dynamic>? _buildTls(
    Map<String, String> q, {
    required String defaultSni,
    bool forceEnabled = false,
  }) {
    final security = (q['security'] ?? '').toLowerCase();
    final enabled = forceEnabled || security == 'tls' || security == 'reality' || security == 'xtls';
    if (!enabled) return null;

    final sni = q['sni'] ?? q['peer'] ?? defaultSni;
    final tls = <String, dynamic>{
      'enabled': true,
      'server_name': sni,
    };
    if (_isTrue(q['allowInsecure']) || _isTrue(q['insecure'])) {
      tls['insecure'] = true;
    }
    if ((q['alpn'] ?? '').isNotEmpty) tls['alpn'] = q['alpn']!.split(',');

    final fp = q['fp'];
    if (fp != null && fp.isNotEmpty) {
      tls['utls'] = {'enabled': true, 'fingerprint': fp};
    }

    // REALITY
    final pbk = q['pbk'];
    if (security == 'reality' && pbk != null && pbk.isNotEmpty) {
      tls['reality'] = {
        'enabled': true,
        'public_key': pbk,
        if ((q['sid'] ?? '').isNotEmpty) 'short_id': q['sid'],
      };
      // REALITY requires a uTLS fingerprint; default to chrome if absent.
      tls['utls'] ??= {'enabled': true, 'fingerprint': fp ?? 'chrome'};
    }
    return tls;
  }

  /// Builds a sing-box transport object from URL query params (ws/grpc/http/httpupgrade).
  static Map<String, dynamic>? _buildTransport(Map<String, String> q) {
    final type = (q['type'] ?? 'tcp').toLowerCase();
    switch (type) {
      case 'ws':
        return {
          'type': 'ws',
          if ((q['path'] ?? '').isNotEmpty) 'path': q['path'],
          if ((q['host'] ?? '').isNotEmpty) 'headers': {'Host': q['host']},
        };
      case 'grpc':
        return {
          'type': 'grpc',
          if ((q['serviceName'] ?? '').isNotEmpty) 'service_name': q['serviceName'],
        };
      case 'http':
      case 'h2':
        return {
          'type': 'http',
          if ((q['host'] ?? '').isNotEmpty) 'host': q['host']!.split(','),
          if ((q['path'] ?? '').isNotEmpty) 'path': q['path'],
        };
      case 'httpupgrade':
        return {
          'type': 'httpupgrade',
          if ((q['host'] ?? '').isNotEmpty) 'host': q['host'],
          if ((q['path'] ?? '').isNotEmpty) 'path': q['path'],
        };
      case 'quic':
        if ((q['quicSecurity'] ?? 'none') != 'none' ||
            (q['key'] ?? '').isNotEmpty ||
            !const ['', 'none'].contains(q['headerType'] ?? '')) {
          throw const UnsupportedProfileException('QUIC obfuscation');
        }
        return {'type': 'quic'};
      case '':
      case 'tcp':
        if (!const ['', 'none'].contains(q['headerType'] ?? '')) {
          throw const UnsupportedProfileException('TCP header obfuscation');
        }
        return null;
      default:
        throw UnsupportedProfileException(safeFeature(type));
    }
  }

  /// vmess JSON variant transport (keys: net, path, host, type/grpc serviceName).
  static Map<String, dynamic>? _vmessTransport(Map<String, dynamic> j) {
    String s(String k) => (j[k] ?? '').toString();
    return _buildTransport({
      'type': s('net').isEmpty ? 'tcp' : s('net'),
      'host': s('host'),
      'path': s('path'),
      'serviceName': s('serviceName').isEmpty ? s('path') : s('serviceName'),
      'headerType': s('type'),
      if (s('net') == 'quic') 'quicSecurity': s('host').isEmpty ? 'none' : s('host'),
      if (s('net') == 'quic') 'key': s('path'),
    });
  }

  /// Do not expose arbitrary provider strings or credentials in diagnostics.
  static String safeFeature(String value) =>
      RegExp(r'^[a-zA-Z0-9_-]{1,24}$').hasMatch(value) ? value : 'unknown transport';

  /// Synthetic subscription status rows must never become dialable servers.
  static bool isPanelPlaceholder(String link) {
    try {
      final u = Uri.parse(link);
      if (!const ['vless', 'trojan'].contains(u.scheme)) return false;
      if (u.queryParameters['sni'] == 'fake_ip_for_sub_link') return true;
      final label = Uri.decodeComponent(u.fragment).toLowerCase();
      return const ['0.0.0.0', '127.0.0.1'].contains(u.host) && u.port == 1 &&
          RegExp(r'usage|expire|traffic|app.*not.*supported|device.*limit').hasMatch(label);
    } catch (_) {
      return false;
    }
  }

  static List<String> parseHysteriaPorts(String value) {
    final result = <String>[];
    for (final raw in value.split(',')) {
      final part = raw.trim();
      final match = RegExp(r'^(\d+)(?:[-:](\d+))?$').firstMatch(part);
      if (match == null) throw const ProfileParseException('Invalid Hysteria2 port range');
      final start = int.parse(match[1]!);
      final end = int.parse(match[2] ?? match[1]!);
      if (start < 1 || end > 65535 || start > end) {
        throw const ProfileParseException('Invalid Hysteria2 port range');
      }
      result.add(match[2] == null ? '$start' : '$start:$end');
    }
    return result;
  }

  static ProxyProfile _profile(String proto, Uri uri, Map<String, dynamic> outbound) {
    final name = uri.fragment.isNotEmpty
        ? Uri.decodeComponent(uri.fragment)
        : '${_host(uri)}:${_port(uri)}';
    return ProxyProfile(
      name: name,
      protocol: proto,
      server: _host(uri),
      port: _port(uri),
      outbound: outbound,
    );
  }

  static Uri _uri(String link) {
    final uri = Uri.tryParse(link);
    if (uri == null) throw const ProfileParseException('Malformed proxy URL');
    return uri;
  }

  static String _userInfo(Uri uri, String proto) {
    final info = uri.userInfo;
    if (info.isEmpty) throw ProfileParseException('$proto: missing credentials');
    return Uri.decodeComponent(info);
  }

  /// Optional `user[:pass]` from a URI's userinfo (for socks/http proxies,
  /// where auth is optional). Returns (null, null) when absent.
  ///
  /// Two forms exist in the wild: plain `user:pass@host` (v2rayN, sing-box) and
  /// base64-encoded `base64(user:pass)@host` (SIP002-style, emitted by some
  /// clients). When the raw userinfo has no literal `:`, we try base64-decoding
  /// it: if that yields a `user:pass` pair we use it; otherwise the raw value is
  /// a bare username. This keeps plain `user:pass` working while also accepting
  /// the encoded form (without it, SOCKS/HTTP auth profiles silently fail to
  /// authenticate; the whole blob lands in `username`).
  static (String?, String?) _userPass(Uri uri) {
    final info = uri.userInfo;
    if (info.isEmpty) return (null, null);

    final ci = info.indexOf(':');
    if (ci >= 0) {
      // Plain user:pass (each component possibly percent-encoded).
      return (
        Uri.decodeComponent(info.substring(0, ci)),
        Uri.decodeComponent(info.substring(ci + 1)),
      );
    }

    // No colon: might be base64(user:pass). Try to decode.
    final decoded = _tryBase64(info);
    if (decoded != null) {
      final di = decoded.indexOf(':');
      if (di >= 0) {
        return (decoded.substring(0, di), decoded.substring(di + 1));
      }
    }
    // Bare username.
    return (Uri.decodeComponent(info), null);
  }

  /// Decodes a (possibly URL-safe, unpadded) base64 string to UTF-8, returning
  /// null when the input is not valid base64 / not valid UTF-8.
  static String? _tryBase64(String s) {
    try {
      final normalized = s.replaceAll('-', '+').replaceAll('_', '/');
      return utf8.decode(base64.decode(_padBase64(normalized)));
    } catch (_) {
      return null;
    }
  }

  static String _host(Uri uri) {
    if (uri.host.isEmpty) throw const ProfileParseException('missing host');
    // Uri lowercases & strips IPv6 brackets correctly; return as-is.
    return uri.host;
  }

  static int _port(Uri uri) {
    if (!uri.hasPort || uri.port == 0) {
      throw const ProfileParseException('missing port');
    }
    return uri.port;
  }

  static (String, int) _splitHostPort(String s) {
    // Handles host:port and [ipv6]:port
    if (s.startsWith('[')) {
      final close = s.indexOf(']');
      final host = s.substring(1, close);
      final port = int.tryParse(s.substring(close + 2)) ?? 0;
      if (port == 0) throw const ProfileParseException('bad host:port');
      return (host, port);
    }
    final idx = s.lastIndexOf(':');
    if (idx < 0) throw const ProfileParseException('bad host:port');
    final host = s.substring(0, idx);
    final port = int.tryParse(s.substring(idx + 1)) ?? 0;
    if (port == 0) throw const ProfileParseException('bad host:port');
    return (host, port);
  }

  static bool _isTrue(String? v) =>
      v == '1' || (v?.toLowerCase() == 'true');

  /// base64 may be URL-safe and unpadded in share links; normalise it.
  static String _padBase64(String s) {
    var out = s.replaceAll('-', '+').replaceAll('_', '/');
    final mod = out.length % 4;
    if (mod > 0) out += '=' * (4 - mod);
    return out;
  }
}
