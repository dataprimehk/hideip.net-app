/// Names for imported servers that arrive without one.
///
/// A bare-IP link or a WireGuard file with no comment gives the importer
/// nothing to call the server, so the name is suggested from where the
/// address sits: `Berlin, Germany`, or `Germany` when only the country is
/// known, or the host as the last resort. Two servers in the same place would
/// otherwise share a name, so a suggestion that collides with a label already
/// on the list gets ` #2`, ` #3` and so on. The number is decided once, at
/// import, and then stays on the profile like any other name; names the user
/// typed are never numbered.
class SrvNaming {
  SrvNaming._();

  /// The plain suggestion, before numbering.
  static String suggest({String? city, String? country, required String host}) {
    final c = _clean(city);
    final k = _clean(country);
    if (c != null && k != null) return '$c, $k';
    if (k != null) return k;
    if (c != null) return c;
    return host;
  }

  /// [base] with the lowest free number appended when [taken] already holds
  /// it: the first duplicate becomes ` #2`. A gap left by a removed server is
  /// filled before a higher number is used, so the list never counts past
  /// what is actually on it.
  static String numbered(String base, Iterable<String> taken) {
    final used = <int>{};
    for (final label in taken) {
      final n = numberOf(label, base);
      if (n != null) used.add(n);
    }
    if (!used.contains(1)) return base;
    var n = 2;
    while (used.contains(n)) {
      n++;
    }
    return '$base #$n';
  }

  /// Which number [label] carries for [base]: 1 for the bare base, n for
  /// `base #n`, null when the label is not a numbered form of the base.
  static int? numberOf(String label, String base) {
    if (label == base) return 1;
    final m = RegExp('^${RegExp.escape(base)} #([0-9]+)\$').firstMatch(label);
    if (m == null) return null;
    final n = int.tryParse(m.group(1)!);
    return n == null || n < 2 ? null : n;
  }

  /// Whether [name] is [base] or a numbered form of it, which is how a
  /// profile tells its own suggested name apart from one a provider sent.
  static bool isSuggested(String name, String base) =>
      numberOf(name, base) != null;

  /// Whether [name] is one of the placeholders the parsers fall back to when
  /// a link or a file carries no name of its own.
  static bool isFallback(
    String name, {
    required String host,
    required int port,
  }) {
    final n = name.trim();
    return n.isEmpty || n == '$host:$port' || n == 'WireGuard $host';
  }

  static String? _clean(String? s) {
    final t = s?.trim();
    return t == null || t.isEmpty ? null : t;
  }
}
