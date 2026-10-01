import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'account_number.dart';
import 'account_service.dart';
import 'app_version.dart';
import 'catalog.dart';
import 'premium.dart';
import 'profile_store.dart';
import 'proxy_profile.dart';
import 'safe_http.dart';
import 'secret_prefs.dart';
import 'subscription.dart';

const String provisioningEndpoint = 'https://api.hideip.net:8444';
const String _catalogApiSource = 'https://api.hideip.net:8443/v1/catalog';
const String _catalogDirectSource = '$provisioningEndpoint/v1/catalog';
// TODO(filip): Set the public R2 and Firebase catalog URLs in release dart-defines.
const String _catalogR2Source = String.fromEnvironment('HIDEIP_CATALOG_R2_URL');
const String _catalogFirebaseSource = String.fromEnvironment(
  'HIDEIP_CATALOG_FIREBASE_URL',
);
const List<String> catalogSourceUrls = [
  _catalogApiSource,
  if (_catalogR2Source != '') _catalogR2Source,
  if (_catalogFirebaseSource != '') _catalogFirebaseSource,
  _catalogDirectSource,
];

class PremiumProfileRefresh {
  final List<ProxyProfile>? profiles;
  final int? catalogEpoch;

  /// The subscription URL a self-heal re-provision issued, already persisted
  /// here. Set only when the previous one was retired mid-subscription; the
  /// caller uses it for the state that hangs off the URL (the link token, the
  /// WireGuard peer).
  final String? renewedUrl;

  /// The subscription is over rather than merely re-issued: the retired URL
  /// survived a re-provision with the stored purchase proof, or no proof was
  /// left to try it with. Only ever true alongside an empty [profiles].
  final bool expired;

  const PremiumProfileRefresh({
    this.profiles,
    this.catalogEpoch,
    this.renewedUrl,
    this.expired = false,
  });

  bool get changed => profiles != null;
}

/// How a `/v1/provision` attempt ended.
enum ProvisionStatus {
  /// Credentials came back.
  ok,

  /// The store proof buys nothing any more (404/410): the subscription really
  /// has lapsed, whatever the store's cached entitlement still says.
  gone,

  /// Network trouble, a timeout, or a server-side error. Nothing is decided;
  /// retry on the next refresh.
  transient,
}

/// The outcome of `POST /v1/provision`. [url] is set for [ProvisionStatus.ok]
/// and null otherwise.
class ProvisionResult {
  final ProvisionStatus status;
  final String? url;

  /// The account number the purchase adds time to, when the request asked
  /// for one (`v: 2`) and the backend answered with it. Null on an answer
  /// from a backend that does not link purchases to an account yet: the app
  /// then runs on [url] the way it always has.
  final ProvisionAccount? account;

  const ProvisionResult(this.status, [this.url, this.account]);
}

/// The `account` block of a `v: 2` provision answer: the account number a
/// store purchase adds its time to, and this device's place on it.
class ProvisionAccount {
  /// Why the purchase could not go onto an account, or null when it did:
  /// [linkedElsewhere], `device_limit_reached` or `unavailable`. An answer
  /// this app cannot use reads as `unavailable`.
  final String? error;

  /// How the purchase met the account: `new` (the number was made just
  /// now), `joined` (the number this device sent) or `existing`.
  final String? linked;

  /// The number, canonical. Only in the answer that made it; every later
  /// answer about the same purchase leaves it out.
  final String? number;
  final bool active;
  final DateTime? expires;

  /// What the last payment on the account was: `monthly`, `yearly` or
  /// `trial`.
  final String? kind;
  final String? deviceToken;
  final String? deviceId;
  final String? deviceName;
  final String? subscriptionUrl;
  final int deviceLimit;

  /// The store the purchase was made in (`ios` or `android`), and when its
  /// current period ends by the store's own word.
  final String? storePlatform;
  final DateTime? storeExpires;

  static const linkedElsewhere = 'linked_elsewhere';
  static const unavailable = 'unavailable';

