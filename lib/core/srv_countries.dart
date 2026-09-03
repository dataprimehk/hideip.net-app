import 'cc_iso.dart';
import 'country_names.dart';
import 'location.dart';

/// One country the location picker offers.
class SrvCountry {
  final String cc;
  final String name;
  const SrvCountry(this.cc, this.name);
}

/// The countries a server can be placed in by hand: every code the app
/// already knows, named from the same atlas the map is drawn from, sorted by
/// name. Loading also teaches [Location] the names the parser's own table
/// lacks, so a placed server reads the same in the picker and on its row.
class SrvCountries {
  SrvCountries._();

  static List<SrvCountry>? _cache;

  static Future<List<SrvCountry>> load() async {
    final cached = _cache;
    if (cached != null) return cached;
    final atlas = await CountryNames.load();
    final learnt = <String, String>{};
    for (final e in ccIso.entries) {
      final name = atlas[e.value];
      if (name != null) learnt[e.key] = name;
    }
    Location.learnCountryNames(learnt);
    final codes = {...learnt.keys, ...Location.tableCountryCodes};
    final out = [
      for (final cc in codes) SrvCountry(cc, Location.countryName(cc)),
    ]..sort((a, b) => a.name.compareTo(b.name));
    return _cache = out;
  }
}
