import 'proxy_profile.dart';
import 'srv_naming.dart';

/// A display-friendly view over a [ProxyProfile]: "de-fra-reality-01" becomes
/// "Frankfurt, Germany" with a DE tile, while the raw name and endpoint stay
/// available for Advanced view. Derivation is best-effort and purely local.
class Location {
  final ProxyProfile profile;
  final int index; // position in AppState.profiles
  final String city;
  final String country;
  final String cc;
  final String? provider; // e.g. "@quietproxy" lifted from the raw name
  final double? lat;
  final double? lon;

  /// The city of the place, by name, when one is known: what a token in the
  /// name matched, what the lookup answered, or what the user typed. Not the
  /// label ([city] is that, for historical reasons); this is the place.
  final String? placeCity;

  /// A hideip.net location the user cannot use yet: it comes from the signed
  /// public catalog rather than from a provisioned profile, so it is shown
  /// with its real latency and a padlock. Locked locations are never part of
  /// [AppState.profiles] and can never reach the tunnel; the flag only says
  /// how the row renders and where its tap goes.
  final bool locked;

  /// This location won a voting round. The trophy stays on it until the user
  /// connects there once.
  final bool won;

  const Location({
    required this.profile,
    required this.index,
    required this.city,
    required this.country,
    required this.cc,
    this.provider,
    this.lat,
    this.lon,
    this.placeCity,
    this.locked = false,
    this.won = false,
  });

  Location copyWith({int? index, bool? locked, bool? won}) => Location(
        profile: profile,
        index: index ?? this.index,
        city: city,
        country: country,
        cc: cc,
        provider: provider,
        lat: lat,
        lon: lon,
        placeCity: placeCity,
        locked: locked ?? this.locked,
        won: won ?? this.won,
      );

  /// The place in words, `Berlin, Germany` or `Germany`, or empty when
  /// nothing placed this server.
  String get placeLabel => !placed
      ? ''
      : placeCity != null
          ? '$placeCity, $country'
          : country;

  String get rawName => profile.name;

  /// The label to show for this location: the name the user gave the
  /// server, or the parsed one. The provider's own name stays in [rawName].
  String get label => profile.customName ?? city;
  String get host => '${profile.server}:${profile.port}';

  /// Stable identity for a row across rebuilds, and what the paywall is
  /// handed so it can name the location the user tapped.
  String get id => host;
  bool get premium => profile.premium;

  /// Short protocol label, e.g. "vless · reality" or "ss · shadowtls".
  String get protoLabel {
    final o = profile.outbound;
    final parts = <String>[profile.protocol];
    final tls = o['tls'];
    if (tls is Map && tls['reality'] is Map && (tls['reality']['enabled'] == true)) {
      parts.add('reality');
    } else if (o['transport'] is Map && o['transport']['type'] == 'ws') {
      parts.add('ws+tls');
    } else if (profile.extraOutbounds
        .any((e) => e['type'] == 'shadowtls')) {
      parts.add('shadowtls');
    }
    return parts.join(' · ');
  }

  /// Builds locations for all [profiles], preserving list order.
  static List<Location> deriveAll(List<ProxyProfile> profiles) => [
        for (var i = 0; i < profiles.length; i++) derive(profiles[i], i),
      ];

