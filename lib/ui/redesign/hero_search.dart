import '../../core/location.dart';

/// What the search field on Home can find a location by, and the rule it
/// finds it with.
///
/// People type whatever they have in their head about a server: the name
/// they gave it, the city, "vless", "wireguard", "reality", a piece of the
/// host, the provider's handle. All of it counts, so a search never comes
/// back empty for a server the user can plainly see in the list.
class HeroSearch {
  HeroSearch._();

  /// Short forms people type for a protocol, appended beside the long name
  /// so "wg" finds WireGuard the way "wireguard" does.
  static const _aliases = <String, String>{
    'wireguard': 'wg',
    'shadowsocks': 'ss',
    'hysteria2': 'hy2 hysteria',
  };

  /// Everything one location can be found by: lower case, space separated.
  static String textOf(Location l) {
    final p = l.profile;
    final parts = <String?>[
      p.customName,
      l.label,
      l.city,
      l.country,
      l.cc,
      l.protoLabel,
      p.protocol,
      p.server,
      l.provider,
      l.rawName,
    ];
    final words = <String>[
      for (final s in parts)
        if (s != null && s.isNotEmpty) s.toLowerCase(),
    ];
    for (final alias in _aliases.entries) {
      if (words.any((w) => w.contains(alias.key))) words.add(alias.value);
    }
    return words.join(' ');
  }

  /// Whether [query] finds [l]. Case does not matter, any substring counts,
  /// and every word of a multi-word query has to be found somewhere.
  static bool matches(Location l, String query) {
    final words = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return true;
    final text = textOf(l);
    return words.every(text.contains);
  }

  /// The result list for [query]: the open servers that match, in their
  /// order, then the locked ones in theirs.
  static List<Location> filter(
    Iterable<Location> open,
    Iterable<Location> locked,
    String query,
  ) =>
      [
        ...open.where((l) => matches(l, query)),
        ...locked.where((l) => matches(l, query)),
      ];
}
