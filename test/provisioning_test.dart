import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hideip_vpn/core/premium.dart';
import 'package:hideip_vpn/core/provisioning.dart';
import 'package:hideip_vpn/core/proxy_profile.dart';

ProxyProfile _p(String name, {bool premium = false}) => ProxyProfile(
      name: name,
      protocol: 'vless',
      server: '1.2.3.4',
      port: 443,
      outbound: const {'type': 'vless'},
      premium: premium,
    );

void main() {
  test('premium profiles are recognized by the flag, never by name', () {
    expect(isPremiumProfile(_p('Frankfurt', premium: true)), isTrue);
    expect(isPremiumProfile(_p('my server')), isFalse);
    // A user profile that merely mentions the brand is not managed.
    expect(isPremiumProfile(_p('hideip.net Premium')), isFalse);
    expect(isPremiumProfile(_p('hideip-review')), isFalse);
  });

  test('merge replaces managed profiles and keeps user imports in place', () {
    final current = [
      _p('my server'),
      _p('Frankfurt', premium: true),
      _p('work vpn'),
    ];
    final fresh = [
      _p('Amsterdam', premium: true),
      _p('New York', premium: true),
    ];
    final merged = mergePremiumProfiles(current, fresh);
    expect(merged.map((p) => p.name).toList(),
        ['my server', 'work vpn', 'Amsterdam', 'New York']);
  });

  test('merge with no fresh profiles drops the managed ones', () {
    final current = [_p('Frankfurt', premium: true), _p('my server')];
    final merged = mergePremiumProfiles(current, const []);
    expect(merged.map((p) => p.name).toList(), ['my server']);
  });

  group('PurchasePayload', () {
    test('android payload round-trips through JSON', () {
      const p = PurchasePayload.android(
          purchaseToken: 'tok-123', productId: PremiumProducts.monthly);
      final back = PurchasePayload.tryParse(jsonEncode(p.toJson()))!;
      expect(back.platform, 'android');
      expect(back.purchaseToken, 'tok-123');
      expect(back.jws, isNull);
      expect(back.productId, PremiumProducts.monthly);
    });

    test('ios payload round-trips through JSON', () {
      const p =
          PurchasePayload.ios(jws: 'a.b.c', productId: PremiumProducts.yearly);
      final back = PurchasePayload.tryParse(jsonEncode(p.toJson()))!;
      expect(back.platform, 'ios');
      expect(back.jws, 'a.b.c');
      expect(back.purchaseToken, isNull);
      expect(back.productId, PremiumProducts.yearly);
    });

    test('legacy bare-JWS record migrates to an iOS payload', () {
      // Pre-Android persisted value: a raw StoreKit JWS, no JSON wrapper.
      final back = PurchasePayload.tryParse('header.payload.sig')!;
      expect(back.platform, 'ios');
      expect(back.jws, 'header.payload.sig');
      expect(back.purchaseToken, isNull);
      expect(back.productId, '');
    });

    test('empty persisted value parses to null', () {
      expect(PurchasePayload.tryParse(''), isNull);
    });
  });

  group('provisionBody', () {
    test('android body uses snake_case token and product id', () {
      const p = PurchasePayload.android(
          purchaseToken: 'tok-xyz', productId: PremiumProducts.yearly);
      expect(provisionBody(p), {
        'platform': 'android',
        'purchase_token': 'tok-xyz',
        'product_id': PremiumProducts.yearly,
      });
    });

    test('ios body is unchanged from the JWS-only contract', () {
      const p =
          PurchasePayload.ios(jws: 'a.b.c', productId: PremiumProducts.monthly);
      // iOS keeps exactly {platform, jws}: no product id, no token.
      expect(provisionBody(p), {'platform': 'ios', 'jws': 'a.b.c'});
    });

    test('v2 asks for the account and names the device like a sign-in', () {
      const p = PurchasePayload.android(
          purchaseToken: 'tok-xyz', productId: PremiumProducts.yearly);
      expect(provisionBody(p, v2: true), {
        'platform': 'android',
        'purchase_token': 'tok-xyz',
        'product_id': PremiumProducts.yearly,
        'v': 2,
        'device': {'kind': 'phone', 'name': 'Android phone'},
      });
    });

    test('v2 carries the device token of the account this device is on', () {
      const p =
          PurchasePayload.ios(jws: 'a.b.c', productId: PremiumProducts.monthly);
      expect(provisionBody(p, v2: true, deviceToken: 'k9Q-token'), {
        'platform': 'ios',
        'jws': 'a.b.c',
        'v': 2,
        'device_token': 'k9Q-token',
        'device': {'kind': 'phone', 'name': 'Android phone'},
      });
    });

    test('a device token without v2 is not sent', () {
      const p =
          PurchasePayload.ios(jws: 'a.b.c', productId: PremiumProducts.monthly);
      expect(provisionBody(p, deviceToken: 'k9Q-token'),
          {'platform': 'ios', 'jws': 'a.b.c'});
    });
  });

  group('ProvisionAccount', () {
    test('a new number comes with everything the device runs on', () {
      final a = ProvisionAccount.fromJson({
        'linked': 'new',
        'number': '8236 3877 8895 0319',
        'active': true,
        'expires_ms': 1767225600000,
        'kind': 'yearly',
        'device_token': 'k9Q-token',
        'device': {'id': 'dev_abc', 'kind': 'phone', 'name': 'iPhone'},
        'subscription_url': 'https://api.test/v1/sub/dev_abc',
        'device_limit': 5,
        'store': {'platform': 'ios', 'expires_ms': 1767225600000},
      })!;
      expect(a.usable, isTrue);
      expect(a.linked, 'new');
      expect(a.number, '8236387788950319');
      expect(a.expires, DateTime.fromMillisecondsSinceEpoch(1767225600000));
      expect(a.kind, 'yearly');
      expect(a.deviceToken, 'k9Q-token');
      expect(a.deviceId, 'dev_abc');
      expect(a.deviceName, 'iPhone');
      expect(a.subscriptionUrl, 'https://api.test/v1/sub/dev_abc');
      expect(a.deviceLimit, 5);
      expect(a.storePlatform, 'ios');
      expect(
          a.storeExpires, DateTime.fromMillisecondsSinceEpoch(1767225600000));
    });

    test('a later answer leaves the number out', () {
      final a = ProvisionAccount.fromJson({
        'linked': 'existing',
        'number': null,
        'active': true,
        'expires_ms': 1767225600000,
        'device_token': 'k9Q-token',
        'subscription_url': 'https://api.test/v1/sub/dev_abc',
      })!;
      expect(a.usable, isTrue);
      expect(a.number, isNull);
    });

    test('a number that fails its check digit is not taken', () {
      final a = ProvisionAccount.fromJson({
        'linked': 'new',
        'number': '1234567890123456',
        'active': true,
        'device_token': 'k9Q-token',
        'subscription_url': 'https://api.test/v1/sub/dev_abc',
      })!;
      expect(a.number, isNull);
    });

    test('an error is kept as it was said', () {
      final a = ProvisionAccount.fromJson(
          {'error': 'linked_elsewhere', 'device_limit': 5})!;
      expect(a.usable, isFalse);
      expect(a.error, ProvisionAccount.linkedElsewhere);
    });

    test('an answer the device cannot run on reads as unavailable', () {
      for (final raw in [
        {'active': false, 'device_token': 't', 'subscription_url': 'u'},
        {'active': true, 'subscription_url': 'u'},
        {'active': true, 'device_token': 't'},
      ]) {
        final a = ProvisionAccount.fromJson(raw)!;
        expect(a.error, ProvisionAccount.unavailable, reason: '$raw');
      }
    });

    test('no block is no account', () {
      expect(ProvisionAccount.fromJson(null), isNull);
      expect(ProvisionAccount.fromJson('x'), isNull);
    });
  });
}
