import 'dart:collection';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:http/http.dart' as http;

import 'proxy_profile.dart';
import 'safe_http.dart';
import 'share_link_parser.dart';

const Duration catalogSourceTimeout = Duration(seconds: 4);

/// Ceiling on a catalog response. The real document is a few kilobytes; a
/// mirror that answers with something far larger is either broken or hostile,
/// and neither is worth parsing or verifying.
const int catalogMaxBytes = 512 * 1024;

/// The public half of the fixture key in `test/catalog_test.dart`, whose seed
/// is bytes 0..31 and therefore public knowledge in this GPLv3 repository.
/// Shipping it would let anyone sign a catalog pointing at their own servers.
const String _testVerificationPublicKey =
    'A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg=';

/// Fixed public key for the catalog signature verifier.
///
/// TODO(filip): pass the production key through
/// `--dart-define=HIDEIP_CATALOG_PUBLIC_KEY=...` in the release build.
const String catalogVerificationPublicKey = String.fromEnvironment(
  'HIDEIP_CATALOG_PUBLIC_KEY',
  defaultValue: _testVerificationPublicKey,
);

/// Whether the build is still verifying against the published fixture key.
bool get catalogUsesTestKey =>
    catalogVerificationPublicKey == _testVerificationPublicKey;

/// A release build will not touch a catalog while the fixture key is in
/// place. Verifying against a key whose private half is published is worse
/// than not verifying at all, and falling back to /v1/sub costs nothing.
/// Debug builds keep the catalog path so it stays testable before the real
/// key exists.
bool get catalogVerificationIsUsable => !(kReleaseMode && catalogUsesTestKey);

/// The local part of a premium credential needed to combine a public catalog
/// with the user's existing entitlement.
class CatalogIdentity {
  final String uuid;
  final String subToken;

  const CatalogIdentity({required this.uuid, required this.subToken});
}

class CatalogEndpoint {
  final String protocol;
  final int port;
  final String publicKey;
  final String shortId;
  final String sni;
  final String flow;

  const CatalogEndpoint({
    required this.protocol,
    required this.port,
    required this.publicKey,
    required this.shortId,
    required this.sni,
    required this.flow,
  });
}

class CatalogServer {
  final String id;
  final String label;
  final String host;
  final int sortWeight;
  final String audience;
  final List<CatalogEndpoint> endpoints;

  /// `premium` or `free`. A catalog from before the free location has no
  /// tier on any server, and every one of them is premium.
  final String tier;

  const CatalogServer({
    required this.id,
    required this.label,
    required this.host,
    required this.sortWeight,
    required this.audience,
    required this.endpoints,
    this.tier = 'premium',
  });

  /// A server of the free location: never a premium profile and never a
  /// locked premium row. A tier this build does not know is premium.
  bool get free => tier == 'free';
}

class CatalogDocument {
  final int epoch;
  final DateTime generatedAt;
  final List<CatalogServer> servers;

  const CatalogDocument({
    required this.epoch,
    required this.generatedAt,
    required this.servers,
  });
}

/// JSON encoding shared with the backend signer: recursively sorted object
/// keys, UTF-8 content and no insignificant whitespace.
String canonicalCatalogJson(Object? value) => jsonEncode(_sortedJson(value));

Object? _sortedJson(Object? value) {
  if (value is Map) {
    final sorted = SplayTreeMap<String, Object?>();
    for (final entry in value.entries) {
      if (entry.key is! String) {
        throw const FormatException('Catalog object keys must be strings');
      }
      sorted[entry.key as String] = _sortedJson(entry.value);
    }
    return sorted;
  }
  if (value is List) return value.map(_sortedJson).toList(growable: false);
  if (value == null || value is String || value is bool || value is num) {
    return value;
  }
  throw const FormatException('Catalog contains a non-JSON value');
}

