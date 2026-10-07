import 'dart:convert';
import 'dart:math';

import 'async_gate.dart';
import 'secret_prefs.dart';

/// Subscription-scoped random identifier, never a hardware identifier.
/// The encrypted value lives in app preferences (not a persistent Keychain
/// identity), so uninstalling removes it even when iOS retains encryption keys.
class SubscriptionIdentity {
  static const _key = 'user_subscription_ids';
  static final _gate = AsyncGate();

  static String canonical(String url) =>
      Uri.parse(url).removeFragment().toString();

  static Future<Map<String, String>> _load() async {
    final raw = await SecretPrefs.readString(_key);
    if (raw == null) return {};
    return (jsonDecode(raw) as Map).cast<String, String>();
  }

  static Future<String> forUrl(String url) => _gate.run(() async {
    final all = await _load();
    final key = canonical(url);
    final saved = all[key];
    if (saved != null && RegExp(r'^[a-f0-9]{32}$').hasMatch(saved)) {
      return saved;
    }
    final random = Random.secure();
    final id = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    all[key] = id;
    await SecretPrefs.writeString(_key, jsonEncode(all));
    return id;
  });

  static Future<void> remove(String url) => _gate.run(() async {
    final all = await _load();
    if (all.remove(canonical(url)) != null) {
      await SecretPrefs.writeString(_key, jsonEncode(all));
    }
  });

  static Future<void> retain(Iterable<String> urls) => _gate.run(() async {
    final all = await _load();
    final keep = urls.map(canonical).toSet();
    all.removeWhere((key, _) => !keep.contains(key));
    await SecretPrefs.writeString(_key, jsonEncode(all));
  });
}