  static Location derive(ProxyProfile p, int index) {
    final raw = p.name.trim();
    final lowered = raw.toLowerCase();

    // Provider handle: "tg:@handle", "| @handle" or a lone "@handle" fragment.
    String? provider;
    final at = RegExp(r'@[a-z0-9_]{3,}').firstMatch(lowered);
    if (at != null) provider = at.group(0);

    final hostPort = '${p.server}:${p.port}';
    final display = raw.isEmpty ? hostPort : raw;
    // A placeholder the parser fell back to says nothing; the place does.
    final unnamed = SrvNaming.isFallback(raw, host: p.server, port: p.port);

    // The place the user chose wins over the name and over the lookup.
    final over = p.ccOverride;
    if (validCc(over)) {
      return _placed(
        p,
        index,
        cc: over!,
        cityName: p.cityOverride,
        provider: provider,
        label: unnamed
            ? SrvNaming.suggest(
                city: p.cityOverride, country: countryName(over), host: hostPort)
            : display,
      );
    }

    // The name the importer suggested from the lookup is made of the place's
    // own words, so the token pass below would only find what the lookup
    // found, and lose the number on the way. It is read as is instead.
    final geoSuggestion = placeSuggestion(p);
    final suggested =
        geoSuggestion != null && SrvNaming.isSuggested(raw, geoSuggestion);

    if (!suggested) {
      // Tokenize on anything non-alphanumeric; also split off digits so
      // "reality01" yields "reality".
      final tokens = lowered
          .split(RegExp(r'[^a-z0-9]+'))
          .expand((t) => t.split(RegExp(r'(?<=[a-z])(?=\d)')))
          .where((t) => t.isNotEmpty)
          .toList();

      _City? city;
      for (final t in tokens) {
        city = _cities[t];
        if (city != null) break;
      }
      // Country prefix ("de-...") wins over the city's country only when no
      // city matched; otherwise the city already implies it.
      String? cc;
      for (final t in tokens) {
        if (_countries.containsKey(t)) {
          cc = t;
          break;
        }
      }

      if (city != null) {
        return Location(
          profile: p,
          index: index,
          city: city.name,
          country: _countries[city.cc] ?? city.cc.toUpperCase(),
          cc: city.cc.toUpperCase(),
          provider: provider,
          lat: city.lat,
          lon: city.lon,
          placeCity: city.name,
        );
      }
      if (cc != null) {
        final c = _countryCenters[cc];
        return Location(
          profile: p,
          index: index,
          city: _countries[cc]!,
          country: _countries[cc]!,
          cc: cc.toUpperCase(),
          provider: provider,
          lat: c?.$1,
          lon: c?.$2,
        );
      }
    }

    // A place geolocated from the server address (stored on the profile at
    // import) fills in when the name says nothing: a provider's own label
    // stays, a placeholder gives way to the place, and the country supplies
    // the flag and the map pin either way.
    final geoCc = p.cc;
    if (validCc(geoCc)) {
      return _placed(
        p,
        index,
        cc: geoCc!,
        cityName: p.city,
        provider: provider,
        label: unnamed ? geoSuggestion! : display,
      );
    }

    // Nothing recognized: show a cleaned-up raw name, no flag guess.
    return Location(
      profile: p,
      index: index,
      city: display,
      country: p.server,
      cc: unknownCc,
      provider: provider,
    );
  }

  /// A location at a known place: the user's or the lookup's. The pin lands
  /// on the city when the table knows it, on the country's centre otherwise.
  static Location _placed(
    ProxyProfile p,
    int index, {
    required String cc,
    String? cityName,
    String? provider,
    required String label,
  }) {
    final lc = cc.toLowerCase();
    final cleanCity = cityName?.trim();
    final known = cleanCity == null || cleanCity.isEmpty
        ? null
        : _cities[cleanCity.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '')];
    final pin = known != null && known.cc == lc
        ? (known.lat, known.lon)
        : _countryCenters[lc];
    return Location(
      profile: p,
      index: index,
      city: label,
      country: countryName(cc),
      cc: cc.toUpperCase(),
      provider: provider,
      lat: pin?.$1,
      lon: pin?.$2,
      placeCity: cleanCity == null || cleanCity.isEmpty ? null : cleanCity,
    );
  }

  /// The name the importer would suggest for [p] from the place it has
  /// (the user's choice first, then the lookup), or null when it has none.
  static String? placeSuggestion(ProxyProfile p) {
    final hostPort = '${p.server}:${p.port}';
    if (validCc(p.ccOverride)) {
      return SrvNaming.suggest(
          city: p.cityOverride,
          country: countryName(p.ccOverride!),
          host: hostPort);
    }
    if (validCc(p.cc)) {
      return SrvNaming.suggest(
          city: p.city, country: countryName(p.cc!), host: hostPort);
    }
    return null;
  }

  /// Whether [cc] is exactly two ASCII letters.
  static bool validCc(String? cc) =>
      cc != null && RegExp(r'^[A-Za-z]{2}$').hasMatch(cc);

  /// Names learnt from the atlas at runtime (see SrvCountries), for the
  /// codes the table below does not carry. Upper-case codes.
  static Map<String, String> _learnt = const {};

  static void learnCountryNames(Map<String, String> names) =>
      _learnt = {..._learnt, ...names};

  /// The display name for a country code: the table's, then a learnt one,
  /// then the code itself.
  static String countryName(String cc) =>
      _countries[cc.toLowerCase()] ?? _learnt[cc.toUpperCase()] ?? cc.toUpperCase();

  /// The codes the table knows names for, upper case, without the `uk`
  /// alias.
  static List<String> get tableCountryCodes => [
        for (final k in _countries.keys)
          if (k != 'uk') k.toUpperCase(),
      ];

  /// The placeholder `cc` of a server nothing could place. Its `country` is
  /// then the raw host, which is fine under a flag slot and wrong after a
  /// comma.
  static const String unknownCc = '··';

  /// Whether a real country stands behind [country] and [cc].
  bool get placed => cc != unknownCc;
}

