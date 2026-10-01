import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hideip_vpn/core/premium.dart';
import 'package:hideip_vpn/core/provisioning.dart';
import 'package:hideip_vpn/core/proxy_profile.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A subscription URL the backend retires when the period it was issued for
/// ends, and the one a renewal replaces it with.
final _retired = Uri.parse('https://api.test/v1/sub/old-token');
final _renewed = Uri.parse('https://api.test/v1/sub/new-token');
final _catalogSource = Uri.parse('https://mirror.test/catalog');
final _provision = Uri.parse('${ProvisioningService.endpoint}/v1/provision');

const _proof = PurchasePayload.android(
  purchaseToken: 'tok-123',
  productId: PremiumProducts.monthly,
);

String _link(String name) =>
    'vless://uuid-local@203.0.113.50:443'
    '?security=reality&pbk=KEY&sni=renewed.test.invalid#$name';

ProxyProfile _cachedProfile() => ProxyProfile(
  name: 'Cached',
  protocol: 'vless',
  server: '192.0.2.10',
  port: 443,
  outbound: const {'type': 'vless', 'uuid': 'uuid-local'},
  premium: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await PremiumSub.clear();
    await PremiumSub.saveUrl(_retired.toString());
    await PremiumSub.saveProof(_proof);
  });

  /// A service whose catalog mirror is down, so every case here runs through
  /// the legacy subscription path the self-heal hangs off.
  ProvisioningService service(
    Future<http.Response> Function(http.Request request) handle,
    List<Uri> requests,
  ) => ProvisioningService(
    client: MockClient((request) async {
      requests.add(request.url);
      if (request.url == _catalogSource) return http.Response('', 503);
      return handle(request);
    }),
    catalogSources: [_catalogSource],
  );

  test('a retired subscription URL is re-provisioned once and comes back',
      () async {
    final requests = <Uri>[];
    var provisions = 0;
    final svc = service((request) async {
      if (request.url == _retired) return http.Response('', 410);
      if (request.url == _provision) {
        provisions++;
        // The heal answers for the store URL alone: it never asks for an
        // account it would have nowhere to put.
        expect(jsonDecode(request.body), provisionBody(_proof));
        expect((jsonDecode(request.body) as Map).containsKey('v'), isFalse);
        return http.Response(
          jsonEncode({'subscription_url': _renewed.toString()}),
          200,
        );
      }
      return http.Response(_link('Renewed'), 200);
    }, requests);

    final refresh = await svc.refreshProfiles(
      _retired.toString(),
      cachedProfiles: [_cachedProfile()],
    );

    expect(refresh?.expired, isFalse);
    expect(refresh?.profiles?.single.name, 'Renewed');
    expect(refresh?.profiles?.single.premium, isTrue);
    expect(refresh?.renewedUrl, _renewed.toString());
    expect(provisions, 1);
    expect(requests, [_catalogSource, _retired, _provision, _renewed]);
    // The new URL is persisted here, and the catalog identity follows it, so
    // the next launch never touches the dead one again.
    expect(await PremiumSub.url(), _renewed.toString());
    expect((await PremiumSub.identity())?.subToken, 'new-token');
  });

  test('a re-provision the backend also refuses ends the subscription',
      () async {
    final requests = <Uri>[];
    final svc = service(
      (_) async => http.Response('', 410),
      requests,
    );

    final refresh = await svc.refreshProfiles(
      _retired.toString(),
      cachedProfiles: [_cachedProfile()],
    );

    expect(refresh?.expired, isTrue);
    expect(refresh?.profiles, isEmpty);
    expect(refresh?.renewedUrl, isNull);
    expect(requests, [_catalogSource, _retired, _provision]);
    // The proof outlives the verdict: a later renewal provisions from it.
    expect(await PremiumSub.proof(), isNotNull);
  });

  test('a renewed URL that is gone too ends the subscription', () async {
    final requests = <Uri>[];
    final svc = service((request) async {
      if (request.url == _provision) {
        return http.Response(
          jsonEncode({'subscription_url': _renewed.toString()}),
          200,
        );
      }
      return http.Response('', 410);
    }, requests);

    final refresh = await svc.refreshProfiles(_retired.toString());

    expect(refresh?.expired, isTrue);
    expect(refresh?.profiles, isEmpty);
    expect(refresh?.renewedUrl, _renewed.toString());
    expect(requests, [_retired, _provision, _renewed]);
  });

  test('a transient re-provision failure leaves the cache in use', () async {
    final requests = <Uri>[];
    final cached = [_cachedProfile()];
    final svc = service((request) async {
      if (request.url == _retired) return http.Response('', 410);
      return http.Response('', 503);
    }, requests);

    final refresh = await svc.refreshProfiles(
      _retired.toString(),
      cachedProfiles: cached,
    );

    expect(refresh, isNull);
    expect((refresh?.profiles ?? cached), same(cached));
    expect(requests, [_catalogSource, _retired, _provision]);
    expect(await PremiumSub.url(), _retired.toString());
  });

  test('a transient subscription failure never spends the proof', () async {
    final requests = <Uri>[];
    final svc = service((_) async => http.Response('', 503), requests);

    expect(await svc.refreshProfiles(_retired.toString()), isNull);
    expect(requests, [_retired]);
  });

  test('without a stored proof there is nothing to heal with', () async {
    await PremiumSub.clear();
    final requests = <Uri>[];
    final svc = service((_) async => http.Response('', 404), requests);

    final refresh = await svc.refreshProfiles(_retired.toString());

    expect(refresh?.expired, isTrue);
    expect(requests, [_retired]);
  });

  test('healLapsed off reports the retired URL without re-provisioning',
      () async {
    final requests = <Uri>[];
    final svc = service((_) async => http.Response('', 410), requests);

    final refresh = await svc.refreshProfiles(
      _retired.toString(),
      healLapsed: false,
    );

    expect(refresh?.expired, isTrue);
    expect(requests, [_retired]);
  });

  group('provision', () {
    ProvisioningService provisioner(http.Response response) =>
        ProvisioningService(client: MockClient((_) async => response));

    test('404 and 410 are the only verdicts on the purchase', () async {
      for (final code in [404, 410]) {
        final result = await provisioner(http.Response('', code)).provision(
          _proof,
        );
        expect(result.status, ProvisionStatus.gone);
        expect(result.url, isNull);
      }
    });

    test('a server-side error decides nothing', () async {
      final result = await provisioner(
        http.Response('', 500),
      ).provision(_proof);
      expect(result.status, ProvisionStatus.transient);
    });

    test('a 200 without a URL decides nothing either', () async {
      final result = await provisioner(
        http.Response('{}', 200),
      ).provision(_proof);
      expect(result.status, ProvisionStatus.transient);
      expect(result.url, isNull);
    });

    test('a URL comes back as ok', () async {
      final body = jsonEncode({'subscription_url': _renewed.toString()});
      final result = await provisioner(
        http.Response(body, 200),
      ).provision(_proof);
      expect(result.status, ProvisionStatus.ok);
      expect(result.url, _renewed.toString());
      expect(result.account, isNull);
    });

    final withAccount = jsonEncode({
      'subscription_url': _renewed.toString(),
      'expires_ms': 0,
      'account': {
        'linked': 'joined',
        'number': null,
        'active': true,
        'expires_ms': 1767225600000,
        'kind': 'monthly',
        'device_token': 'k9Q-token',
        'device': {'id': 'dev_abc', 'kind': 'phone', 'name': 'Android phone'},
        'subscription_url': 'https://api.test/v1/sub/dev_abc',
        'device_limit': 5,
        'store': {'platform': 'android', 'expires_ms': 1764547200000},
      },
    });

    test('v2 sends the account fields and reads the account back', () async {
      http.Request? sent;
      final result = await ProvisioningService(
        client: MockClient((request) async {
          sent = request;
          return http.Response(withAccount, 200);
        }),
      ).provision(_proof, v2: true, deviceToken: 'k9Q-token');
      expect(jsonDecode(sent!.body), {
        ...provisionBody(_proof),
        'v': 2,
        'device_token': 'k9Q-token',
        'device': {'kind': 'phone', 'name': 'Android phone'},
      });
      expect(result.status, ProvisionStatus.ok);
      expect(result.url, _renewed.toString());
      final account = result.account!;
      expect(account.linked, 'joined');
      expect(account.deviceId, 'dev_abc');
      expect(
        account.storeExpires,
        DateTime.fromMillisecondsSinceEpoch(1764547200000),
      );
    });

    test('an account block on a v1 call is not read', () async {
      final result = await provisioner(
        http.Response(withAccount, 200),
      ).provision(_proof);
      expect(result.account, isNull);
    });

    test('v2 without an account block runs as before', () async {
      final body = jsonEncode({'subscription_url': _renewed.toString()});
      final result = await provisioner(
        http.Response(body, 200),
      ).provision(_proof, v2: true);
      expect(result.status, ProvisionStatus.ok);
      expect(result.url, _renewed.toString());
      expect(result.account, isNull);
    });
  });
}
