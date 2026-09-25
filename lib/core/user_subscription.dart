import 'package:http/http.dart' as http;

import 'app_version.dart';
import 'proxy_profile.dart';
import 'safe_http.dart';
import 'sub_info.dart';
import 'subscription.dart';

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

  /// Fetch and parse one subscription URL. Null on any transient failure so
  /// the caller keeps the servers it already has (a flaky network must not
  /// strand a working import); a result with an empty profile list only on a
  /// definitive "gone" (404/410: the provider retired the link). Fresh
  /// profiles are tagged with [url] so they stay grouped under their origin,
  /// and any plan headers the provider sent ride along as [SubFetch.info].
  Future<SubFetch?> fetch(String url) async {
    try {
      final resp = await _fetcher.get(
        Uri.parse(url),
        headers: subscriptionHeaders,
      );
      if (resp.statusCode == 404 || resp.statusCode == 410) {
        return const SubFetch(profiles: [], info: null);
      }
      if (resp.statusCode != 200) return null;
      final profiles = (await Subscription.parseAsync(resp.body)).profiles
          .map((p) => p.copyWith(subUrl: url))
          .toList();
      if (profiles.isEmpty) return null;
      final info =
          SubInfo.fromHeaders(resp.headers, fetchedAt: DateTime.now());
      return SubFetch(profiles: profiles, info: info);
    } catch (_) {
      return null;
    }
  }
}

/// The outcome of a subscription fetch: the fresh server list plus the plan
/// metadata parsed from the response headers (null when the provider sent
/// none). Kept together so a single fetch surfaces both to the caller.
class SubFetch {
  final List<ProxyProfile> profiles;
  final SubInfo? info;
  const SubFetch({required this.profiles, required this.info});
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
