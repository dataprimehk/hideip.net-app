import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hideip_vpn/core/profile_store.dart';
import 'package:hideip_vpn/core/proxy_profile.dart';
import 'package:hideip_vpn/core/secret_prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('premium flag survives a save/load round trip', () async {
    SharedPreferences.setMockInitialValues({});
    await ProfileStore.save([
      const ProxyProfile(
          name: 'Frankfurt',
          protocol: 'vless',
          server: '1.2.3.4',
          port: 443,
          outbound: {'type': 'vless'},
          premium: true),
      const ProxyProfile(
          name: 'my server',
          protocol: 'vless',
          server: '5.6.7.8',
          port: 443,
          outbound: {'type': 'vless'}),
    ]);
    final loaded = await ProfileStore.load();
    expect(loaded.map((p) => p.premium).toList(), [true, false]);
  });

  test('a name the user gave survives a save/load round trip', () async {
    SharedPreferences.setMockInitialValues({});
    await ProfileStore.save([
      const ProxyProfile(
          name: 'ch-zur-reality-03',
          protocol: 'vless',
          server: '1.2.3.4',
          port: 443,
          outbound: {'type': 'vless'},
          customName: 'Home'),
      const ProxyProfile(
          name: 'never renamed',
          protocol: 'vless',
          server: '5.6.7.8',
          port: 443,
          outbound: {'type': 'vless'}),
    ]);
    final loaded = await ProfileStore.load();
    expect(loaded.map((p) => p.customName).toList(), ['Home', null]);
    // The provider's own name is kept alongside it, so a rename is never a
    // loss and can always be undone.
    expect(loaded.first.name, 'ch-zur-reality-03');
  });

  test('the source text, city and place override survive a round trip',
      () async {
    SharedPreferences.setMockInitialValues({});
    await ProfileStore.save([
      const ProxyProfile(
          name: 'WireGuard 1.2.3.4',
          protocol: 'wireguard',
          server: '1.2.3.4',
          port: 51820,
          outbound: {'type': 'wireguard'},
          source: '[Interface]\nPrivateKey = x\n[Peer]\nEndpoint = 1.2.3.4:51820',
          city: 'Berlin',
          cc: 'DE',
          ccOverride: 'NL',
          cityOverride: 'Amsterdam'),
      const ProxyProfile(
          name: 'plain',
          protocol: 'vless',
          server: '5.6.7.8',
          port: 443,
          outbound: {'type': 'vless'}),
    ]);
    final loaded = await ProfileStore.load();
    final wg = loaded.first;
    expect(wg.source, startsWith('[Interface]'));
    expect(wg.city, 'Berlin');
    expect(wg.ccOverride, 'NL');
    expect(wg.cityOverride, 'Amsterdam');
    final plain = loaded.last;
    expect(plain.source, isNull);
    expect(plain.city, isNull);
    expect(plain.ccOverride, isNull);
    expect(plain.cityOverride, isNull);
  });

  test('clearing a name is told apart from leaving it alone', () {
    const p = ProxyProfile(
        name: 'ch-zur-reality-03',
        protocol: 'vless',
        server: '1.2.3.4',
        port: 443,
        outbound: {'type': 'vless'},
        customName: 'Home');
    expect(p.copyWith(cc: 'CH').customName, 'Home');
    expect(p.copyWith(customName: null).customName, isNull);
  });

  test('subUrl survives a save/load round trip', () async {
    SharedPreferences.setMockInitialValues({});
    await ProfileStore.save([
      const ProxyProfile(
          name: 'provider node',
          protocol: 'vless',
          server: '1.2.3.4',
          port: 443,
          outbound: {'type': 'vless'},
          subUrl: 'https://provider.example/sub/abc'),
      const ProxyProfile(
          name: 'pasted link',
          protocol: 'vless',
          server: '5.6.7.8',
          port: 443,
          outbound: {'type': 'vless'}),
    ]);
    final loaded = await ProfileStore.load();
    expect(loaded.map((p) => p.subUrl).toList(),
        ['https://provider.example/sub/abc', null]);
  });

  test('lists saved before the flag migrate via the old name prefix',
      () async {
    SharedPreferences.setMockInitialValues({
      'profiles_v1': jsonEncode([
        {
          'name': 'hideip.net Premium',
          'protocol': 'vless',
          'server': '1.2.3.4',
          'port': 443,
          'outbound': {'type': 'vless'},
        },
        {
          'name': 'my server',
          'protocol': 'vless',
          'server': '5.6.7.8',
          'port': 443,
          'outbound': {'type': 'vless'},
        },
      ]),
    });
    final loaded = await ProfileStore.load();
    expect(loaded.map((p) => p.premium).toList(), [true, false]);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('profiles_v1'), isFalse);
    expect(
      prefs.getString(SecretPrefs.encryptedPreferenceKey('profiles')),
      isNot(contains('hideip.net Premium')),
    );
  });
}
