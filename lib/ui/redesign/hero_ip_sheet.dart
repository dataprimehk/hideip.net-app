import 'package:flutter/material.dart';

import '../../core/ip_lookup.dart';
import '../strings.dart';
import 'hip.dart';
import 'hip_sheet.dart';

/// What the address sheet has to say. Every field but the address itself is
/// optional: a row the lookup could not fill is left out, never dashed.
class HeroIpDetails {
  final String ip;
  final String? city;
  final String? country;
  final String? cc;
  final String? isp;

  const HeroIpDetails({
    required this.ip,
    this.city,
    this.country,
    this.cc,
    this.isp,
  });

  /// The lookup answers "you" for a city it does not know, because the map
  /// pin still needs a word. On a sheet that is no city at all.
  static String? _city(String? c) =>
      c == null || c.isEmpty || c == 'you' ? null : c;

  /// These details with the lookup's answer laid over them: what it knows
  /// wins, what it does not know keeps what was there.
  HeroIpDetails withGeo(IpGeo geo) => HeroIpDetails(
        ip: ip,
        city: _city(geo.city) ?? city,
        country: geo.country ?? country,
        cc: geo.cc ?? cc,
        isp: geo.isp ?? isp,
      );

  factory HeroIpDetails.fromGeo(String ip, IpGeo? geo) {
    final bare = HeroIpDetails(ip: ip);
    return geo == null ? bare : bare.withGeo(geo);
  }
}

/// The sheet a long press on the address row opens: the address, the city,
/// the country and the network behind it, as far as the lookup knows them,
/// and one Copy button. Codes and the address are in mono; names are not.
class HeroIpSheet extends StatefulWidget {
  final HeroIpDetails initial;
  final ValueChanged<String> onCopy;

  const HeroIpSheet({
    super.key,
    required this.initial,
    required this.onCopy,
  });

  /// Where the sheet asks for the rest of the picture. The app answers with
  /// the lookup, which serves the cached answer when the address was checked
  /// in the last ten seconds and otherwise asks hideip.net's own endpoint,
  /// the one the address itself came from. Tests hand back a fixed answer.
  static Future<IpGeo?> Function() lookup = IpLookup.locate;

  @override
  State<HeroIpSheet> createState() => _HeroIpSheetState();
}

class _HeroIpSheetState extends State<HeroIpSheet> {
  late HeroIpDetails _d = widget.initial;

  @override
  void initState() {
    super.initState();
    HeroIpSheet.lookup().then((geo) {
      if (geo != null && mounted) setState(() => _d = _d.withGeo(geo));
    }, onError: (Object _) {
      // The sheet already shows what it had; a failed refinement adds nothing.
    });
  }

  Widget _kv(String label, Widget value) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(children: [
          Text(label, style: Hip.sans(400, Hip.bodySize, color: Hip.muted)),
          const SizedBox(width: 16),
          Expanded(
            child: Align(alignment: Alignment.centerRight, child: value),
          ),
        ]),
      );

  Widget _name(String text) => Text(
        text,
        textAlign: TextAlign.end,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: Hip.sans(600, Hip.bodySize, color: Hip.ink),
      );

  Widget _code(String text) => Text(
        text,
        textAlign: TextAlign.end,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Hip.mono(600, Hip.bodySize, color: Hip.ink),
      );

  /// The country row: the name, then the code beside it in mono; the code
  /// alone when that is all the lookup had.
  Widget _country(String? country, String? cc) {
    if (country == null) return _code(cc!);
    if (cc == null) return _name(country);
    return Text.rich(
      TextSpan(children: [
        TextSpan(
            text: country,
            style: Hip.sans(600, Hip.bodySize, color: Hip.ink)),
        const TextSpan(text: '  '),
        TextSpan(
            text: cc,
            style: Hip.mono(600, Hip.bodySize, color: Hip.muted)),
      ]),
      textAlign: TextAlign.end,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const HipSheetTitle(S.heroIpTitle),
        const SizedBox(height: 14),
        HipListGroup(children: [
          _kv(S.heroIpAddress, _code(d.ip)),
          if (d.city != null) _kv(S.heroIpCity, _name(d.city!)),
          if (d.country != null || d.cc != null)
            _kv(S.heroIpCountry, _country(d.country, d.cc)),
          if (d.isp != null) _kv(S.heroIpNetwork, _name(d.isp!)),
        ]),
        HipSheetActions(children: [
          HipCta(S.homeCopyIp, onTap: () {
            widget.onCopy(d.ip);
            Navigator.of(context).pop();
          }),
        ]),
      ],
    );
  }
}
