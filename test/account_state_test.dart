import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hideip_vpn/core/account_service.dart';
import 'package:hideip_vpn/core/account_store.dart';
import 'package:hideip_vpn/core/premium.dart';
import 'package:hideip_vpn/core/provisioning.dart';
import 'package:hideip_vpn/state/app_state.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _number = '8236387788950319';
const _subUrl = 'https://api.test/v1/sub/dev_abc';
final _catalog = Uri.parse('https://mirror.test/catalog');

String _link(String name) =>
    'vless://11111111-1111-1111-1111-111111111111@127.0.0.1:9'
    '?security=none#$name';

/// The account API as the contract describes it, with the answers a test
/// can change and every request kept for asserting on.
class _Backend {
  final requests = <http.Request>[];
  bool active = true;
  int statusCode = 200;
  DateTime expires = DateTime.now().add(const Duration(days: 30));
  List<String> devices = ['dev_abc'];

  Map<String, dynamic> body(http.Request r) =>
      jsonDecode(r.body) as Map<String, dynamic>;

  List<http.Request> to(String path) =>
      requests.where((r) => r.url.path == path).toList();

  http.Client get client => MockClient((req) async {
    requests.add(req);
    final ms = expires.millisecondsSinceEpoch;
    switch (req.url.path) {
      case '/v1/account/signin':
        if (statusCode != 200) {
          return http.Response(jsonEncode({'detail': 'x'}), statusCode);
        }
        return http.Response(
          jsonEncode(
            active
                ? {
                    'active': true,
                    'expires_ms': ms,
                    'subscription_url': _subUrl,
                    'device': {
                      'id': 'dev_abc',
                      'kind': 'phone',
                      'name': 'Android phone',
                    },
                    'device_token': 'k9Q-token',
                    'device_limit': 5,
                  }
                : {
                    'active': false,
                    'expires_ms': ms,
                    'subscription_url': null,
                    'device': null,
                    'device_token': null,
                    'device_limit': 5,
                  },
          ),
          200,
        );
      case '/v1/account/status':
        if (statusCode != 200) {
          return http.Response(jsonEncode({'detail': 'x'}), statusCode);
        }
        return http.Response(
          jsonEncode({
            'active': active,
            'expires_ms': ms,
            'kind': 'yearly',
            'devices': [
              for (final id in devices) {'id': id, 'kind': 'phone', 'name': id},
            ],
            'device_limit': 5,
          }),
          200,
        );
      case '/v1/account/revoke':
        return http.Response(jsonEncode({'ok': true, 'revoked': 1}), 200);
    }
    return http.Response('', 404);
  });
}

