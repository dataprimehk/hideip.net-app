import 'package:http/http.dart' as http;

import 'app_version.dart';
import 'proxy_profile.dart';
import 'safe_http.dart';
import 'sub_info.dart';
import 'subscription.dart';
import 'subscription_identity.dart';

/// Refreshing user-imported (BYOC) subscriptions. A user pastes a provider's
/// subscription URL once; the provider rotates its servers behind that URL, so
/// the app re-pulls each distinct URL on launch and swaps in the fresh server
/// list. Unlike the premium subscription there can be several of these, so the
/// origin URL lives on each [ProxyProfile.subUrl] rather than in one shared
/// key; refresh groups profiles by that URL.
class UserSubscriptionService {
  final SafeHttpFetcher _fetcher;
  UserSubscriptionService({http.Client? client})
      : _fetcher = client == null
            ? SafeHttpFetcher()
            : SafeHttpFetcher.forTesting(client);

  /// A failed refresh never authorizes removing locally saved servers.
  /// Import uses [read] for typed, user-visible failure reasons; background
  /// refresh can use [fetch] and keep the existing profiles on null.
  Future<SubFetch?> fetch(String url) async {
    try {
      return await read(url);
    } catch (_) {
      return null;
    }
  }

  Future<SubFetch> read(String url) async {
    final uri = Uri.parse(url);
    final resp = await _fetcher.get(uri, headers: {
      ...subscriptionHeaders,
      if (!isHideipHost(uri.host)) 'x-hwid': await SubscriptionIdentity.forUrl(url),
    });
    final headers = {for (final e in resp.headers.entries) e.key.toLowerCase(): e.value};
    bool flagged(String key) => const ['true', '1'].contains(headers[key]?.toLowerCase());
    if (flagged('x-hwid-max-devices-reached')) {
      throw const SubscriptionFetchException(SubscriptionFailure.deviceLimit);
    }
    if (flagged('x-hwid-not-supported')) {
      throw const SubscriptionFetchException(SubscriptionFailure.hwidRequired);
    }
    if (resp.statusCode == 403 && resp.body.toLowerCase().contains('device limit reached')) {
      throw const SubscriptionFetchException(SubscriptionFailure.deviceLimit);
    }
    if ((resp.statusCode == 403 || resp.statusCode == 404) &&
        resp.body.toLowerCase().contains('hwid')) {
      final limited = RegExp(r'limit|max.*device|too many').hasMatch(resp.body.toLowerCase());
      throw SubscriptionFetchException(limited ? SubscriptionFailure.deviceLimit : SubscriptionFailure.hwidRequired);
    }
    if (resp.statusCode != 200) {
      throw SubscriptionFetchException(SubscriptionFailure.http, statusCode: resp.statusCode);
    }
    if (resp.body.trim().isEmpty) {
      throw const SubscriptionFetchException(SubscriptionFailure.empty);
    }
    final parsed = await Subscription.parseAsync(resp.body);
    if (parsed.profiles.isEmpty) {
      throw SubscriptionFetchException(
        parsed.placeholders > 0 ? SubscriptionFailure.placeholder : SubscriptionFailure.noSupportedProfiles,
        parsed: parsed,
      );
    }
    return SubFetch(
      profiles: parsed.profiles.map((p) => p.copyWith(subUrl: url)).toList(),
      info: SubInfo.fromHeaders(resp.headers, fetchedAt: DateTime.now()),
      parsed: parsed,
    );
  }

}

/// The outcome of a subscription fetch: the fresh server list plus the plan
/// metadata parsed from the response headers (null when the provider sent
/// none). Kept together so a single fetch surfaces both to the caller.
class SubFetch {
  final List<ProxyProfile> profiles;
  final SubInfo? info;
  final SubscriptionResult? parsed;
  const SubFetch({required this.profiles, required this.info, this.parsed});
}

/// The distinct user-subscription URLs present in [profiles], in first-seen
/// order. Premium profiles are excluded (they refresh through their own path).
List<String> userSubUrls(List<ProxyProfile> profiles) {
  final seen = <String>{};
  final urls = <String>[];
  for (final p in profiles) {
    final u = p.subUrl;
    if (u != null && !p.premium && seen.add(u)) urls.add(u);
  }
  return urls;
}

/// Whether [p] came from the user subscription at [url].
bool isFromUserSub(ProxyProfile p, String url) =>
    !p.premium && p.subUrl == url;

/// Replace the profiles that came from [url] with [fresh], leaving every other
/// profile (other subscriptions, single-link imports, premium) untouched and
/// in place.
List<ProxyProfile> mergeUserSubProfiles(
    List<ProxyProfile> current, String url, List<ProxyProfile> fresh) {
  final out = <ProxyProfile>[];
  var inserted = false;
  for (final p in current) {
    if (isFromUserSub(p, url)) {
      // Drop the stale ones; drop the fresh set in where the first old one was.
      if (!inserted) {
        out.addAll(fresh);
        inserted = true;
      }
    } else {
      out.add(p);
    }
  }
  if (!inserted) out.addAll(fresh); // url had no current profiles (shouldn't happen)
  return out;
}

enum SubscriptionFailure { deviceLimit, hwidRequired, http, empty, placeholder, noSupportedProfiles }

class SubscriptionFetchException implements Exception {
  final SubscriptionFailure reason;
  final int? statusCode;
  final SubscriptionResult? parsed;
  const SubscriptionFetchException(this.reason, {this.statusCode, this.parsed});
}
