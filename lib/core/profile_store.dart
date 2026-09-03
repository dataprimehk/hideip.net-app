import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'proxy_profile.dart';
import 'secret_prefs.dart';

/// Persists the user's list of [ProxyProfile]s and which one is selected,
/// in shared_preferences as JSON. Profiles have no stable server-assigned id,
/// so the selection is stored as an index into the saved list.
class ProfileStore {
  static const _kProfiles = 'profiles_v1';
  static const _kSecureProfiles = 'profiles';
  static const _kSelected = 'selected_index_v1';

  /// Load saved profiles. Corrupt or unparsable entries are skipped.
  static Future<List<ProxyProfile>> load() async {
    final raw = await SecretPrefs.readString(
      _kSecureProfiles,
      legacyPreferenceKey: _kProfiles,
    );
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .whereType<Map<String, dynamic>>()
          .map(_fromMap)
          .toList(growable: true);
    } catch (_) {
      return [];
    }
  }

  /// Overwrite the saved profile list.
  static Future<void> save(List<ProxyProfile> profiles) async {
    final encoded = jsonEncode(profiles.map(_toMap).toList());
    await SecretPrefs.writeString(
      _kSecureProfiles,
      encoded,
      legacyPreferenceKey: _kProfiles,
    );
  }

  static Future<int> loadSelectedIndex() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_kSelected) ?? -1;
  }

  static Future<void> saveSelectedIndex(int index) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kSelected, index);
  }

  static Map<String, dynamic> _toMap(ProxyProfile p) => {
        'name': p.name,
        'protocol': p.protocol,
        'server': p.server,
        'port': p.port,
        'outbound': p.outbound,
        if (p.extraOutbounds.isNotEmpty) 'extraOutbounds': p.extraOutbounds,
        if (p.cc != null) 'cc': p.cc,
        if (p.premium) 'premium': true,
        if (p.subUrl != null) 'subUrl': p.subUrl,
        if (p.customName != null) 'customName': p.customName,
        ...p.storedExtras,
      };

  static ProxyProfile _fromMap(Map<String, dynamic> m) => ProxyProfile(
        name: m['name'] as String? ?? '',
        protocol: m['protocol'] as String? ?? '',
        server: m['server'] as String? ?? '',
        port: m['port'] as int? ?? 0,
        outbound: (m['outbound'] as Map).cast<String, dynamic>(),
        extraOutbounds: (m['extraOutbounds'] as List?)
                ?.whereType<Map>()
                .map((e) => e.cast<String, dynamic>())
                .toList() ??
            const [],
        cc: m['cc'] as String?,
        // Lists saved before the flag existed marked managed profiles only by
        // the backend's old "hideip.net " name prefix; migrate them here.
        premium: m['premium'] == true ||
            (m['name'] as String? ?? '').startsWith('hideip.net '),
        subUrl: m['subUrl'] as String?,
        customName: m['customName'] as String?,
      ).withStoredExtras(m);
}