class _City {
  final String name;
  final String cc;
  final double lat;
  final double lon;
  const _City(this.name, this.cc, this.lat, this.lon);
}

/// City tokens commonly seen in provider server names (IATA codes, short
/// names, full names). Lowercase keys.
const _cities = <String, _City>{
  'fra': _City('Frankfurt', 'de', 50.1, 8.7),
  'frankfurt': _City('Frankfurt', 'de', 50.1, 8.7),
  'ber': _City('Berlin', 'de', 52.5, 13.4),
  'berlin': _City('Berlin', 'de', 52.5, 13.4),
  'vie': _City('Vienna', 'at', 48.2, 16.4),
  'vienna': _City('Vienna', 'at', 48.2, 16.4),
  'ams': _City('Amsterdam', 'nl', 52.4, 4.9),
  'amsterdam': _City('Amsterdam', 'nl', 52.4, 4.9),
  'zur': _City('Zurich', 'ch', 47.4, 8.5),
  'zrh': _City('Zurich', 'ch', 47.4, 8.5),
  'zurich': _City('Zurich', 'ch', 47.4, 8.5),
  'lon': _City('London', 'gb', 51.5, -.1),
  'london': _City('London', 'gb', 51.5, -.1),
  'par': _City('Paris', 'fr', 48.9, 2.4),
  'paris': _City('Paris', 'fr', 48.9, 2.4),
  'mad': _City('Madrid', 'es', 40.4, -3.7),
  'madrid': _City('Madrid', 'es', 40.4, -3.7),
  'mil': _City('Milan', 'it', 45.5, 9.2),
  'milan': _City('Milan', 'it', 45.5, 9.2),
  'sto': _City('Stockholm', 'se', 59.3, 18.1),
  'stockholm': _City('Stockholm', 'se', 59.3, 18.1),
  'hel': _City('Helsinki', 'fi', 60.2, 24.9),
  'helsinki': _City('Helsinki', 'fi', 60.2, 24.9),
  'osl': _City('Oslo', 'no', 59.9, 10.8),
  'oslo': _City('Oslo', 'no', 59.9, 10.8),
  'waw': _City('Warsaw', 'pl', 52.2, 21.0),
  'warsaw': _City('Warsaw', 'pl', 52.2, 21.0),
  'prg': _City('Prague', 'cz', 50.1, 14.4),
  'prague': _City('Prague', 'cz', 50.1, 14.4),
  'bud': _City('Budapest', 'hu', 47.5, 19.0),
  'budapest': _City('Budapest', 'hu', 47.5, 19.0),
  'beg': _City('Belgrade', 'rs', 44.8, 20.5),
  'belgrade': _City('Belgrade', 'rs', 44.8, 20.5),
  'ist': _City('Istanbul', 'tr', 41.0, 28.9),
  'istanbul': _City('Istanbul', 'tr', 41.0, 28.9),
  'kiv': _City('Kyiv', 'ua', 50.5, 30.5),
  'kyiv': _City('Kyiv', 'ua', 50.5, 30.5),
  'mow': _City('Moscow', 'ru', 55.8, 37.6),
  'moscow': _City('Moscow', 'ru', 55.8, 37.6),
  'nyc': _City('New York', 'us', 40.7, -74.0),
  'newyork': _City('New York', 'us', 40.7, -74.0),
  'lax': _City('Los Angeles', 'us', 34.1, -118.2),
  'mia': _City('Miami', 'us', 25.8, -80.2),
  'chi': _City('Chicago', 'us', 41.9, -87.6),
  'dal': _City('Dallas', 'us', 32.8, -96.8),
  'sea': _City('Seattle', 'us', 47.6, -122.3),
  'sjc': _City('San Jose', 'us', 37.3, -121.9),
  'tor': _City('Toronto', 'ca', 43.7, -79.4),
  'toronto': _City('Toronto', 'ca', 43.7, -79.4),
  'sao': _City('São Paulo', 'br', -23.6, -46.6),
  'saopaulo': _City('São Paulo', 'br', -23.6, -46.6),
  'tyo': _City('Tokyo', 'jp', 35.7, 139.7),
  'tokyo': _City('Tokyo', 'jp', 35.7, 139.7),
  'osa': _City('Osaka', 'jp', 34.7, 135.5),
  'sel': _City('Seoul', 'kr', 37.6, 127.0),
  'seoul': _City('Seoul', 'kr', 37.6, 127.0),
  'hkg': _City('Hong Kong', 'hk', 22.3, 114.2),
  'hongkong': _City('Hong Kong', 'hk', 22.3, 114.2),
  'sin': _City('Singapore', 'sg', 1.4, 103.8),
  'sgp': _City('Singapore', 'sg', 1.4, 103.8),
  'singapore': _City('Singapore', 'sg', 1.4, 103.8),
  'tpe': _City('Taipei', 'tw', 25.0, 121.6),
  'taipei': _City('Taipei', 'tw', 25.0, 121.6),
  'bom': _City('Mumbai', 'in', 19.1, 72.9),
  'mumbai': _City('Mumbai', 'in', 19.1, 72.9),
  'dxb': _City('Dubai', 'ae', 25.2, 55.3),
  'dubai': _City('Dubai', 'ae', 25.2, 55.3),
  'syd': _City('Sydney', 'au', -33.9, 151.2),
  'sydney': _City('Sydney', 'au', -33.9, 151.2),
  'jnb': _City('Johannesburg', 'za', -26.2, 28.0),
};

