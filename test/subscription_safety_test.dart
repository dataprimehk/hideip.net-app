import 'package:flutter_test/flutter_test.dart';
import 'package:hideip_vpn/core/user_subscription.dart';
import 'package:hideip_vpn/core/safe_http.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hideip_vpn/core/subscription_identity.dart';
import 'package:hideip_vpn/core/subscription.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  const url = 'https://provider.example/sub';
  test('404 does not authorize deletion of saved servers', () async {
    final s = UserSubscriptionService(
      client: MockClient((r) async => http.Response('', 404)),
    );
    final r = await s.fetch(url);
    expect(r == null || r.profiles.isNotEmpty, true);
  });
  test('placeholder never replaces real subscription servers', () async {
    final s = UserSubscriptionService(
      client: MockClient(
        (r) async =>
            http.Response('vless://id@0.0.0.0:1#App%20not%20supported', 200),
      ),
    );
    final r = await s.fetch(url);
    expect(r == null || r.profiles.isEmpty, true);
  });
  for (final destination in [
    'https://hideip.net/sub',
    'https://api.hideip.net/sub',
    'https://another.example/sub',
  ]) {
    test('HWID cannot follow redirect to $destination', () async {
      final fetcher = SafeHttpFetcher.forTesting(
        MockClient((r) async {
          if (r.url.toString() == url) {
            return http.Response('', 302, headers: {'location': destination});
          }
          expect(r.headers.containsKey('x-hwid'), false);
          return http.Response('', 200);
        }),
      );
      await fetcher.get(
        Uri.parse(url),
        headers: {'x-hwid': '0123456789abcdef'},
      );
    });
  }
  test('own domains never receive HWID even on initial request', () async {
    final f = SafeHttpFetcher.forTesting(
      MockClient((r) async {
        expect(r.headers.containsKey('x-hwid'), false);
        return http.Response('', 200);
      }),
    );
    await f.get(
      Uri.parse('https://api.hideip.net./sub'),
      headers: {'x-hwid': '0123456789abcdef'},
    );
  });
  test(
    'ID is stable, isolated per subscription, and removed on deletion',
    () async {
      final first = await SubscriptionIdentity.forUrl(url);
      expect(first, matches(RegExp(r'^[a-f0-9]{32}$')));
      expect(await SubscriptionIdentity.forUrl(url), first);
      expect(await SubscriptionIdentity.forUrl('$url/other'), isNot(first));
      expect(
        await SubscriptionIdentity.forUrl('https://other.example/sub'),
        isNot(first),
      );
      await SubscriptionIdentity.remove(url);
      expect(await SubscriptionIdentity.forUrl(url), isNot(first));
    },
  );
  test(
    'concurrent imports share one ID and do not lose other subscriptions',
    () async {
      final ids = await Future.wait(
        List.generate(8, (_) => SubscriptionIdentity.forUrl(url)),
      );
      expect(ids.toSet().length, 1);
      await Future.wait([
        SubscriptionIdentity.forUrl('$url/a'),
        SubscriptionIdentity.forUrl('$url/b'),
      ]);
      final a = await SubscriptionIdentity.forUrl('$url/a');
      final b = await SubscriptionIdentity.forUrl('$url/b');
      await SubscriptionIdentity.retain(['$url/a']);
      expect(await SubscriptionIdentity.forUrl('$url/a'), a);
      expect(await SubscriptionIdentity.forUrl('$url/b'), isNot(b));
    },
  );
  test('IDs disappear with app preferences on reinstall', () async {
    final first = await SubscriptionIdentity.forUrl(url);
    SharedPreferences.setMockInitialValues({});
    expect(await SubscriptionIdentity.forUrl(url), isNot(first));
  });
  test('refresh sends only x-hwid, stable across service instances', () async {
    final ids = <String>[];
    final client = MockClient((r) async {
      ids.add(r.headers['x-hwid']!);
      expect(
        r.headers.keys.where(
          (k) => k.startsWith('x-device') || k == 'x-ver-os',
        ),
        isEmpty,
      );
      return http.Response('vless://id@example.com:443', 200);
    });
    await UserSubscriptionService(client: client).read(url);
    await UserSubscriptionService(client: client).read(url);
    expect(ids[0], ids[1]);
  });
  test(
    'typed HWID failures and empty results preserve existing servers',
    () async {
      final cases = <(http.Response, SubscriptionFailure)>[
        (
          http.Response(
            '',
            200,
            headers: {'x-hwid-max-devices-reached': 'true'},
          ),
          SubscriptionFailure.deviceLimit,
        ),
        (
          http.Response('', 404, headers: {'x-hwid-not-supported': 'true'}),
          SubscriptionFailure.hwidRequired,
        ),
        (
          http.Response('HWID header required', 403),
          SubscriptionFailure.hwidRequired,
        ),
        (
          http.Response('Device limit reached', 403),
          SubscriptionFailure.deviceLimit,
        ),
        (http.Response('', 200), SubscriptionFailure.empty),
        (
          http.Response('vless://id@0.0.0.0:1#App%20not%20supported', 200),
          SubscriptionFailure.placeholder,
        ),
        (
          http.Response('vless://id@example.com:443?type=xhttp', 200),
          SubscriptionFailure.noSupportedProfiles,
        ),
        (http.Response('', 404), SubscriptionFailure.http),
        (http.Response('', 410), SubscriptionFailure.http),
      ];
      for (final c in cases) {
        final svc = UserSubscriptionService(
          client: MockClient((r) async => c.$1),
        );
        await expectLater(
          svc.read(url),
          throwsA(
            isA<SubscriptionFetchException>().having(
              (e) => e.reason,
              'reason',
              c.$2,
            ),
          ),
        );
        expect(await svc.fetch(url), isNull);
      }
    },
  );
  test(
    'mixed subscription reports every unsupported entry beyond error cap',
    () {
      final parsed = Subscription.parse(
        List.filled(120, 'vless://id@example.com:443?type=xhttp').join('\n'),
      );
      expect(parsed.unsupported['xhttp'], 120);
      expect(parsed.errors.length, Subscription.maxErrors);
      expect(parsed.profiles, isEmpty);
    },
  );
}