  const ProvisionAccount({
    this.error,
    this.linked,
    this.number,
    this.active = false,
    this.expires,
    this.kind,
    this.deviceToken,
    this.deviceId,
    this.deviceName,
    this.subscriptionUrl,
    this.deviceLimit = AccountService.defaultDeviceLimit,
    this.storePlatform,
    this.storeExpires,
  });

  /// Whether this device is on an account with time, with everything it
  /// needs to run on it.
  bool get usable => error == null;

  /// Reads the block, or null when there is none to read.
  static ProvisionAccount? fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final limitRaw = raw['device_limit'];
    final limit = limitRaw is num && limitRaw > 0
        ? limitRaw.toInt()
        : AccountService.defaultDeviceLimit;
    final error = _text(raw['error']);
    if (error != null) return ProvisionAccount(error: error, deviceLimit: limit);
    final device = raw['device'];
    final deviceMap = device is Map<String, dynamic> ? device : null;
    final store = raw['store'];
    final storeMap = store is Map<String, dynamic> ? store : null;
    final digits = normalizeAccountNumber(_text(raw['number']) ?? '');
    final account = ProvisionAccount(
      linked: _text(raw['linked']),
      number: isValidAccountNumber(digits) ? digits : null,
      active: raw['active'] == true,
      expires: _ms(raw['expires_ms']),
      kind: _text(raw['kind']),
      deviceToken: _text(raw['device_token']),
      deviceId: _text(deviceMap?['id']),
      deviceName: _text(deviceMap?['name']),
      subscriptionUrl: _text(raw['subscription_url']),
      deviceLimit: limit,
      storePlatform: _text(storeMap?['platform']),
      storeExpires: _ms(storeMap?['expires_ms']),
    );
    // An account without time, or without the token and the URL this
    // device runs on, is nothing the app can stand on; the purchase then
    // works the way it did before accounts.
    if (!account.active ||
        account.deviceToken == null ||
        account.subscriptionUrl == null) {
      return ProvisionAccount(error: unavailable, deviceLimit: limit);
    }
    return account;
  }

  static String? _text(Object? raw) {
    final s = raw?.toString().trim() ?? '';
    return s.isEmpty ? null : s;
  }

  static DateTime? _ms(Object? raw) {
    final n = raw is num ? raw.toInt() : int.tryParse(raw?.toString() ?? '');
    if (n == null || n <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(n);
  }
}

/// Exchanges a verified store purchase for tunnel credentials on hideip.net
/// servers. Anonymous by design: the signed proof is the only identifier the
/// backend ever sees; it re-validates the proof against Apple (iOS JWS) or
/// Google (Android purchase token) before issuing anything.
class ProvisioningService {
  static const String endpoint = provisioningEndpoint;

  final http.Client _client;
  final SafeHttpFetcher _safeFetcher;
  final List<Uri> _catalogSources;
  final String _catalogPublicKey;
  final Duration _catalogTimeout;

  ProvisioningService({
    http.Client? client,
    List<Uri>? catalogSources,
    String? catalogPublicKey,
    Duration? catalogTimeout,
  }) : _client = client ?? http.Client(),
       _safeFetcher = client == null
           ? SafeHttpFetcher()
           : SafeHttpFetcher.forTesting(client),
       _catalogSources =
           catalogSources ??
           catalogSourceUrls.map(Uri.parse).toList(growable: false),
       _catalogPublicKey = catalogPublicKey ?? catalogVerificationPublicKey,
       _catalogTimeout = catalogTimeout ?? catalogSourceTimeout;

