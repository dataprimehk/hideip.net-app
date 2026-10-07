import 'package:flutter_test/flutter_test.dart';
import 'package:hideip_vpn/core/proxy_profile.dart';
import 'package:hideip_vpn/core/user_subscription.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

ProxyProfile _p(String name,
        {String server = '1.2.3.4', bool premium = false, String? subUrl}) =>
    ProxyProfile(
        name: name,
        protocol: 'vless',
        server: server,
        port: 443,
        outbound: const {'type': 'vless'},
        premium: premium,
        subUrl: subUrl);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  const url = 'https://provider.example/sub/abc';

  group('fetch', () {
    test('tags parsed profiles with the origin url on 200', () async {
      final svc = UserSubscriptionService(
          client: MockClient((req) async => http.Response(
              'vless://11111111-1111-1111-1111-111111111111@9.9.9.9:443'
              '?encryption=none#Fresh\n',
              200)));
      final fresh = await svc.fetch(url);
      expect(fresh, isNotNull);
      expect(fresh!.profiles.single.name, 'Fresh');
      expect(fresh.profiles.single.subUrl, url);
      // No plan headers on this response, so no SubInfo.
      expect(fresh.info, isNull);
    });

    test('surfaces SubInfo parsed from the response headers', () async {
      final svc = UserSubscriptionService(
          client: MockClient((req) async => http.Response(
                'vless://11111111-1111-1111-1111-111111111111@9.9.9.9:443'
                '?encryption=none#Fresh\n',
                200,
                headers: {
                  'subscription-userinfo':
                      'upload=1; download=2; total=100; expire=1800000000',
                  'profile-title': 'QuietProxy',
                  'profile-web-page-url': 'https://panel.example',
                },
              )));
      final fresh = await svc.fetch(url);
      expect(fresh, isNotNull);
      expect(fresh!.info, isNotNull);
      expect(fresh.info!.title, 'QuietProxy');
      expect(fresh.info!.totalBytes, 100);
      expect(fresh.info!.usedBytes, 3);
      expect(fresh.info!.webPageUrl, 'https://panel.example');
    });

    test('returns null on a transient failure so callers keep what they have',
        () async {
      final svc = UserSubscriptionService(
          client: MockClient((req) async => http.Response('', 503)));
      expect(await svc.fetch(url), isNull);
    });

    test('keeps cached profiles when a 200 response has no valid servers',
        () async {
      final svc = UserSubscriptionService(
          client: MockClient((req) async => http.Response('not a profile', 200)));
      expect(await svc.fetch(url), isNull);
    });

    test('keeps cached profiles on ambiguous retired or device-denied status',
        () async {
      for (final code in [404, 410]) {
        final svc = UserSubscriptionService(
            client: MockClient((req) async => http.Response('', code)));
        final res = await svc.fetch(url);
        expect(res, isNull);
      }
    });
  });

  group('userSubUrls', () {
    test('distinct urls in first-seen order, premium excluded', () {
      final urls = userSubUrls([
        _p('a', subUrl: 'https://one.example/s'),
        _p('b'),
        _p('c', subUrl: 'https://two.example/s'),
        _p('d', subUrl: 'https://one.example/s'),
        _p('e', premium: true, subUrl: 'https://premium.example/s'),
      ]);
      expect(urls, ['https://one.example/s', 'https://two.example/s']);
    });
  });

  group('mergeUserSubProfiles', () {
    test('replaces the group in place, leaving everything else untouched', () {
      final current = [
        _p('single import'),
        _p('old 1', subUrl: url),
        _p('other sub', subUrl: 'https://other.example/s'),
        _p('old 2', subUrl: url),
        _p('premium', premium: true),
      ];
      final merged = mergeUserSubProfiles(
          current, url, [_p('new 1', subUrl: url), _p('new 2', subUrl: url)]);
      expect(merged.map((p) => p.name).toList(),
          ['single import', 'new 1', 'new 2', 'other sub', 'premium']);
    });

    test('an empty fresh list clears the group (provider retired the link)',
        () {
      final current = [
        _p('single import'),
        _p('old 1', subUrl: url),
      ];
      final merged = mergeUserSubProfiles(current, url, const []);
      expect(merged.map((p) => p.name).toList(), ['single import']);
    });

    test('a premium profile is never treated as part of a user sub', () {
      final current = [
        _p('premium', premium: true, subUrl: url),
        _p('old', subUrl: url),
      ];
      final merged = mergeUserSubProfiles(current, url, [_p('new', subUrl: url)]);
      expect(merged.map((p) => p.name).toList(), ['premium', 'new']);
    });
  });
}
