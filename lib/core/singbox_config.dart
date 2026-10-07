import 'dart:convert';
import 'dart:io' show Platform;

import 'proxy_profile.dart';

/// Assembles a full sing-box (1.13.x) config JSON from a [ProxyProfile].
///
/// The TUN inbound mirrors the proven Blok 2 test config (MTU 1280, auto_route,
/// auto_detect_interface). The chosen profile becomes the "proxy" outbound and
/// route.final points to it; a direct + dns outbound remain so DNS and bypass
/// traffic still work.
///
/// The TUN stack is platform-specific. Android hands the core the real tun file
/// descriptor, so the "system" stack reads and writes it directly. iOS
/// NEPacketTunnelProvider does not expose the descriptor that way; the core has
/// to move packets through the packetFlow object, which only the "gvisor" stack
/// does. Picking "system" on iOS brings the tunnel up but no packet ever flows,
/// so the exit IP never changes.
class SingboxConfig {
  static const String proxyTag = 'proxy';

  /// Build the config for a single selected [profile]. [logLevel] is "info"
  /// during development; switch to "warn" for release builds. [tunStack] lets
  /// tests pin the stack; it defaults to the right one for the platform.
  /// [killSwitch] turns on strict_route, which closes the routing side-doors
  /// around the TUN while the tunnel is up (the drop-recovery half of the
  /// kill switch lives in the native layer).
  static Map<String, dynamic> build(
    ProxyProfile profile, {
    String logLevel = 'warn',
    String? tunStack,
    bool killSwitch = false,
  }) {
    final stack = tunStack ?? (Platform.isIOS ? 'gvisor' : 'system');
    return {
      'log': {'level': logLevel, 'timestamp': true},
      'dns': {
        'servers': [
          {'type': 'tls', 'tag': 'remote', 'server': '1.1.1.1', 'detour': proxyTag},
          {'type': 'local', 'tag': 'local'},
        ],
        'final': 'remote',
        'strategy': 'prefer_ipv4',
      },
      'inbounds': [
        {
          'type': 'tun',
          'tag': 'tun-in',
          'address': ['172.19.0.1/30', 'fdfe:dcba:9876::1/126'],
          // 1280 is the IPv6 minimum MTU: it is guaranteed to traverse every
          // network (DSL/PPPoE, cellular, double-NAT, restrictive carriers) and
          // leaves ample headroom for any proxy encapsulation (Reality/Vision,
          // ShadowTLS, QUIC). A 1500 tun MTU silently dropped large packets over
          // an encapsulated link: small HTTP passed, HTTPS bursts/speedtests
          // failed. We trade a little per-packet efficiency for "never breaks".
          'mtu': 1280,
          'auto_route': true,
          'strict_route': killSwitch,
          'stack': stack,
        },
      ],
      // A WireGuard profile is an `endpoints[]` entry, not an outbound (see
      // [ProxyProfile.isEndpoint]). The key stays "endpoints" only when there
      // is one, because sing-box rejects an empty array here.
      if (profile.isEndpoint) 'endpoints': [profile.taggedOutbound(proxyTag)],
      'outbounds': [
        if (!profile.isEndpoint) profile.taggedOutbound(proxyTag),
        ...profile.extraOutbounds,
        {'type': 'direct', 'tag': 'direct'},
      ],
      'route': {
        'auto_detect_interface': true,
        'default_domain_resolver': 'local',
        'final': proxyTag,
        'rules': [
          // Keep DNS queries and private ranges off the tunnel sanely.
          {'action': 'sniff'},
          {'protocol': 'dns', 'action': 'hijack-dns'},
        ],
      },
    };
  }

  /// Convenience: build + encode to the JSON string VpnController.start expects.
  static String buildJson(ProxyProfile profile,
          {String logLevel = 'warn', String? tunStack, bool killSwitch = false}) =>
      jsonEncode(build(profile,
          logLevel: logLevel, tunStack: tunStack, killSwitch: killSwitch));
}
