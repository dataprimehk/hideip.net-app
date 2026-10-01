import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hideip_vpn/core/account_service.dart';
import 'package:hideip_vpn/core/provisioning.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _number = '8236387788950319';
const _fresh = '5997190828766207';

/// A client that answers every request with [status]/[body] and records the
/// last request so the test can assert on the wire shape.
class _Recorder {
  http.Request? last;
  int calls = 0;

  http.Client client(int status, [String body = '']) => MockClient((req) async {
    last = req;
    calls++;
    return http.Response(
      body,
      status,
      headers: {'content-type': 'application/json'},
    );
  });

  Map<String, dynamic> get lastJson =>
      jsonDecode(last!.body) as Map<String, dynamic>;
}

String _detail(String code) => jsonEncode({'detail': code});

const _active = {
  'active': true,
  'expires_ms': 1767225600000,
  'subscription_url': 'https://api.hideip.net:8444/v1/sub/dev_3c0f',
  'device': {'id': 'dev_3c0f', 'kind': 'phone', 'name': 'Pixel 6a'},
  'device_token': 'k9Q-token',
  'device_limit': 5,
};

void main() {
  group('sign in', () {
    test('posts the documented body to /v1/account/signin', () async {
      final rec = _Recorder();
      await AccountService(
        client: rec.client(200, jsonEncode(_active)),
      ).signIn('8236 3877 8895 0319', name: 'Pixel 6a');

      expect(rec.last!.method, 'POST');
      expect(
        rec.last!.url.toString(),
        '${ProvisioningService.endpoint}/v1/account/signin',
      );
      expect(rec.last!.headers['content-type'], startsWith('application/json'));
      // The canonical number, never with separators, and never in the URL.
      expect(rec.lastJson, {
        'account_number': _number,
        'kind': 'phone',
        'name': 'Pixel 6a',
        'device_token': null,
      });
      expect(rec.last!.url.query, isEmpty);
    });

    test('passes a held device token along', () async {
      final rec = _Recorder();
      await AccountService(
        client: rec.client(200, jsonEncode(_active)),
      ).signIn(_number, name: 'Pixel 6a', deviceToken: 'held');
      expect(rec.lastJson['device_token'], 'held');
    });

    test('200 active is ok, with everything the app keeps', () async {
      final rec = _Recorder();
      final r = await AccountService(
        client: rec.client(200, jsonEncode(_active)),
      ).signIn(_number);
      expect(r.result, AccountResult.ok);
      expect(r.subscriptionUrl, 'https://api.hideip.net:8444/v1/sub/dev_3c0f');
      expect(r.deviceToken, 'k9Q-token');
      expect(r.deviceId, 'dev_3c0f');
      expect(r.expires, DateTime.fromMillisecondsSinceEpoch(1767225600000));
    });

    test('200 inactive keeps the date and adds no device', () async {
      final rec = _Recorder();
      final r = await AccountService(
        client: rec.client(
          200,
          jsonEncode({
            'active': false,
            'expires_ms': 1756684800000,
            'subscription_url': null,
            'device': null,
            'device_token': null,
            'device_limit': 5,
          }),
        ),
      ).signIn(_number);
      expect(r.result, AccountResult.inactive);
      expect(r.expires, DateTime.fromMillisecondsSinceEpoch(1756684800000));
      expect(r.subscriptionUrl, isNull);
      expect(r.deviceToken, isNull);
    });

    test('the error table maps onto the results', () async {
      final cases = {
        400: (_detail('invalid_account_number'), AccountResult.invalid),
        403: (_detail('account_revoked'), AccountResult.revoked),
        404: (_detail('unknown_account'), AccountResult.unknown),
        409: (_detail('device_limit_reached'), AccountResult.deviceLimit),
        429: (_detail('too_many_attempts'), AccountResult.tooManyAttempts),
        503: (_detail('account_api_not_configured'), AccountResult.network),
        500: ('', AccountResult.network),
      };
      for (final entry in cases.entries) {
        final rec = _Recorder();
        final r = await AccountService(
          client: rec.client(entry.key, entry.value.$1),
        ).signIn(_number);
        expect(r.result, entry.value.$2, reason: '${entry.key}');
      }
    });

    test('a device limit says how many devices', () async {
      final rec = _Recorder();
      final r = await AccountService(
        client: rec.client(409, _detail('device_limit_reached')),
      ).signIn(_number);
      expect(r.result, AccountResult.deviceLimit);
      expect(r.deviceLimit, 5);
    });

    test('a timeout or a dead network is a network failure', () async {
      final hung = MockClient((_) => Completer<http.Response>().future);
      final r =
          await AccountService(
                client: hung,
                timeout: const Duration(milliseconds: 50),
              )
              .signIn(_number)
              .timeout(
                const Duration(seconds: 5),
                onTimeout: () {
                  fail('the service must give up on its own');
                },
              );
      expect(r.result, AccountResult.network);

      final dead = MockClient((_) async => throw http.ClientException('down'));
      expect(
        (await AccountService(client: dead).signIn(_number)).result,
        AccountResult.network,
      );
    });

    test('a mistyped number never leaves the device', () async {
      final rec = _Recorder();
      final r = await AccountService(
        client: rec.client(200, jsonEncode(_active)),
      ).signIn('1234567890123456');
      expect(r.result, AccountResult.invalid);
      expect(rec.calls, 0);
    });

    test('an active answer without a URL is not taken as a sign-in', () async {
      final rec = _Recorder();
      final r = await AccountService(
        client: rec.client(
          200,
          jsonEncode({..._active, 'subscription_url': null}),
        ),
      ).signIn(_number);
      expect(r.result, AccountResult.network);
    });
  });

  group('status', () {
    test('posts the number and reads the devices', () async {
      final rec = _Recorder();
      final s = await AccountService(
        client: rec.client(
          200,
          jsonEncode({
            'active': true,
            'expires_ms': 1767225600000,
            'kind': 'yearly',
            'devices': [
              {
                'id': 'dev_3c0f',
                'kind': 'phone',
                'name': 'Pixel 6a',
                'created_at': 1756800000,
                'last_seen_at': 1756850000,
              },
            ],
            'device_limit': 5,
          }),
        ),
      ).status(_number);

      expect(
        rec.last!.url.toString(),
        '${ProvisioningService.endpoint}/v1/account/status',
      );
      expect(rec.lastJson, {'account_number': _number});
      expect(s!.result, AccountResult.ok);
      expect(s.active, isTrue);
      expect(s.kind, 'yearly');
      expect(s.devices!.single.id, 'dev_3c0f');
      expect(
        s.devices!.single.createdAt,
        DateTime.fromMillisecondsSinceEpoch(1756800000 * 1000),
      );
    });

    test('a revoked account says so, a dead network says nothing', () async {
      final revoked = await AccountService(
        client: _Recorder().client(403, _detail('account_revoked')),
      ).status(_number);
      expect(revoked!.result, AccountResult.revoked);

      final down = await AccountService(
        client: _Recorder().client(503, ''),
      ).status(_number);
      expect(down, isNull);

      final busy = await AccountService(
        client: _Recorder().client(429, _detail('too_many_attempts')),
      ).status(_number);
      expect(busy!.result, AccountResult.tooManyAttempts);
    });

    test('says whether a store subscription adds time to it', () async {
      final linked = await AccountService(
        client: _Recorder().client(
          200,
          jsonEncode({
            'active': true,
            'expires_ms': 1767225600000,
            'devices': [],
            'store_linked': true,
            'store_platform': 'ios',
            'store_expires_ms': 1764547200000,
          }),
        ),
      ).status(_number);
      expect(linked!.storeLinked, isTrue);
      expect(linked.storePlatform, 'ios');
      expect(
        linked.storeExpires,
        DateTime.fromMillisecondsSinceEpoch(1764547200000),
      );

      final older = await AccountService(
        client: _Recorder().client(200, jsonEncode({'active': true})),
      ).status(_number);
      expect(older!.storeLinked, isNull);
      expect(older.storePlatform, isNull);
      expect(older.storeExpires, isNull);
    });

    test('without a number, the device token asks instead', () async {
      final rec = _Recorder();
      final s = await AccountService(
        client: rec.client(200, jsonEncode({'active': true, 'devices': []})),
      ).status(null, deviceToken: 'k9Q-token');
      expect(rec.lastJson, {'device_token': 'k9Q-token'});
      expect(s!.result, AccountResult.ok);
    });

    test('a known number is sent instead of the token', () async {
      final rec = _Recorder();
      await AccountService(
        client: rec.client(200, jsonEncode({'active': true, 'devices': []})),
      ).status(_number, deviceToken: 'k9Q-token');
      expect(rec.lastJson, {'account_number': _number});
    });

    test('with neither, nothing leaves the device', () async {
      final rec = _Recorder();
      final s = await AccountService(
        client: rec.client(200, '{}'),
      ).status(null);
      expect(s!.result, AccountResult.invalid);
      expect(rec.calls, 0);
    });
  });

  group('rotate', () {
    test('posts revoke_devices and returns the new number', () async {
      final rec = _Recorder();
      final r = await AccountService(
        client: rec.client(
          200,
          jsonEncode({
            'account_number': _fresh,
            'expires_ms': 1767225600000,
            'devices_revoked': true,
          }),
        ),
      ).rotate(_number, revokeDevices: true);

      expect(
        rec.last!.url.toString(),
        '${ProvisioningService.endpoint}/v1/account/rotate',
      );
      expect(rec.lastJson, {'account_number': _number, 'revoke_devices': true});
      expect(r.result, AccountResult.ok);
      expect(r.accountNumber, _fresh);
      expect(r.devicesRevoked, isTrue);
    });

    test('keeps the devices unless asked', () async {
      final rec = _Recorder();
      await AccountService(
        client: rec.client(200, jsonEncode({'account_number': _fresh})),
      ).rotate(_number);
      expect(rec.lastJson['revoke_devices'], isFalse);
    });

    test('a malformed new number is not accepted', () async {
      final r = await AccountService(
        client: _Recorder().client(
          200,
          jsonEncode({'account_number': '1234567890123456'}),
        ),
      ).rotate(_number);
      expect(r.result, AccountResult.network);
      expect(r.accountNumber, isNull);
    });

    test('a device without the number gets one with its token', () async {
      final rec = _Recorder();
      final r = await AccountService(
        client: rec.client(200, jsonEncode({'account_number': _fresh})),
      ).rotate(null, deviceToken: 'k9Q-token');
      expect(rec.lastJson, {
        'device_token': 'k9Q-token',
        'revoke_devices': false,
      });
      expect(r.accountNumber, _fresh);
    });
  });

  group('revoke', () {
    test('one device', () async {
      final rec = _Recorder();
      final r = await AccountService(
        client: rec.client(200, jsonEncode({'ok': true, 'revoked': 1})),
      ).revokeDevice(_number, 'dev_3c0f');
      expect(
        rec.last!.url.toString(),
        '${ProvisioningService.endpoint}/v1/account/revoke',
      );
      expect(rec.lastJson, {
        'account_number': _number,
        'device_id': 'dev_3c0f',
      });
      expect(r, AccountResult.ok);
    });

    test('every device', () async {
      final rec = _Recorder();
      await AccountService(
        client: rec.client(200, jsonEncode({'ok': true, 'revoked': 3})),
      ).revokeAll(_number);
      expect(rec.lastJson, {'account_number': _number, 'all': true});
    });

    test('a device already gone counts as removed', () async {
      final r = await AccountService(
        client: _Recorder().client(404, _detail('unknown_device')),
      ).revokeDevice(_number, 'dev_x');
      expect(r, AccountResult.ok);
    });

    test('an unknown account is not a removed device', () async {
      final r = await AccountService(
        client: _Recorder().client(404, _detail('unknown_account')),
      ).revokeDevice(_number, 'dev_x');
      expect(r, AccountResult.unknown);
    });
  });

  group('revoke by device token', () {
    test('one device', () async {
      final rec = _Recorder();
      await AccountService(
        client: rec.client(200, jsonEncode({'ok': true, 'revoked': 1})),
      ).revokeDevice(null, 'dev_3c0f', deviceToken: 'k9Q-token');
      expect(rec.lastJson, {
        'device_token': 'k9Q-token',
        'device_id': 'dev_3c0f',
      });
    });
  });

  group('delete', () {
    test('posts the number to /v1/account/delete', () async {
      final rec = _Recorder();
      final r = await AccountService(
        client: rec.client(200, jsonEncode({'deleted': true})),
      ).delete(_number);
      expect(
        rec.last!.url.toString(),
        '${ProvisioningService.endpoint}/v1/account/delete',
      );
      expect(rec.lastJson, {'account_number': _number});
      expect(r, AccountResult.ok);
    });

    test('a device without the number deletes with its token', () async {
      final rec = _Recorder();
      final r = await AccountService(
        client: rec.client(200, jsonEncode({'deleted': true})),
      ).delete(null, deviceToken: 'k9Q-token');
      expect(rec.lastJson, {'device_token': 'k9Q-token'});
      expect(r, AccountResult.ok);
    });

    test('only a stated deletion counts as done', () async {
      final r = await AccountService(
        client: _Recorder().client(200, '{}'),
      ).delete(_number);
      expect(r, AccountResult.network);
    });

    test('the error table applies', () async {
      final revoked = await AccountService(
        client: _Recorder().client(403, _detail('account_revoked')),
      ).delete(_number);
      expect(revoked, AccountResult.revoked);
      final busy = await AccountService(
        client: _Recorder().client(429, _detail('too_many_attempts')),
      ).delete(_number);
      expect(busy, AccountResult.tooManyAttempts);
    });

    test('with neither a number nor a token, nothing is sent', () async {
      final rec = _Recorder();
      expect(
        await AccountService(client: rec.client(200, '{}')).delete(null),
        AccountResult.invalid,
      );
      expect(rec.calls, 0);
    });
  });
}
