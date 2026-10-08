import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hideip_vpn/core/device_link.dart';
import 'package:hideip_vpn/core/pairing.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _token = 'dev-token-abc';
const _number = '8236387788950319';

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

http.Response _detail(int status, String detail) =>
    _json({'detail': detail}, status);

const _caps = {
  'pairing': 2,
  'kinds': ['phone', 'tablet', 'desktop', 'tv', 'extension'],
  'code_length': 8,
  'link_ttl_s': 600,
  'delivery_ttl_s': 900,
  'features': ['preview', 'ack', 'cancel', 'permissions', 'signout'],
};

Map<String, dynamic> _row(
  String id, {
  String kind = 'phone',
  bool manage = false,
  bool current = false,
}) => {
  'id': id,
  'kind': kind,
  'name': id,
  'created_at': 1760000000,
  'last_seen_at': 1760000500,
  'permissions': {'use': true, 'manage': manage},
  'current': current,
};

void main() {
  late List<http.Request> requests;

  PairingClient client(
    Future<http.Response> Function(http.Request r) answer, {
    DateTime Function()? now,
  }) => PairingClient(
    client: MockClient((r) async {
      requests.add(r);
      return answer(r);
    }),
    now: now,
  );

  Map<String, dynamic> body(http.Request r) =>
      jsonDecode(r.body) as Map<String, dynamic>;

  setUp(() => requests = []);

  group('capabilities', () {
    test('a v2 server is read and kept for five minutes', () async {
      var now = DateTime(2026, 10, 8, 12);
      final c = client((_) async => _json(_caps), now: () => now);

      final caps = await c.capabilities();
      expect(caps.v2, isTrue);
      expect(caps.permissions, isTrue);
      expect(caps.request, isTrue);
      expect(caps.kinds, contains('tv'));
      expect(caps.linkTtl, const Duration(minutes: 10));

      now = now.add(const Duration(minutes: 4));
      await c.capabilities();
      expect(requests, hasLength(1));

      now = now.add(const Duration(minutes: 2));
      await c.capabilities();
      expect(requests, hasLength(2));
    });

    test('404, no answer and an old version all read as no v2', () async {
      for (final answer in <Future<http.Response> Function(http.Request)>[
        (_) async => http.Response('', 404),
        (_) async => throw http.ClientException('down'),
        (_) async => _json({'pairing': 1, 'features': []}),
        (_) async => http.Response('not json', 200),
      ]) {
        final caps = await client(answer).capabilities();
        expect(caps.v2, isFalse);
        expect(caps.request, isFalse);
      }
    });

    test(
      'a failed question is asked again sooner than a good answer',
      () async {
        var now = DateTime(2026, 10, 8, 12);
        final c = client((_) async => http.Response('', 503), now: () => now);
        await c.capabilities();
        now = now.add(const Duration(seconds: 10));
        await c.capabilities();
        expect(requests, hasLength(1));
        now = now.add(const Duration(seconds: 31));
        await c.capabilities();
        expect(requests, hasLength(2));
      },
    );
  });

  group('approving', () {
    test(
      'preview by code sends v2, the token and the normalized code',
      () async {
        final c = client(
          (_) async => _json({
            'link_id': 'L1',
            'code': '7KQM-3XHP',
            'device': {
              'kind': 'tv',
              'name': 'Living room TV',
              'platform': 'android',
            },
            'expires_in': 412,
            'state': 'pending',
            'can_grant_manage': false,
            'account': {'active': true, 'devices_used': 3, 'device_limit': 5},
          }),
        );
        final r = await c.preview(
          const PairingAuth(token: _token),
          code: '7kqm 3xhp',
        );
        expect(r.request!.device.kind, DeviceKind.tv);
        expect(r.request!.code, '7KQM-3XHP');
        expect(r.request!.devicesUsed, 3);
        final sent = body(requests.single);
        expect(sent, {'v': 2, 'token': _token, 'code': '7KQM3XHP'});
        expect(requests.single.url.path, '/v1/link/preview');
        expect(requests.single.url.query, isEmpty);
      },
    );

    test('preview of a request this account approved has no code', () async {
      final c = client(
        (_) async => _json({
          'link_id': 'L1',
          'code': null,
          'device': {'kind': 'tablet', 'name': '', 'platform': null},
          'expires_in': 0,
          'state': 'approved',
          'can_grant_manage': true,
          'account': {'active': true, 'devices_used': 4, 'device_limit': 5},
        }),
      );
      final r = await c.preview(const PairingAuth(token: _token), linkId: 'L1');
      expect(r.request!.code, '');
      expect(r.request!.device.kind, DeviceKind.tablet);
    });

    test('a number is sent in the body when there is no token', () async {
      final c = client((_) async => _detail(404, 'unknown_link'));
      final r = await c.preview(
        const PairingAuth(accountNumber: '8236 3877 8895 0319'),
        linkId: 'L1',
      );
      expect(r.error, PairingError.unknownLink);
      expect(body(requests.single)['account_number'], _number);
      expect(body(requests.single).containsKey('token'), isFalse);
    });

    test('preview needs exactly one of link id and code', () async {
      final c = client((_) async => _json({}));
      expect(
        (await c.preview(const PairingAuth(token: _token))).error,
        PairingError.unauthorized,
      );
      expect(
        (await c.preview(
          const PairingAuth(token: _token),
          linkId: 'L1',
          code: 'AAAA-BBBB',
        )).error,
        PairingError.unauthorized,
      );
      expect(requests, isEmpty);
    });

    test('every error the contract names maps to its own value', () async {
      final cases = {
        (401, 'unauthorized'): PairingError.unauthorized,
        (403, 'not_permitted'): PairingError.notPermitted,
        (403, 'account_revoked'): PairingError.accountRevoked,
        (403, 'subscription_inactive'): PairingError.subscriptionInactive,
        (404, 'unknown_link'): PairingError.unknownLink,
        (400, 'bad_code'): PairingError.badCode,
        (410, 'link_expired'): PairingError.linkExpired,
        (410, 'link_cancelled'): PairingError.linkCancelled,
        (429, 'too_many_attempts'): PairingError.tooManyAttempts,
        (500, 'boom'): PairingError.network,
      };
      for (final e in cases.entries) {
        final c = client((_) async => _detail(e.key.$1, e.key.$2));
        final r = await c.approve(
          const PairingAuth(token: _token),
          linkId: 'L1',
          grantManage: false,
        );
        expect(r.error, e.value, reason: '${e.key}');
      }
    });

    test('approve reads the device, its right and a repeat', () async {
      final c = client(
        (_) async => _json({
          'ok': true,
          'status': 'approved',
          'already': true,
          'device': {'id': 'dev_tv', 'kind': 'tv', 'name': 'Living room TV'},
          'permissions': {'use': true, 'manage': false},
        }),
      );
      final r = await c.approve(
        const PairingAuth(token: _token),
        linkId: 'L1',
        grantManage: true,
      );
      expect(r.ok, isTrue);
      expect(r.already, isTrue);
      expect(r.manage, isFalse);
      expect(r.device!.kind, DeviceKind.tv);
      expect(body(requests.single), {
        'v': 2,
        'token': _token,
        'link_id': 'L1',
        'grant_manage': true,
      });
    });

    test('a full account comes back with its devices to choose from', () async {
      final c = client(
        (_) async => _json({
          'detail': 'device_limit_reached',
          'device_limit': 5,
          'devices': [
            _row('dev_me', manage: true, current: true),
            _row('dev_tv', kind: 'tv'),
            {'kind': 'phone'},
          ],
        }, 409),
      );
      final r = await c.approve(
        const PairingAuth(token: _token),
        linkId: 'L1',
        grantManage: false,
      );
      expect(r.error, PairingError.deviceLimitReached);
      expect(r.deviceLimit, 5);
      expect(r.devices.map((d) => d.id), ['dev_me', 'dev_tv']);
      expect(r.devices.first.current, isTrue);
      expect(r.devices.last.kind, DeviceKind.tv);
    });

    test(
      'the device list carries the token in the query, never a number',
      () async {
        final c = client(
          (_) async => _json({
            'devices': [
              _row('dev_me', manage: true, current: true),
              _row('dev_tab', kind: 'tablet'),
            ],
          }),
        );
        final list = await c.devices(_token);
        expect(list!.map((d) => d.kind), [DeviceKind.phone, DeviceKind.tablet]);
        expect(list.first.manage, isTrue);
        expect(requests.single.url.queryParameters, {
          'token': _token,
          'v': '2',
        });
      },
    );

    test('revoke and permissions say last_manager, self and kind', () async {
      var reply = _detail(409, 'last_manager');
      final c = client((_) async => reply);
      final auth = const PairingAuth(token: _token);

      expect((await c.revoke(auth, 'dev_x')).error, PairingError.lastManager);
      reply = _json({'ok': true});
      expect(
        (await c.revoke(auth, 'dev_x', confirmLastManager: true)).ok,
        isTrue,
      );
      expect(body(requests.last), {
        'v': 2,
        'token': _token,
        'device_id': 'dev_x',
        'confirm_last_manager': true,
      });

      reply = _detail(400, 'self');
      expect(
        (await c.setManage(auth, 'dev_me', manage: true)).error,
        PairingError.self,
      );
      reply = _detail(400, 'not_allowed_for_kind');
      expect(
        (await c.setManage(auth, 'dev_tv', manage: true)).error,
        PairingError.notAllowedForKind,
      );
      reply = _json({
        'ok': true,
        'device': _row('dev_tab', kind: 'tablet', manage: true),
      });
      final ok = await c.setManage(auth, 'dev_tab', manage: true);
      expect(ok.device!.manage, isTrue);
      expect(requests.last.url.path, '/v1/link/permissions');
    });

    test(
      'nothing is sent without anything to prove the account with',
      () async {
        final c = client((_) async => _json({}));
        const none = PairingAuth();
        expect(
          (await c.approve(none, linkId: 'L', grantManage: false)).error,
          PairingError.unauthorized,
        );
        expect((await c.revoke(none, 'd')).error, PairingError.unauthorized);
        expect(
          (await c.setManage(none, 'd', manage: true)).error,
          PairingError.unauthorized,
        );
        expect(requests, isEmpty);
      },
    );
  });

  group('asking', () {
    final now = DateTime(2026, 10, 8, 12);
    final ticket = LinkTicket(
      linkId: 'L1',
      pollSecret: 'secret-1',
      qrPayload: 'hideip://link?v=1&id=L1',
      code: '7KQM-3XHP',
      expiresAt: now.add(const Duration(minutes: 10)),
    );

    test('start sends v2 and its own kind and keeps the code', () async {
      final c = client(
        (_) async => _json({
          'link_id': 'L1',
          'poll_secret': 'secret-1',
          'qr_payload': 'hideip://link?v=1&id=L1',
          'code': '7KQM-3XHP',
          'expires_in': 600,
          'v': 2,
        }),
        now: () => now,
      );
      final r = await c.start(kind: 'tablet', name: 'iPad', platform: 'ios');
      expect(r.ticket!.code, '7KQM-3XHP');
      expect(r.ticket!.expiresAt, now.add(const Duration(minutes: 10)));
      expect(body(requests.single), {
        'v': 2,
        'kind': 'tablet',
        'name': 'iPad',
        'platform': 'ios',
      });
    });

    test('a start answered without a code is the first protocol', () async {
      final c = client(
        (_) async => _json({
          'link_id': 'L1',
          'poll_secret': 's',
          'qr_payload': 'hideip://link?v=1&id=L1',
          'expires_in': 300,
        }),
      );
      expect(
        (await c.start(kind: 'phone', name: 'x')).error,
        LinkStartError.unsupported,
      );
    });

    test('start failures', () async {
      expect(
        (await client(
          (_) async => _detail(429, 'too_many_attempts'),
        ).start(kind: 'phone', name: 'x')).error,
        LinkStartError.tooManyAttempts,
      );
      expect(
        (await client(
          (_) async => throw http.ClientException('x'),
        ).start(kind: 'phone', name: 'x')).error,
        LinkStartError.network,
      );
    });

    test('poll reads every state, and the secret goes in the body', () async {
      final answers = <http.Response, LinkPollStatus>{
        _json({'status': 'pending', 'expires_in': 30}): LinkPollStatus.pending,
        _json({'status': 'delivered'}): LinkPollStatus.delivered,
        _detail(404, 'unknown_link'): LinkPollStatus.unknown,
        _detail(410, 'link_expired'): LinkPollStatus.expired,
        _detail(410, 'link_cancelled'): LinkPollStatus.cancelled,
        _detail(410, 'device_revoked'): LinkPollStatus.revoked,
        _detail(410, 'subscription_inactive'): LinkPollStatus.inactive,
        _detail(429, 'too_many_attempts'): LinkPollStatus.tooManyAttempts,
        http.Response('', 502): LinkPollStatus.network,
        _json({'status': 'approved'}): LinkPollStatus.network,
      };
      for (final e in answers.entries) {
        final r = await client((_) async => e.key).poll(ticket);
        expect(r.status, e.value, reason: e.key.body);
      }
      expect(body(requests.last), {
        'v': 2,
        'link_id': 'L1',
        'poll_secret': 'secret-1',
      });
      expect(
        requests.every((r) => !r.url.toString().contains('secret')),
        isTrue,
      );
    });

    test(
      'an approved poll carries the credentials, permissions and time',
      () async {
        final r = await client(
          (_) async => _json({
            'status': 'approved',
            'device': {
              'id': 'dev_new',
              'kind': 'phone',
              'name': 'Android phone',
            },
            'device_token': 'tok-new',
            'permissions': {'use': true, 'manage': true},
            'credentials': {'sub_url': 'https://api.test/v1/sub/dev_new'},
            'account': {
              'active': true,
              'expires_ms': 1767225600000,
              'device_limit': 8,
            },
            'delivery_expires_in': 870,
          }),
        ).poll(ticket);
        final h = r.handoff!;
        expect(r.status, LinkPollStatus.approved);
        expect(h.deviceToken, 'tok-new');
        expect(h.deviceId, 'dev_new');
        expect(h.manage, isTrue);
        expect(h.subUrl, 'https://api.test/v1/sub/dev_new');
        expect(h.deviceLimit, 8);
        expect(h.expires, DateTime.fromMillisecondsSinceEpoch(1767225600000));
        // It survives being written down and read back.
        final again = LinkHandoff.fromPollJson(h.toJson())!;
        expect(again.deviceToken, h.deviceToken);
        expect(again.subUrl, h.subUrl);
        expect(again.manage, isTrue);
        expect(again.expires, h.expires);
      },
    );

    test('ack and cancel tell their answers apart', () async {
      final cases = {
        _json({'ok': true}): LinkCloseResult.ok,
        _detail(404, 'unknown_link'): LinkCloseResult.unknown,
        _detail(409, 'not_approved'): LinkCloseResult.notApproved,
        _detail(409, 'already_delivered'): LinkCloseResult.alreadyDelivered,
        http.Response('', 500): LinkCloseResult.network,
      };
      for (final e in cases.entries) {
        expect(await client((_) async => e.key).ack(ticket), e.value);
      }
      await client((_) async => _json({'ok': true})).cancel(ticket);
      expect(requests.last.url.path, '/v1/link/cancel');
      expect(body(requests.last), {'link_id': 'L1', 'poll_secret': 'secret-1'});
    });

    test('refresh reads a device that lost its time or was removed', () async {
      var reply = _json({'active': false, 'reason': 'subscription_inactive'});
      final c = client((_) async => reply);
      final off = await c.refresh('tok');
      expect(off.active, isFalse);
      expect(off.reason, 'subscription_inactive');
      reply = _json({
        'active': true,
        'credentials': {'sub_url': 'https://api.test/v1/sub/dev_new'},
        'permissions': {'use': true, 'manage': false},
        'device': {'id': 'dev_new', 'kind': 'phone', 'name': 'x'},
      });
      final on = await c.refresh('tok');
      expect(on.subUrl, 'https://api.test/v1/sub/dev_new');
      expect(on.manage, isFalse);
      reply = http.Response('', 500);
      expect((await c.refresh('tok')).active, isNull);
    });
  });

  group('device rows', () {
    test('a TV and a tablet stay what they are in the first list too', () {
      final list = parseDevices(
        jsonEncode({
          'devices': [
            _row('a', kind: 'tv'),
            _row('b', kind: 'tablet', manage: true, current: true),
            {'id': 'c', 'kind': 'phone', 'name': 'c'},
          ],
        }),
      )!;
      expect(list.map((d) => d.kindLabel), ['TV', 'Tablet', 'Phone']);
      final tablet = AccountDevice.fromLinked(list[1]);
      expect(tablet.kind, DeviceKind.tablet);
      expect(tablet.manage, isTrue);
      expect(tablet.current, isTrue);
      final old = AccountDevice.fromLinked(list[2], current: true);
      expect(old.manage, isNull);
      expect(old.current, isTrue);
      expect(AccountDevice.fromJson(_row('t', kind: 'tv'))!.kindLabel, 'TV');
    });

    test('codes are normalized and checked against the alphabet', () {
      expect(normalizePairingCode(' 7kqm-3xhp '), '7KQM3XHP');
      expect(pairingCodeCharsValid('7KQM3XHP'), isTrue);
      expect(pairingCodeCharsValid('7KQM3XH0'), isFalse);
      expect(displayPairingCode('7KQM3XHP'), '7KQM-3XHP');
      expect(kindCanManage(DeviceKind.tv), isFalse);
      expect(kindCanManage(DeviceKind.tablet), isTrue);
    });
  });
}
