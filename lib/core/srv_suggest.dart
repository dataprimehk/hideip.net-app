import 'ip_lookup.dart';
import 'location.dart';
import 'proxy_profile.dart';
import 'srv_naming.dart';

/// Names a freshly parsed profile from where its address is, when the link
/// or file gave it no name of its own.
///
/// The lookup's answer is stored on the profile either way (the flag and
/// the pin want it). The name changes only for a placeholder (`host:port`,
/// `WireGuard host`): it becomes `City, Country` or `Country`, numbered
/// against [taken] (the labels already on the list) so two servers in the
/// same place read apart. A name the provider or the user gave is never
/// touched and never numbered. With no answer the placeholder stays, and
/// the host is what the row reads.
ProxyProfile srvNameFromPlace(
  ProxyProfile p, {
  required IpLookupData? geo,
  required Iterable<String> taken,
}) {
  final cc = geo?.cc;
  if (cc == null || !Location.validCc(cc)) return p;
  final placed = p.copyWith(cc: cc, city: geo!.city);
  if (!SrvNaming.isFallback(p.name, host: p.server, port: p.port))
    return placed;
  final base = SrvNaming.suggest(
    city: geo.city,
    country: geo.country ?? Location.countryName(cc),
    host: p.server,
  );
  return placed.copyWith(name: SrvNaming.numbered(base, taken));
}