/// ISO 3166-1 alpha-2 → country display name, for tokens like "de-".
const _countries = <String, String>{
  'de': 'Germany', 'at': 'Austria', 'nl': 'Netherlands', 'ch': 'Switzerland',
  'gb': 'United Kingdom', 'uk': 'United Kingdom', 'fr': 'France',
  'es': 'Spain', 'it': 'Italy', 'se': 'Sweden', 'fi': 'Finland',
  'no': 'Norway', 'pl': 'Poland', 'cz': 'Czechia', 'hu': 'Hungary',
  'rs': 'Serbia', 'tr': 'Türkiye', 'ua': 'Ukraine', 'ru': 'Russia',
  'us': 'United States', 'ca': 'Canada', 'br': 'Brazil', 'jp': 'Japan',
  'kr': 'South Korea', 'hk': 'Hong Kong', 'sg': 'Singapore', 'tw': 'Taiwan',
  'in': 'India', 'ae': 'UAE', 'au': 'Australia', 'za': 'South Africa',
};

/// Rough country centroids for the dot map when only a country matched.
const _countryCenters = <String, (double, double)>{
  'de': (51.0, 10.0), 'at': (47.6, 14.1), 'nl': (52.2, 5.3), 'ch': (46.8, 8.2),
  'gb': (54.0, -2.0), 'uk': (54.0, -2.0), 'fr': (46.6, 2.4), 'es': (40.0, -3.7),
  'it': (42.8, 12.8), 'se': (62.0, 15.0), 'fi': (64.0, 26.0), 'no': (61.0, 9.0),
  'pl': (52.0, 19.0), 'cz': (49.8, 15.5), 'hu': (47.2, 19.5), 'rs': (44.0, 21.0),
  'tr': (39.0, 35.0), 'ua': (49.0, 32.0), 'ru': (56.0, 38.0), 'us': (39.8, -98.6),
  'ca': (56.1, -106.3), 'br': (-14.2, -51.9), 'jp': (36.2, 138.3),
  'kr': (36.5, 127.9), 'hk': (22.3, 114.2), 'sg': (1.4, 103.8),
  'tw': (23.7, 121.0), 'in': (20.6, 79.0), 'ae': (24.0, 54.0),
  'au': (-25.3, 133.8), 'za': (-29.0, 24.0),
};