  /// Send the signed purchase proof and get back the subscription URL the
  /// profiles live at. The body is per-store: iOS keeps
  /// `{platform: ios, jws}`; Android sends
  /// `{platform: android, purchase_token, product_id}`.
  ///
  /// Only 404/410 is a verdict on the purchase; everything else (including a
  /// 200 without a URL) is transient, so a broken backend never reads as a
  /// lapsed subscription.
  ///
  /// With [v2] the purchase also goes onto an account number: the one
  /// [deviceToken] belongs to when this device is on one, otherwise the one
  /// the purchase already adds time to, or a new one. The answer says which
  /// in [ProvisionResult.account].
  Future<ProvisionResult> provision(
    PurchasePayload payload, {
    bool v2 = false,
    String? deviceToken,
  }) async {
    try {
      final resp = await _client
          .post(
            Uri.parse('$endpoint/v1/provision'),
            headers: {'content-type': 'application/json'},
            body: jsonEncode(
              provisionBody(payload, v2: v2, deviceToken: deviceToken),
            ),
          )
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode == 404 || resp.statusCode == 410) {
        return const ProvisionResult(ProvisionStatus.gone);
      }
      if (resp.statusCode != 200) {
        return const ProvisionResult(ProvisionStatus.transient);
      }
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      final url = body['subscription_url'] as String?;
      if (url == null || url.isEmpty) {
        return const ProvisionResult(ProvisionStatus.transient);
      }
      return ProvisionResult(
        ProvisionStatus.ok,
        url,
        v2 ? ProvisionAccount.fromJson(body['account']) : null,
      );
    } catch (_) {
      return const ProvisionResult(ProvisionStatus.transient);
    }
  }

  /// Fetch and parse the premium subscription. Null on any failure so the
  /// caller can keep whatever it already has (transient network trouble must
  /// not drop a working profile); an empty list only on a definitive "gone"
  /// (subscription lapsed server-side).
  Future<List<ProxyProfile>?> fetchProfiles(String subscriptionUrl) async =>
      (await refreshProfiles(subscriptionUrl))?.profiles;

  /// Prefer a signed public catalog and locally held UUID. The legacy
  /// subscription remains the final fallback and also bootstraps old installs
  /// whose profile cache predates the separately persisted identity.
  ///
  /// [healLapsed] spends the stored purchase proof on one re-provision when
  /// that fallback finds the URL retired; pass false right after a provision,
  /// where a second one would only ask the same question twice.
  Future<PremiumProfileRefresh?> refreshProfiles(
    String subscriptionUrl, {
    Iterable<ProxyProfile>? cachedProfiles,
    bool healLapsed = true,
  }) async {
    final storedIdentity = await PremiumSub.identity();
    var identity = storedIdentity;
    if (identity != null &&
        !catalogIdentityMatchesSubscription(identity, subscriptionUrl)) {
      identity = null;
    }
    if (identity == null && storedIdentity == null) {
      identity = catalogIdentityFromProfiles(
        subscriptionUrl,
        cachedProfiles ?? await ProfileStore.load(),
      );
      if (identity != null) await PremiumSub.saveIdentity(identity);
    }

    if (identity != null) {
      // TODO(filip): Define an out-of-band epoch signal; the current API cannot reveal an epoch change without fetching a catalog.
      final knownEpoch = await PremiumSub.catalogEpoch();
      final catalog = await CatalogClient(
        client: _client,
        sources: _catalogSources,
        publicKey: _catalogPublicKey,
        timeout: _catalogTimeout,
      ).fetch(minimumEpoch: knownEpoch);
      if (catalog != null) {
        if (catalog.epoch == knownEpoch) {
          return PremiumProfileRefresh(catalogEpoch: catalog.epoch);
        }
        try {
          final profiles = profilesFromCatalog(catalog, identity);
          if (profiles.isNotEmpty) {
            return PremiumProfileRefresh(
              profiles: profiles,
              catalogEpoch: catalog.epoch,
            );
          }
        } catch (_) {
          // A signed but unusable catalog must not displace working profiles.
        }
      }
    }

    final legacy = await _fetchLegacyProfiles(subscriptionUrl);
    if (legacy == null || !legacy.expired || !healLapsed) return legacy;
    return _healRetiredSubscription();
  }

  /// The subscription URL is retired server-side. A renewal issues a new one
  /// while the old one is already dead, so spend the stored proof on exactly
  /// one re-provision before calling the subscription over: the stores keep
  /// charging across that gap, and only a backend that refuses the proof
  /// itself is an expiry.
  Future<PremiumProfileRefresh?> _healRetiredSubscription() async {
    final proof = await PremiumSub.proof();
    if (proof == null) return _lapsed;
    final result = await provision(proof);
    final url = result.url;
    if (url == null) {
      // Only an outright refusal decides anything; a backend that could not
      // answer leaves the cache in place for the next refresh to retry.
      return result.status == ProvisionStatus.gone ? _lapsed : null;
    }
    await PremiumSub.saveUrl(url);
    final healed = await _fetchLegacyProfiles(url);
    // A URL that is issued and gone in the same breath leaves nothing to try;
    // a transient failure on it keeps the cache, as everywhere else.
    if (healed == null) return PremiumProfileRefresh(renewedUrl: url);
    return PremiumProfileRefresh(
      profiles: healed.profiles,
      expired: healed.expired,
      renewedUrl: url,
    );
  }

  /// The subscription is over: no servers, and the caller may say so.
  static const _lapsed = PremiumProfileRefresh(profiles: [], expired: true);

  Future<PremiumProfileRefresh?> _fetchLegacyProfiles(
    String subscriptionUrl,
  ) async {
    try {
      final resp = await _safeFetcher.get(
        Uri.parse(subscriptionUrl),
        headers: subscriptionHeaders,
      );
      if (resp.statusCode == 404 || resp.statusCode == 410) return _lapsed;
      if (resp.statusCode != 200) return null;
      // Everything this URL serves is subscription-managed by definition;
      // the flag (not the name) is what marks a profile as ours, so the
      // backend is free to label servers by plain location.
      final parsed = await Subscription.parseAsync(resp.body);
      final profiles = parsed.profiles
          .map((p) => p.copyWith(premium: true))
          .toList();
      if (profiles.isEmpty) return null;
      final identity = catalogIdentityFromProfiles(subscriptionUrl, profiles);
      if (identity != null) await PremiumSub.saveIdentity(identity);
      return PremiumProfileRefresh(profiles: profiles);
    } catch (_) {
      return null;
    }
  }
}