/// Decode a catalog only after its detached field verifies against [publicKey].
/// Empty, malformed and incorrectly signed documents are all rejected.
Future<CatalogDocument?> decodeVerifiedCatalog(
  String body,
  String publicKey,
) async {
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) return null;
    final encodedSignature = decoded['signature'];
    if (encodedSignature is! String || encodedSignature.isEmpty) return null;

    final signatureBytes = base64Decode(encodedSignature);
    final publicKeyBytes = base64Decode(publicKey);
    if (signatureBytes.length != 64 || publicKeyBytes.length != 32) return null;

    final unsigned = Map<String, dynamic>.from(decoded)..remove('signature');
    final verified = await Ed25519().verify(
      utf8.encode(canonicalCatalogJson(unsigned)),
      signature: Signature(
        signatureBytes,
        publicKey: SimplePublicKey(publicKeyBytes, type: KeyPairType.ed25519),
      ),
    );
    if (!verified) return null;
    return _parseCatalog(unsigned);
  } catch (_) {
    return null;
  }
}

CatalogDocument _parseCatalog(Map<String, dynamic> value) {
  final epoch = value['epoch'];
  final generatedAtRaw = value['generated_at'];
  final serverValues = value['servers'];
  if (epoch is! int || epoch < 0) {
    throw const FormatException('Catalog epoch is invalid');
  }
  if (generatedAtRaw is! String || !generatedAtRaw.endsWith('Z')) {
    throw const FormatException('Catalog generated_at is invalid');
  }
  final generatedAt = DateTime.parse(generatedAtRaw);
  if (serverValues is! List) {
    throw const FormatException('Catalog servers are invalid');
  }

  final servers = <CatalogServer>[];
  for (final serverValue in serverValues) {
    if (serverValue is! Map<String, dynamic>) {
      throw const FormatException('Catalog server is invalid');
    }
    final id = serverValue['id'];
    final label = serverValue['label'];
    final host = serverValue['host'];
    final sortWeight = serverValue['sort_weight'];
    final audience = serverValue['audience'];
    final endpointValues = serverValue['endpoints'];
    final tier = serverValue['tier'];
    if (id is! String ||
        id.isEmpty ||
        label is! String ||
        host is! String ||
        host.isEmpty ||
        sortWeight is! int ||
        audience is! String ||
        endpointValues is! List ||
        (tier != null && tier is! String)) {
      throw const FormatException('Catalog server fields are invalid');
    }

    final endpoints = <CatalogEndpoint>[];
    for (final endpointValue in endpointValues) {
      if (endpointValue is! Map<String, dynamic>) {
        throw const FormatException('Catalog endpoint is invalid');
      }
      final protocol = endpointValue['protocol'];
      final port = endpointValue['port'];
      final publicKey = endpointValue['public_key'];
      final shortId = endpointValue['short_id'];
      final sni = endpointValue['sni'];
      final flow = endpointValue['flow'];
      if (protocol is! String ||
          protocol.isEmpty ||
          port is! int ||
          port < 1 ||
          port > 65535 ||
          publicKey is! String ||
          shortId is! String ||
          sni is! String ||
          flow is! String) {
        throw const FormatException('Catalog endpoint fields are invalid');
      }
      endpoints.add(
        CatalogEndpoint(
          protocol: protocol,
          port: port,
          publicKey: publicKey,
          shortId: shortId,
          sni: sni,
          flow: flow,
        ),
      );
    }
    servers.add(
      CatalogServer(
        id: id,
        label: label,
        host: host,
        sortWeight: sortWeight,
        audience: audience,
        endpoints: endpoints,
        tier: (tier as String?)?.trim().toLowerCase() ?? 'premium',
      ),
    );
  }
  return CatalogDocument(
    epoch: epoch,
    generatedAt: generatedAt,
    servers: servers,
  );
}

/// Fetch mirrors in order and return the first verified, non-rollback catalog.
class CatalogClient {
  final SafeHttpFetcher _fetcher;
  final List<Uri> sources;
  final String publicKey;
  final Duration timeout;

  CatalogClient({
    http.Client? client,
    required List<Uri> sources,
    required this.publicKey,
    this.timeout = catalogSourceTimeout,
  }) : _fetcher = client == null
           ? SafeHttpFetcher()
           : SafeHttpFetcher.forTesting(client),
       sources = List.unmodifiable(sources);

