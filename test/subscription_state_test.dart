import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hideip_vpn/core/ip_lookup.dart';
import 'package:hideip_vpn/core/share_link_parser.dart';
import 'package:hideip_vpn/core/subscription_identity.dart';
import 'package:hideip_vpn/core/user_subscription.dart';
import 'package:hideip_vpn/state/app_state.dart';

class QuietState extends AppState {
  QuietState(UserSubscriptionService service)
    : super(userSubscriptions: service);
  @override
  Future<void> pingAll() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    IpLookup.lookupOverride = (_) async => null;
  });
  tearDown(() => IpLookup.lookupOverride = null);
  const url = 'https://provider.example/sub';
  test(
    'failed and all-unsupported refreshes preserve selection and profiles',
    () async {
      var response = http.Response('', 404);
      final service = UserSubscriptionService(
        client: MockClient((r) async => response),
      );
      final state = QuietState(service);
      final old = ShareLinkParser.parse(
        'vless://id@example.com:443#de-fra-01',
      )!.copyWith(subUrl: url);
      await state.addProfiles([old], countFirstProfile: false);
      final responses = [
        http.Response('', 404),
        http.Response('', 410),
        http.Response('', 200),
        http.Response('vless://id@0.0.0.0:1#App%20not%20supported', 200),
        http.Response('vless://id@example.com:443?type=xhttp', 200),
      ];
      for (final next in responses) {
        response = next;
        expect(await state.refreshSubscription(url), isNull);
        expect(state.profiles, [old]);
        expect(state.selected, old);
        expect(state.subscriptionNotice(url), isNotEmpty);
      }
      response = http.Response(
        'vless://id@example.com:443#nl-ams-01\nvless://id@example.com:443?type=xhttp',
        200,
      );
      expect(await state.refreshSubscription(url), 1);
      expect(state.profiles.single.name, 'nl-ams-01');
      expect(state.subscriptionNotice(url), contains('xhttp'));
      final id = await SubscriptionIdentity.forUrl(url);
      await state.remove(0);
      expect(await SubscriptionIdentity.forUrl(url), isNot(id));
      state.dispose();
    },
  );
}