/// The `/v1/provision` request body for [payload], per the client/backend
/// contract. iOS is unchanged from the JWS-only era (`{platform, jws}`);
/// Android sends the Play token under snake_case keys the backend expects.
///
/// [v2] asks for the account the purchase adds time to, and names this
/// device the way an account sign-in does; [deviceToken] says which account
/// this device is already on.
Map<String, dynamic> provisionBody(
  PurchasePayload payload, {
  bool v2 = false,
  String? deviceToken,
}) => {
  ...payload.platform == 'android'
      ? {
          'platform': 'android',
          'purchase_token': payload.purchaseToken,
          'product_id': payload.productId,
        }
      : {'platform': 'ios', 'jws': payload.jws},
  if (v2) ...{
    'v': 2,
    'device_token': ?deviceToken,
    'device': {'kind': 'phone', 'name': accountDeviceName},
  },
};

/// Replace the premium-managed profiles inside [current] with [fresh],
/// leaving every user-imported profile untouched and in place.
List<ProxyProfile> mergePremiumProfiles(
  List<ProxyProfile> current,
  List<ProxyProfile> fresh,
) {
  final kept = current.where((p) => !isPremiumProfile(p)).toList();
  return [...kept, ...fresh];
}

/// Whether [p] is managed by the premium subscription (vs user-imported).
bool isPremiumProfile(ProxyProfile p) => p.premium;

/// Persisted pointers for the premium subscription: the subscription URL the
/// backend issued, and the latest signed purchase proof (kept so a provision
/// that failed offline can be retried on a later launch).
class PremiumSub {
  static const _kUrl = 'premium_sub_url_v1';
  // The key predates Android support; the value is now a [PurchasePayload]
  // JSON blob, but a legacy iOS record is a bare JWS string that
  // [PurchasePayload.tryParse] migrates in place.
  static const _kProof = 'premium_jws_v1';
  static const _kUuid = 'premium_uuid_v1';
  static const _kToken = 'premium_sub_token_v1';
  static const _kCatalogEpoch = 'premium_catalog_epoch_v1';
  static const _kSecureUrl = 'premium_subscription_url';
  static const _kSecureProof = 'premium_purchase_proof';
  static const _kSecureIdentity = 'premium_catalog_identity';