  Future<CatalogDocument?> fetch({int? minimumEpoch}) async {
    if (!catalogVerificationIsUsable) return null;
    for (final source in sources) {
      try {
        // No User-Agent and no other identifying header. The catalog is a
        // static public document, so nothing here needs to say which client
        // asked for it, and mirrors are third parties: a fixed self-naming
        // header would let anyone watching that traffic enumerate our users.
        final response = await _fetcher.get(
          source,
          maxBytes: catalogMaxBytes,
          timeout: timeout,
        );
        if (response.statusCode != 200) continue;
        final catalog = await decodeVerifiedCatalog(response.body, publicKey);
        if (catalog == null) continue;
        if (minimumEpoch != null && catalog.epoch < minimumEpoch) continue;
        return catalog;
      } catch (_) {
        continue;
      }
    }
    return null;
  }
}

/// Recover the local UUID from trusted premium profiles and the subscription
/// token from the URL that delivered them. Conflicting UUIDs are rejected.
CatalogIdentity? catalogIdentityFromProfiles(
  String subscriptionUrl,
  Iterable<ProxyProfile> profiles,
) {
  final token = _subscriptionToken(subscriptionUrl);
  if (token == null) return null;
  final uuids = profiles
      .where((profile) => profile.premium)
      .map((profile) => profile.outbound['uuid'])
      .whereType<String>()
      .where((uuid) => uuid.isNotEmpty)
      .toSet();
  if (uuids.length != 1) return null;
  return CatalogIdentity(uuid: uuids.single, subToken: token);
}

bool catalogIdentityMatchesSubscription(
  CatalogIdentity identity,
  String subscriptionUrl,
) => _subscriptionToken(subscriptionUrl) == identity.subToken;

String? _subscriptionToken(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
  final segments = uri.pathSegments;
  if (segments.length < 3 ||
      segments[segments.length - 2] != 'sub' ||
      segments[segments.length - 3] != 'v1') {
    return null;
  }
  final token = segments.last;
  return token.isEmpty ? null : token;
}

/// Build phone profiles from public Reality endpoints and one local UUID.
List<ProxyProfile> profilesFromCatalog(
  CatalogDocument catalog,
  CatalogIdentity identity,
) {
  final servers = [...catalog.servers]
    ..sort((a, b) {
      final weight = a.sortWeight.compareTo(b.sortWeight);
      return weight == 0 ? a.id.compareTo(b.id) : weight;
    });
  final profiles = <ProxyProfile>[];
  for (final server in servers) {
    if (!_audienceAllowsPhone(server.audience)) continue;
    // A premium key does not work on a free node, and the free key never
    // comes this way: free servers are not premium profiles.
    if (server.free) continue;
    for (final endpoint in server.endpoints) {
      if (endpoint.protocol != 'vless-reality' || endpoint.publicKey.isEmpty) {
        continue;
      }
      final uri = Uri(
        scheme: 'vless',
        userInfo: identity.uuid,
        host: server.host,
        port: endpoint.port,
        queryParameters: {
          'security': 'reality',
          'pbk': endpoint.publicKey,
          if (endpoint.shortId.isNotEmpty) 'sid': endpoint.shortId,
          'fp': 'chrome',
          if (endpoint.sni.isNotEmpty) 'sni': endpoint.sni,
          if (endpoint.flow.isNotEmpty) 'flow': endpoint.flow,
        },
        fragment: server.label,
      );
      final profile = ShareLinkParser.parse(uri.toString());
      if (profile != null) profiles.add(profile.copyWith(premium: true));
    }
  }
  return profiles;
}

/// Mirrors `audience_allows` on the control plane exactly: "all" is only a
/// wildcard when it is the entire value, never as one member of a list. A
/// looser reading here would show a server the subscription path withholds.
bool _audienceAllowsPhone(String value) {
  final trimmed = value.trim();
  if (trimmed == 'all') return true;
  return trimmed.split(',').map((part) => part.trim()).contains('phone');
}
