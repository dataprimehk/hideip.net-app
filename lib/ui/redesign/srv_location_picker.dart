import 'package:flutter/material.dart';

import '../../core/srv_countries.dart';
import '../strings.dart';
import 'hip.dart';
import 'hip_sheet.dart';

/// What the location picker answers with: a country (and maybe a city) the
/// user chose, or, with [cc] null, the wish to go back to the detected place.
class SrvPlace {
  final String? cc;
  final String? city;
  const SrvPlace(this.cc, this.city);

  /// Back to whatever the lookup found.
  static const detected = SrvPlace(null, null);
}

/// Asks where a server is. Returns null when the sheet was dismissed.
Future<SrvPlace?> showSrvLocationPicker(
  BuildContext context, {
  String? cc,
  String? city,
  required bool overridden,
}) {
  return showHipSheet<SrvPlace>(
    context,
    children: [
      SrvLocationPicker(
        cc: cc,
        city: city,
        overridden: overridden,
        onDone: (place) => Navigator.of(context).pop(place),
        onCancel: () => Navigator.of(context).pop(),
      ),
    ],
  );
}

/// The picker's body: a searchable country list and a city field. Held
/// apart from the sheet so it can be exercised on its own.
class SrvLocationPicker extends StatefulWidget {
  final String? cc;
  final String? city;

  /// Whether the server already carries a place of the user's own, which is
  /// what offers the way back to the detected one.
  final bool overridden;
  final ValueChanged<SrvPlace> onDone;
  final VoidCallback onCancel;

  /// Where the list comes from; the atlas by default, a fixed list in tests.
  final Future<List<SrvCountry>> Function() loadCountries;

  const SrvLocationPicker({
    super.key,
    this.cc,
    this.city,
    required this.overridden,
    required this.onDone,
    required this.onCancel,
    this.loadCountries = SrvCountries.load,
  });

  @override
  State<SrvLocationPicker> createState() => _SrvLocationPickerState();
}

class _SrvLocationPickerState extends State<SrvLocationPicker> {
  final _search = TextEditingController();
  late final TextEditingController _city = TextEditingController(
    text: widget.city ?? '',
  );
  List<SrvCountry> _countries = const [];
  String? _cc;

  @override
  void initState() {
    super.initState();
    _cc = widget.cc?.toUpperCase();
    _search.addListener(() => setState(() {}));
    widget.loadCountries().then((list) {
      if (mounted) setState(() => _countries = list);
    });
  }

  @override
  void dispose() {
    _search.dispose();
    _city.dispose();
    super.dispose();
  }

  List<SrvCountry> get _shown {
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return _countries;
    return [
      for (final c in _countries)
        if (c.name.toLowerCase().contains(q) || c.cc.toLowerCase() == q) c,
    ];
  }

  void _save() {
    final cc = _cc;
    if (cc == null) return;
    final city = _city.text.trim();
    widget.onDone(SrvPlace(cc, city.isEmpty ? null : city));
  }

  InputDecoration _field(String hint) => InputDecoration(
    isDense: true,
    hintText: hint,
    hintStyle: Hip.sans(400, 14, color: Hip.muted2),
    contentPadding: const EdgeInsets.only(top: 6, bottom: 7),
    border: UnderlineInputBorder(
      borderSide: BorderSide(color: Hip.line, width: 1.5),
    ),
    enabledBorder: UnderlineInputBorder(
      borderSide: BorderSide(color: Hip.line, width: 1.5),
    ),
    focusedBorder: UnderlineInputBorder(
      borderSide: BorderSide(color: Hip.blue, width: 1.5),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    // The sheet rides above the keyboard while a field has it.
    return AnimatedPadding(
      duration: Hip.dur(const Duration(milliseconds: 200)),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const HipSheetTitle(S.srvLocationTitle),
          const HipSheetBody(S.srvLocationBody),
          const SizedBox(height: 14),
          TextField(
            controller: _search,
            autocorrect: false,
            style: Hip.sans(550, 15, color: Hip.ink),
            decoration: _field(S.srvCountrySearch),
          ),
          SizedBox(
            height: 220,
            child: _countries.isEmpty
                ? Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Hip.muted2,
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: shown.length,
                    itemBuilder: (context, i) {
                      final c = shown[i];
                      final chosen = c.cc == _cc;
                      return InkWell(
                        onTap: () => setState(() => _cc = c.cc),
                        borderRadius: BorderRadius.circular(10),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 7,
                          ),
                          child: Row(
                            children: [
                              HipFlag(cc: c.cc, small: true),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  c.name,
                                  overflow: TextOverflow.ellipsis,
                                  style: Hip.sans(
                                    chosen ? 650 : 500,
                                    15,
                                    color: Hip.ink,
                                  ),
                                ),
                              ),
                              if (chosen)
                                Icon(Icons.check, size: 18, color: Hip.blue),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _city,
            autocorrect: false,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _save(),
            style: Hip.sans(550, 15, color: Hip.ink),
            decoration: _field(S.srvCityHint),
          ),
          HipSheetActions(
            children: [
              HipCta(S.gSave, onTap: _cc == null ? null : _save),
              if (widget.overridden)
                HipCta(
                  S.srvUseDetected,
                  ghost: true,
                  onTap: () => widget.onDone(SrvPlace.detected),
                ),
              HipCta(S.aCancel, quiet: true, onTap: widget.onCancel),
            ],
          ),
        ],
      ),
    );
  }
}
