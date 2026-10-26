import 'package:flutter_test/flutter_test.dart';
import 'package:hideip_vpn/core/app_telemetry.dart';
import 'package:hideip_vpn/core/proxy_profile.dart';
import 'package:shared_preferences/shared_preferences.dart';

ProxyProfile _profile({
  String protocol = 'vless',
  bool premium = false,
  bool free = false,
  String? subUrl,
  String? source,
}) =>
    ProxyProfile(
      name: 'Secret name',
      protocol: protocol,
      server: '203.0.113.7',
      port: 443,
      outbound: const {'type': 'vless'},
      premium: premium,
      free: free,
      subUrl: subUrl,
      source: source,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<Map<String, Object>> sent;
  late bool accept;
  late DateTime clock;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    sent = [];
    accept = true;
    clock = DateTime(2026, 10, 26, 12);
    AppTelemetry.send = (body) async {
      sent.add(body);
      return accept;
    };
    AppTelemetry.resetFacts();
    AppTelemetry.facts = () async => DeviceFacts(
          country: 'IR',
          channel: 'play',
          installedAt: DateTime(2026, 10, 10),
        );
    AppTelemetry.now = () => clock;
  });

  test('sends each event once', () async {
    expect(await AppTelemetry.mark(AppEvent.firstOpen, enabled: true), isTrue);
    expect(await AppTelemetry.mark(AppEvent.firstOpen, enabled: true), isFalse);
    expect(sent, hasLength(1));
    expect(sent.single, {
      'event': 'first_open',
      'platform': AppTelemetry.platform,
      'country': 'IR',
      'channel': 'play',
    });
  });

  test('first connect carries the country and the given kind only', () async {
    await AppTelemetry.mark(AppEvent.firstConnect,
        enabled: true, attrs: {'kind': 'own'});
    expect(sent.single.keys.toSet(), {'event', 'platform', 'kind', 'country'});
  });

  test('a missing country is left out, not guessed', () async {
    AppTelemetry.facts = () async => const DeviceFacts(channel: 'apk');
    await AppTelemetry.mark(AppEvent.firstOpen, enabled: true);
    expect(sent.single.containsKey('country'), isFalse);
  });

  test('switched off means no request at all', () async {
    expect(await AppTelemetry.mark(AppEvent.firstConnect, enabled: false), isFalse);
    expect(await AppTelemetry.active(_profile(), enabled: false), isFalse);
    expect(sent, isEmpty);
    // Turning it on later still counts the event: nothing was burnt.
    expect(await AppTelemetry.mark(AppEvent.firstConnect, enabled: true), isTrue);
  });

  test('a failed send is retried on the next trigger', () async {
    accept = false;
    expect(await AppTelemetry.mark(AppEvent.firstProfile, enabled: true), isFalse);
    expect(await AppTelemetry.active(_profile(), enabled: true), isFalse);
    accept = true;
    expect(await AppTelemetry.mark(AppEvent.firstProfile, enabled: true), isTrue);
    expect(await AppTelemetry.active(_profile(), enabled: true), isTrue);
    expect(sent, hasLength(4));
  });

  group('active', () {
    test('carries labels only, never the server or its name', () async {
      await AppTelemetry.active(
        _profile(subUrl: 'https://panel.example/sub/abc'),
        enabled: true,
      );
      final body = sent.single;
      expect(body['event'], 'active');
      expect(body['kind'], 'own');
      expect(body['source'], 'sub');
      expect(body['proto'], 'vless');
      expect(body['channel'], 'play');
      expect(body['country'], 'IR');
      expect(body['age'], 'd7_29');
      expect(body['new_week'], isTrue);
      expect(body['new_month'], isTrue);
      final text = body.toString();
      expect(text, isNot(contains('203.0.113.7')));
      expect(text, isNot(contains('panel.example')));
      expect(text, isNot(contains('Secret')));
    });

    test('once a day; week and month flags only on their first ping', () async {
      expect(await AppTelemetry.active(_profile(), enabled: true), isTrue);
      expect(await AppTelemetry.active(_profile(), enabled: true), isFalse);
      clock = DateTime(2026, 10, 27, 9); // Tuesday, same ISO week and month
      expect(await AppTelemetry.active(_profile(), enabled: true), isTrue);
      expect(sent[1]['new_week'], isFalse);
      expect(sent[1]['new_month'], isFalse);
      clock = DateTime(2026, 11, 2, 9); // Monday: new week and month
      await AppTelemetry.active(_profile(), enabled: true);
      expect(sent[2]['new_week'], isTrue);
      expect(sent[2]['new_month'], isTrue);
      expect(sent, hasLength(3));
    });
  });

  group('UsageLabels', () {
    test('kind and source', () {
      expect(UsageLabels.kind(_profile(premium: true)), 'premium');
      expect(UsageLabels.kind(_profile(free: true)), 'free');
      expect(UsageLabels.source(_profile(premium: true)), 'premium');
      expect(UsageLabels.source(_profile(free: true)), 'free');
      expect(UsageLabels.source(_profile(subUrl: 'https://x')), 'sub');
      expect(UsageLabels.source(_profile(protocol: 'wireguard', source: '[Interface]')), 'wg');
      expect(UsageLabels.source(_profile(source: 'vless://x')), 'link');
      expect(UsageLabels.source(_profile()), 'paste');
    });

    test('unknown protocols collapse to other', () {
      expect(UsageLabels.proto(_profile(protocol: 'hysteria2')), 'hysteria2');
      expect(UsageLabels.proto(_profile(protocol: 'naive')), 'other');
    });

    test('age ranges', () {
      final now = DateTime(2026, 10, 26, 23);
      expect(UsageLabels.age(DateTime(2026, 10, 26, 1), now), 'd0');
      expect(UsageLabels.age(DateTime(2026, 10, 20), now), 'd1_6');
      expect(UsageLabels.age(DateTime(2026, 10, 19), now), 'd7_29');
      expect(UsageLabels.age(DateTime(2026, 9, 26), now), 'd30');
    });

    test('ISO weeks across year ends', () {
      expect(UsageLabels.week(DateTime(2026, 10, 26)), '2026-W44');
      expect(UsageLabels.week(DateTime(2026, 11, 1)), '2026-W44');
      expect(UsageLabels.week(DateTime(2027, 1, 1)), '2026-W53');
      expect(UsageLabels.week(DateTime(2024, 12, 30)), '2025-W01');
    });
  });

  test('install channel from the Android installer', () {
    DeviceFacts f(Object? installer) =>
        DeviceFacts.fromNative({'installer': installer, 'country': 'rs'}, ios: false);
    expect(f('com.android.vending').channel, 'play');
    expect(f('org.fdroid.fdroid').channel, 'fdroid');
    expect(f(null).channel, 'apk');
    expect(f('com.android.chrome').channel, 'apk');
    expect(f(null).country, 'RS');
    expect(DeviceFacts.fromNative({'country': 'Serbia'}, ios: true).country, isNull);
    expect(DeviceFacts.fromNative(const {}, ios: true).channel, 'appstore');
  });
}