  static Future<String?> url() => SecretPrefs.readString(
    _kSecureUrl,
    legacyPreferenceKey: _kUrl,
  );

  static Future<void> saveUrl(String url) => SecretPrefs.writeString(
    _kSecureUrl,
    url,
    legacyPreferenceKey: _kUrl,
  );

  /// The persisted purchase proof, migrating a legacy bare-JWS record.
  static Future<PurchasePayload?> proof() async {
    final raw = await SecretPrefs.readString(
      _kSecureProof,
      legacyPreferenceKey: _kProof,
    );
    return raw == null ? null : PurchasePayload.tryParse(raw);
  }

  static Future<void> saveProof(PurchasePayload payload) =>
      SecretPrefs.writeString(
        _kSecureProof,
        jsonEncode(payload.toJson()),
        legacyPreferenceKey: _kProof,
      );

  static Future<CatalogIdentity?> identity() async {
    final secure = await SecretPrefs.readString(_kSecureIdentity);
    if (secure != null) {
      try {
        final decoded = jsonDecode(secure) as Map<String, dynamic>;
        final uuid = decoded['uuid'] as String?;
        final token = decoded['token'] as String?;
        if (uuid != null && uuid.isNotEmpty && token != null && token.isNotEmpty) {
          return CatalogIdentity(uuid: uuid, subToken: token);
        }
      } catch (_) {
        return null;
      }
    }

    final prefs = await SharedPreferences.getInstance();
    final uuid = prefs.getString(_kUuid);
    final token = prefs.getString(_kToken);
    if (uuid == null || uuid.isEmpty || token == null || token.isEmpty) {
      return null;
    }
    final migrated = CatalogIdentity(uuid: uuid, subToken: token);
    final encoded = jsonEncode({'uuid': uuid, 'token': token});
    await SecretPrefs.writeString(_kSecureIdentity, encoded);
    if (await SecretPrefs.readString(_kSecureIdentity) == encoded) {
      await prefs.remove(_kUuid);
      await prefs.remove(_kToken);
    }
    return migrated;
  }

  static Future<void> saveIdentity(CatalogIdentity identity) async {
    final held = await PremiumSub.identity();
    final prefs = await SharedPreferences.getInstance();
    final changed = held?.uuid != identity.uuid || held?.subToken != identity.subToken;
    await SecretPrefs.writeString(
      _kSecureIdentity,
      jsonEncode({'uuid': identity.uuid, 'token': identity.subToken}),
    );
    await prefs.remove(_kUuid);
    await prefs.remove(_kToken);
    if (changed) await prefs.remove(_kCatalogEpoch);
  }

  static Future<int?> catalogEpoch() async =>
      (await SharedPreferences.getInstance()).getInt(_kCatalogEpoch);

  /// Only ever moves forward. Two refreshes can overlap (a purchase and a
  /// periodic one both start without awaiting each other), and both read the
  /// stored epoch before either writes; a plain write would let the slower,
  /// older one lower the floor the rollback guard rests on.
  static Future<void> saveCatalogEpoch(int epoch) async {
    final prefs = await SharedPreferences.getInstance();
    final known = prefs.getInt(_kCatalogEpoch);
    if (known != null && epoch <= known) return;
    await prefs.setInt(_kCatalogEpoch, epoch);
  }

  /// Drop the subscription URL and the catalog identity bound to it, keeping
  /// the purchase proof: after a subscription the backend has retired, that
  /// proof is the only thing a renewal can be provisioned from.
  static Future<void> forgetSubscription() async {
    await SecretPrefs.deleteString(
      _kSecureUrl,
      legacyPreferenceKey: _kUrl,
    );
    await SecretPrefs.deleteString(_kSecureIdentity);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kUuid);
    await prefs.remove(_kToken);
    await prefs.remove(_kCatalogEpoch);
  }

  static Future<void> clear() async {
    await forgetSubscription();
    await SecretPrefs.deleteString(
      _kSecureProof,
      legacyPreferenceKey: _kProof,
    );
  }
}
