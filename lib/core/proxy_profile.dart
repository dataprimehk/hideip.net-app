/// One parsed proxy server. Holds the sing-box outbound map plus display info.
///
/// [outbound] is a sing-box outbound object (e.g. {"type":"vless", ...}) WITHOUT
/// a "tag"; the tag is assigned by [SingboxConfig] when the full config is built,
/// so a profile can be reused under different tags. [name] is the human label
/// (from the link fragment or subscription), [protocol] the scheme (vless, etc.).
class ProxyProfile {
  final String name;
  final String protocol;
  final String server;
  final int port;
  final Map<String, dynamic> outbound;

  /// Supporting outbounds this profile's [outbound] depends on (e.g. a
  /// ShadowTLS outbound that the shadowsocks outbound detours into). These
  /// already carry their own "tag" and are added to the config as-is.
  final List<Map<String, dynamic>> extraOutbounds;

  /// True when [outbound] is a sing-box `endpoints[]` entry rather than an
  /// `outbounds[]` one, which is where WireGuard lives from sing-box 1.11 on:
  /// an endpoint both receives from peers and sends, so it is not an outbound.
  /// The tag works the same either way, so `route.final` still points at it;
  /// only the array it is placed in differs. See [SingboxConfig.build].
  final bool isEndpoint;

  /// Country code geolocated from [server] when the name reveals no location
  /// (most bare-IP links). Null until (and unless) that lookup succeeds.
  final String? cc;

  /// True for profiles managed by the hideip.net premium subscription (they
  /// came from the provisioning backend, not a user import). Managed profiles
  /// are replaced wholesale on refresh and removed when the subscription
  /// lapses; user imports are never touched.
  final bool premium;

  /// For a profile imported from a user's own subscription URL, that URL.
  /// Null for single-link imports and pasted blobs (nothing to re-fetch).
  /// The app re-pulls each distinct [subUrl] on launch so a provider rotating
  /// its servers doesn't silently strand the user on dead nodes.
  final String? subUrl;

  /// The name the user gave this server, which wins over [name] everywhere a
  /// server is listed. Null means they never renamed it. The provider's own
  /// name is kept either way, so a rename never loses where the server came
  /// from and can always be undone.
  final String? customName;

  /// The text this profile was imported from: the share link, or the whole
  /// WireGuard file. Kept so the server can be edited as the user first saw
  /// it rather than as a rebuilt approximation. Null for profiles that came
  /// out of a subscription body, a rebuilt form stands in for those (see
  /// `srvEditText`). It holds the same credentials the outbound does and
  /// lives in the same protected store.
  final String? source;

  const ProxyProfile({
    required this.name,
    required this.protocol,
    required this.server,
    required this.port,
    required this.outbound,
    this.extraOutbounds = const [],
    this.isEndpoint = false,
    this.cc,
    this.premium = false,
    this.subUrl,
    this.customName,
    this.source,
  });

  /// Sentinel for [copyWith]: tells "leave it alone" apart from "set it to
  /// null", which a plain optional argument cannot express.
  static const _keep = Object();

  ProxyProfile copyWith({
    String? name,
    String? cc,
    bool? premium,
    String? subUrl,
    Object? customName = _keep,
    Object? source = _keep,
  }) =>
      ProxyProfile(
        name: name ?? this.name,
        protocol: protocol,
        server: server,
        port: port,
        outbound: outbound,
        extraOutbounds: extraOutbounds,
        isEndpoint: isEndpoint,
        cc: cc ?? this.cc,
        premium: premium ?? this.premium,
        subUrl: subUrl ?? this.subUrl,
        customName: identical(customName, _keep)
            ? this.customName
            : customName as String?,
        source: identical(source, _keep) ? this.source : source as String?,
      );

  /// The fields added after the profile store's map was first laid out, in
  /// the shape the store persists. The store spreads this into its map and
  /// hands the map back to [withStoredExtras] on load, so a new field is
  /// declared here once and older saved lists, which lack it, still read.
  Map<String, dynamic> get storedExtras => {
        if (source != null) 'source': source,
      };

  /// This profile with the fields of [storedExtras] read back from [m].
  ProxyProfile withStoredExtras(Map<String, dynamic> m) => copyWith(
        source: m['source'] as String?,
      );

  /// A copy of [outbound] with the given [tag] injected.
  Map<String, dynamic> taggedOutbound(String tag) => {
        'tag': tag,
        ...outbound,
      };

  @override
  String toString() => '$protocol://$server:$port ($name)';
}

/// Thrown when a share link cannot be parsed into a [ProxyProfile].
class ProfileParseException implements Exception {
  final String message;
  const ProfileParseException(this.message);
  @override
  String toString() => 'ProfileParseException: $message';
}