/// Premium profiles served at the account's subscription URL; the signed
/// catalog mirror is down, so the legacy path answers.
ProvisioningService _provisioning() => ProvisioningService(
  client: MockClient((req) async {
    if (req.url == _catalog) return http.Response('', 503);
    if (req.url.toString() == _subUrl) {
      return http.Response('${_link('de-fra-01')}\n${_link('ch-zur-02')}', 200);
    }
    return http.Response('', 404);
  }),
  catalogSources: [_catalog],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Backend backend;
  late AppState state;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await PremiumSub.clear();
    await const AccountStore().clear();
    backend = _Backend();
    state = AppState(
      accounts: AccountService(client: backend.client),
      provisioning: _provisioning(),
    );
  });

  test('signing in puts the account in force, like a purchase', () async {
    final r = await state.signInWithAccountNumber('8236 3877 8895 0319');
    await pumpEventQueue();

    expect(r.result, AccountResult.ok);
    expect(state.premium.source, PremiumSource.account);
    expect(state.premium.isOn, isTrue);
    expect(await PremiumSub.url(), _subUrl);
    expect(state.profiles.where((p) => p.premium), hasLength(2));
    expect(state.accountSignedIn, isTrue);
    expect(state.accountNumber, _number);
    // The kind arrives with the status call that follows the sign-in.
    expect(state.premium.plan, PremiumPlan.yearly);

    final stored = await const AccountStore().load();
    expect(stored!.number, _number);
    expect(stored.deviceToken, 'k9Q-token');
    expect(stored.deviceId, 'dev_abc');

    // It survives a restart.
    final loaded = await Premium.load();
    expect(loaded.source, PremiumSource.account);
    expect(loaded.isOn, isTrue);
  });

  test('the link API gets this device token, not the URL token', () async {
    await state.signInWithAccountNumber(_number);
    await pumpEventQueue();

    expect(state.subToken, 'k9Q-token');
    expect(state.canLinkDevices, isTrue);
  });

  test('an account out of time keeps the number and says expired', () async {
    backend.active = false;
    backend.expires = DateTime.now().subtract(const Duration(days: 3));

    final r = await state.signInWithAccountNumber(_number);

    expect(r.result, AccountResult.inactive);
    expect(state.accountSignedIn, isTrue);
    expect((await const AccountStore().load())!.number, _number);
    expect(state.premium.status, PremiumStatus.expired);
    expect(state.premium.source, PremiumSource.account);
    expect(state.premium.isOn, isFalse);
    expect(state.profiles.where((p) => p.premium), isEmpty);
    expect(state.canLinkDevices, isFalse);
  });

  test('a refused number changes nothing on the device', () async {
    backend.statusCode = 404;

    final r = await state.signInWithAccountNumber(_number);

    expect(r.result, AccountResult.unknown);
    expect(state.accountSignedIn, isFalse);
    expect(state.premium.status, PremiumStatus.none);
    expect(await const AccountStore().load(), isNull);
  });

  test('signing out clears everything and takes the device off', () async {
    await state.signInWithAccountNumber(_number);
    await pumpEventQueue();

    await state.signOutAccount();
    await pumpEventQueue();

    expect(state.accountSignedIn, isFalse);
    expect(state.accountNumber, isNull);
    expect(await const AccountStore().load(), isNull);
    expect(state.premium.isOn, isFalse);
    expect(state.premium.status, PremiumStatus.none);
    expect(await PremiumSub.url(), isNull);
    expect(state.profiles.where((p) => p.premium), isEmpty);
    expect(state.subToken, isNull);
    final revoke = backend.to('/v1/account/revoke');
    expect(revoke, hasLength(1));
    expect(backend.body(revoke.single), {
      'account_number': _number,
      'device_id': 'dev_abc',
    });
  });

  test('signing in again reuses this device instead of a new slot', () async {
    await state.signInWithAccountNumber(_number);
    await pumpEventQueue();
    await state.signInWithAccountNumber(_number);

    final signins = backend.to('/v1/account/signin');
    expect(backend.body(signins.first)['device_token'], isNull);
    expect(backend.body(signins.last)['device_token'], 'k9Q-token');
  });

  test('a device removed from elsewhere is signed out here', () async {
    await state.signInWithAccountNumber(_number);
    await pumpEventQueue();

    backend.devices = ['dev_other'];
    await state.refreshAccount();

    expect(state.accountSignedIn, isFalse);
    expect(state.premium.isOn, isFalse);
    expect(state.profiles.where((p) => p.premium), isEmpty);
    // No new sign-in quietly puts it back.
    expect(backend.to('/v1/account/signin'), hasLength(1));
  });

  test('a revoked account loses its servers but keeps the number', () async {
    await state.signInWithAccountNumber(_number);
    await pumpEventQueue();

    backend.statusCode = 403;
    await state.refreshAccount();

    expect(state.accountProblem, AccountResult.revoked);
    expect(state.accountSignedIn, isTrue);
    expect(state.premium.isOn, isFalse);
    expect(state.profiles.where((p) => p.premium), isEmpty);
  });

  test('a store subscription that lasts longer stays in force', () async {
    final storeEnds = DateTime.now().add(const Duration(days: 300));
    // What the purchase stream leaves behind for a live store subscription.
    state.premiumForTesting = Premium(
      status: PremiumStatus.active,
      plan: PremiumPlan.yearly,
      renews: storeEnds,
    );

    await state.signInWithAccountNumber(_number);
    await pumpEventQueue();

    expect(state.accountSignedIn, isTrue);
    expect(state.premium.source, PremiumSource.store);
    expect(state.premium.renews, storeEnds);
    expect(await PremiumSub.url(), isNull);
  });

  group('the persisted entitlement', () {
    test('a record from before account numbers is a store one', () async {
      final renews = DateTime.now().add(const Duration(days: 10));
      SharedPreferences.setMockInitialValues({
        'premium_v1': jsonEncode({
          'status': 'active',
          'plan': 'yearly',
          'renews': renews.millisecondsSinceEpoch,
        }),
      });
      final p = await Premium.load();
      expect(p.source, PremiumSource.store);
      expect(p.isOn, isTrue);
      expect(p.plan, PremiumPlan.yearly);
    });

    test('an unknown source reads as store, never as a crash', () async {
      SharedPreferences.setMockInitialValues({
        'premium_v1': jsonEncode({
          'status': 'active',
          'plan': null,
          'renews': null,
          'source': 'somewhere-new',
        }),
      });
      expect((await Premium.load()).source, PremiumSource.store);
    });

    test('an account entitlement lapses on load like a store one', () async {
      await Premium(
        status: PremiumStatus.active,
        renews: DateTime.now().subtract(const Duration(hours: 1)),
        source: PremiumSource.account,
      ).save();
      final p = await Premium.load();
      expect(p.status, PremiumStatus.expired);
      expect(p.source, PremiumSource.account);
    });
  });
}
