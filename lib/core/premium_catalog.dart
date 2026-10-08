import 'catalog.dart';
import 'location.dart';
import 'provisioning.dart' show catalogSourceUrls;
import 'proxy_profile.dart';

/// The hideip.net locations shown to someone who has no subscription.
///
/// Where they come from: `CatalogClient.fetch()` needs no identity at all. The
/// catalog is a signed public document, so the app can read the real fleet,
/// with real hostnames, and measure the real latency to each one, without a
/// purchase and without asking the backend anything about who is asking.
///
/// What it deliberately does not do: produce anything connectable. The
/// profiles built here carry no credential, and they are kept out of
/// [AppState.profiles] entirely. They exist as [Location]s with `locked: true`
/// so a row can show a city, a flag, real bars and a padlock. The tunnel picks
/// its profile from the profile list, never from this one, so there is no path
/// from a locked row to a connect attempt.
class PremiumCatalog {
  PremiumCatalog._();

  /// Reads the signed catalog and turns it into locked locations, best-first
  /// by the backend's own sort weight. Returns an empty list on any failure:
  /// an unreachable mirror hides the upsell, it never breaks the screen.
  static Future<List<Location>> fetchLocked({CatalogClient? client}) async =>
      (await fetchSplit(client: client)).locked;

  /// The locked premium rows and the free location's rows, from one read of
  /// the catalog. Both empty on any failure.
  static Future<({List<Location> locked, List<Location> free})> fetchSplit({
    CatalogClient? client,
  }) async {
    final catalog = await (client ??
            CatalogClient(
              sources: catalogSourceUrls.map(Uri.parse).toList(growable: false),
              publicKey: catalogVerificationPublicKey,
            ))
        .fetch();
    if (catalog == null) return (locked: const <Location>[], free: const <Location>[]);
    return (
      locked: lockedLocationsFrom(catalog),
      free: freeLocationsFrom(catalog),
    );
  }

  /// The pure half, so the mapping can be tested without a network. Free
  /// servers are left out: they are not a premium row behind a padlock.
  static List<Location> lockedLocationsFrom(CatalogDocument catalog) =>
      _locationsFrom(catalog, free: false);

  /// The free location's servers, as rows to show before the free key is
  /// asked for. Like the locked rows they carry no credential and never
  /// reach the tunnel; tapping one is what asks for the key.
  static List<Location> freeLocationsFrom(CatalogDocument catalog) =>
      _locationsFrom(catalog, free: true);

  static List<Location> _locationsFrom(
    CatalogDocument catalog, {
    required bool free,
  }) {
    final servers = [...catalog.servers]..sort((a, b) {
        final weight = a.sortWeight.compareTo(b.sortWeight);
        return weight == 0 ? a.id.compareTo(b.id) : weight;
      });
    final out = <Location>[];
    final seen = <String>{};
    for (final server in servers) {
      if (server.free != free) continue;
      if (server.host.isEmpty || server.endpoints.isEmpty) continue;
      if (!seen.add(server.host)) continue;
      final endpoint = server.endpoints.first;
      final profile = ProxyProfile(
        name: server.label.isEmpty ? server.id : server.label,
        // The protocol name is what the row prints in Advanced view; the
        // outbound stays empty because this profile must never build a config.
        protocol: endpoint.protocol.split('-').first,
        server: server.host,
        port: endpoint.port,
        outbound: const {},
        premium: !free,
        free: free,
      );
      out.add(
        Location.derive(profile, out.length).copyWith(locked: !free),
      );
    }
    return out;
  }
}
