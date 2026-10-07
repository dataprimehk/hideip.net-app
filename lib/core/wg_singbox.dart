import 'dart:convert';
import 'dart:io' show Platform;

import 'wg_keys.dart';
import 'wg_profile.dart';

/// Builds the sing-box config that routes the TUN through a WireGuard peer.
///
/// WireGuard moved out of `outbounds` in sing-box 1.11: it is now an entry in
/// the top-level `endpoints` array with `"type": "wireguard"`, because an
/// endpoint is both an inbound and an outbound (it can receive from peers as
/// well as send). The engine here is libbox 1.13.12, well past that change, so
/// the legacy outbound form is not an option; route.final points at the
/// endpoint's tag exactly like it would at an outbound tag.
class WgSingboxConfig {
  static const String endpointTag = 'wg-out';

  /// Build the full config for [profile] exiting through [server].
  ///
  /// [privateKey] is the device's WireGuard private key, which is the only
  /// place in the app it is ever used; it goes to the local core, not over the
  /// network.
  static Map<String, dynamic> build({
    required WgProfile profile,
    required WgServer server,
    required String privateKey,
    String logLevel = 'warn',
    String? tunStack,
    bool killSwitch = false,
  }) {
    final stack = tunStack ?? (Platform.isIOS ? 'gvisor' : 'system');
    return {
      'log': {'level': logLevel, 'timestamp': true},
      'dns': {
        'servers': [
          for (var i = 0; i < profile.dns.length; i++)
            {
              'tag': 'wg-dns-$i',
              'address': profile.dns[i],
              'detour': endpointTag,
            },
          {'type': 'local', 'tag': 'local'},
          if (profile.dns.isEmpty)
            {'type': 'tls', 'tag': 'wg-dns-fallback', 'server': '1.1.1.1', 'detour': endpointTag},
        ],
        // Resolve through the tunnel so DNS cannot leak around it, and so the
        // answers reflect the exit country.
        'final': profile.dns.isEmpty ? 'wg-dns-fallback' : 'wg-dns-0',
        'strategy': 'prefer_ipv4',
      },
      'inbounds': [
        {
          'type': 'tun',
          'tag': 'tun-in',
          'address': ['172.19.0.1/30', 'fdfe:dcba:9876::1/126'],
          // Same 1280 as the stealth path, for the same reason: it is the
          // IPv6 minimum, so it survives every network, and it leaves room
          // for the WireGuard header instead of relying on fragmentation
          // that middleboxes drop.
          'mtu': wgMtu,
          'auto_route': true,
          'strict_route': killSwitch,
          'stack': stack,
        },
      ],
      'endpoints': [
        endpoint(
          profile: profile,
          server: server,
          privateKey: privateKey,
        ),
      ],
      'outbounds': [
        {'type': 'direct', 'tag': 'direct'},
      ],
      'route': {
        'auto_detect_interface': true,
        'default_domain_resolver': 'local',
        'final': endpointTag,
        'rules': [
          {'action': 'sniff'},
          {'protocol': 'dns', 'action': 'hijack-dns'},
        ],
      },
    };
  }

  /// The `endpoints[]` entry itself.
  ///
  /// `system: false` keeps the WireGuard implementation in userspace. The
  /// system option would have the core create its own kernel interface, which
  /// on Android and iOS collides with the TUN the platform already handed us,
  /// and needs privileges an app does not have.
  static Map<String, dynamic> endpoint({
    required WgProfile profile,
    required WgServer server,
    required String privateKey,
  }) =>
      {
        'type': 'wireguard',
        'tag': endpointTag,
        'system': false,
        // The single address the backend assigned this device, e.g.
        // "10.66.0.10/32". Globally unique across the fleet, so the same
        // address is valid on whichever server we exit through.
        'address': [profile.address],
        'private_key': privateKey,
        'mtu': profile.effectiveMtu,
        'peers': [
          {
            'address': server.host,
            'port': server.port,
            'public_key': server.serverPubkey,
            'allowed_ips': profile.allowedIps,
            // Keeps the NAT mapping open on mobile networks, which drop idle
            // UDP flows aggressively; without it the tunnel goes quiet and
            // only recovers on the next outbound packet.
            'persistent_keepalive_interval': profile.persistentKeepalive,
          },
        ],
      };

  /// Convenience: build + encode for [VpnController.start].
  static String buildJson({
    required WgProfile profile,
    required WgServer server,
    required String privateKey,
    String logLevel = 'warn',
    String? tunStack,
    bool killSwitch = false,
  }) =>
      jsonEncode(build(
        profile: profile,
        server: server,
        privateKey: privateKey,
        logLevel: logLevel,
        tunStack: tunStack,
        killSwitch: killSwitch,
      ));

  /// Whether [privateKey] is shaped like something the core will accept.
  /// A malformed key makes sing-box fail at start with an opaque message, so
  /// the caller checks first and falls back to stealth instead.
  static bool usableKey(String privateKey) => WgKeys.isValidKey(privateKey);
}
