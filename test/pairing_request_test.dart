import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hideip_vpn/core/account_service.dart';
import 'package:hideip_vpn/core/account_store.dart';
import 'package:hideip_vpn/core/pairing.dart';
import 'package:hideip_vpn/core/pairing_store.dart';
import 'package:hideip_vpn/core/premium.dart';
import 'package:hideip_vpn/core/provisioning.dart';
import 'package:hideip_vpn/state/app_pairing.dart';
import 'package:hideip_vpn/state/app_state.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _numberA = '8236387788950319';
const _subA = 'https://api.test/v1/sub/dev_a';
const _subB = 'https://api.test/v1/sub/dev_b';
final _catalog = Uri.parse('https://mirror.test/catalog');

String _link(String name) =>
    'vless://11111111-1111-1111-1111-111111111111@127.0.0.1:9'
    '?security=none#$name';

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

/// The account and pairing API as pairing v2 rev 2 describes it: one
/// request at a time, approved from elsewhere when a test says so.
class _Backend {
  final requests = <http.Request>[];

  // Pairing.
  int capsStatus = 200;
  bool approved = false;
  bool manageB = false;
  String linkState = 'pending';
  String? pollError; // a 410/404 detail to answer the poll with
  int ackFailures = 0;
  int ackStatus = 200;
  bool loseNextApprovedPoll = false;
  int devicesMade = 0;
  bool ackSawStoredAnswer = false;

  // Accounts.
  bool activeB = true;
  final expires = DateTime.now().add(const Duration(days: 30));

  List<http.Request> to(String path) =>
      requests.where((r) => r.url.path == path).toList();

  Map<String, dynamic> body(http.Request r) =>
      r.body.isEmpty ? {} : jsonDecode(r.body) as Map<String, dynamic>;

  void approve({bool manage = false}) {
    approved = true;
    manageB = manage;
    if (devicesMade == 0) devicesMade = 1;
  }

  http.Client get client => MockClient((req) async {
    requests.add(req);
    final ms = expires.millisecondsSinceEpoch;
    if (req.url == _catalog) return http.Response('', 503);
    switch (req.url.toString()) {
      case _subA:
        return http.Response(
          '${_link('de-fra-01')}\n${_link('ch-zur-02')}',
          200,
        );
      case _subB:
        return activeB
            ? http.Response(_link('nl-ams-01'), 200)
            : http.Response('', 410);
    }
    switch (req.url.path) {
      case '/v1/link/capabilities':
        if (capsStatus != 200) return http.Response('', capsStatus);
        return _json({
          'pairing': 2,
          'kinds': ['phone', 'tablet', 'desktop', 'tv', 'extension'],
          'code_length': 8,
          'link_ttl_s': 600,
          'delivery_ttl_s': 900,
          'features': ['preview', 'ack', 'cancel', 'permissions', 'signout'],
        });
      case '/v1/link/start':
        return _json({
          'link_id': 'L1',
          'poll_secret': 'secret-1',
          'qr_payload': 'hideip://link?v=1&id=L1',
          'code': '7KQM-3XHP',
          'expires_in': 600,
          'v': 2,
        });
      case '/v1/link/poll':
        final b = body(req);
        if (b['poll_secret'] != 'secret-1') {
          return _json({'detail': 'unknown_link'}, 404);
        }
        final err = pollError;
        if (err != null) {
          return _json({'detail': err}, err == 'unknown_link' ? 404 : 410);
        }
        if (linkState == 'delivered') return _json({'status': 'delivered'});
        if (!approved) return _json({'status': 'pending', 'expires_in': 400});
        if (loseNextApprovedPoll) {
          loseNextApprovedPoll = false;
          throw http.ClientException('connection reset');
        }
        return _json({
          'status': 'approved',
          'device': {'id': 'dev_b', 'kind': 'phone', 'name': 'Android phone'},
          'device_token': 'tok-b',
          'permissions': {'use': true, 'manage': manageB},
          'credentials': {'sub_url': _subB},
          'account': {'active': true, 'expires_ms': ms, 'device_limit': 5},
          'delivery_expires_in': 870,
        });
      case '/v1/link/ack':
        final stored = await const PendingLinkStore().load();
        ackSawStoredAnswer = stored?.handoff?.deviceToken == 'tok-b';
        if (ackFailures > 0) {
          ackFailures--;
          return http.Response('', 502);
        }
        if (ackStatus != 200) {
          return _json({'detail': 'unknown_link'}, ackStatus);
        }
        linkState = 'delivered';
        return _json({'ok': true});
      case '/v1/link/cancel':
        linkState = 'cancelled';
        return _json({'ok': true});
      case '/v1/link/refresh':
        if (body(req)['device_token'] != 'tok-b' || !activeB) {
          return _json({'active': false, 'reason': 'subscription_inactive'});
        }
        return _json({
          'active': true,
          'credentials': {'sub_url': _subB},
          'permissions': {'use': true, 'manage': manageB},
          'device': {'id': 'dev_b', 'kind': 'phone', 'name': 'x'},
        });
      case '/v1/link/preview':
        return _json({
          'link_id': 'L9',
          'code': '7KQM-3XHP',
          'device': {
            'kind': 'tv',
            'name': 'Living room TV',
            'platform': 'android',
          },
          'expires_in': 300,
          'state': 'pending',
          'can_grant_manage': false,
          'account': {'active': true, 'devices_used': 1, 'device_limit': 5},
        });
      case '/v1/link/approve':
        return _json({
          'ok': true,
          'status': 'approved',
          'already': false,
          'device': {'id': 'dev_tv', 'kind': 'tv', 'name': 'Living room TV'},
          'permissions': {'use': true, 'manage': false},
        });
      case '/v1/link/revoke':
        return _json({'ok': true});
      case '/v1/account/signin':
        return _json({
          'active': true,
          'expires_ms': ms,
          'subscription_url': _subA,
          'device': {'id': 'dev_a', 'kind': 'phone', 'name': 'Android phone'},
          'device_token': 'tok-a',
          'device_limit': 5,
        });
      case '/v1/account/status':
        final b = body(req);
        if (b['device_token'] == 'tok-b' && b['account_number'] == null) {
          return _json({
            'active': activeB,
            'expires_ms': ms,
            'kind': 'yearly',
            'devices': manageB
                ? [
                    {'id': 'dev_a', 'kind': 'phone', 'name': 'a'},
                    {'id': 'dev_b', 'kind': 'phone', 'name': 'b'},
                  ]
                : [],
            'device_limit': 5,
            'permissions': {'use': true, 'manage': manageB},
          });
        }
        return _json({
          'active': true,
          'expires_ms': ms,
          'kind': 'yearly',
          'devices': [
            {
              'id': 'dev_a',
              'kind': 'phone',
              'name': 'a',
              'permissions': {'use': true, 'manage': true},
            },
            {'id': 'dev_tv', 'kind': 'tv', 'name': 'TV'},
          ],
          'device_limit': 5,
          'permissions': {'use': true, 'manage': true},
        });
      case '/v1/account/revoke':
        return _json({'ok': true, 'revoked': 1});
    }
    return http.Response('', 404);
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Backend backend;

  AppState fresh() => AppState(
    accounts: AccountService(client: backend.client),
    provisioning: ProvisioningService(
      client: backend.client,
      catalogSources: [_catalog],
    ),
    pairing: PairingClient(client: backend.client),
    linkPollInterval: null,
    tablet: false,
  );

  /// The same device after a restart: everything read back from storage.
  Future<AppState> restarted() async {
    final s = fresh();
    await s.loadAccountForTesting();
    await s.loadPremiumForTesting();
    await s.resumeLinkRequestForTesting();
    await pumpEventQueue();
    return s;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await PremiumSub.clear();
    await const AccountStore().clear();
    await const PendingLinkStore().clear();
    backend = _Backend();
  });

  group('a new device asks for access', () {
    test(
      'it shows a code, collects the approval, stores it, then confirms it',
      () async {
        final state = fresh();
        expect(state.linkRequestNeedsConfirm, isFalse);

        expect(await state.startLinkRequest(), LinkRequestPhase.waiting);
        expect(state.linkTicket!.code, '7KQM-3XHP');
        expect(state.linkTicket!.qrPayload, 'hideip://link?v=1&id=L1');
        final start = backend.body(backend.to('/v1/link/start').single);
        expect(start['v'], 2);
        expect(start['kind'], 'phone');
        expect(start['platform'], isNotNull);

        expect(await state.pollLinkRequest(), LinkRequestPhase.waiting);
        expect(state.premium.isOn, isFalse);

        backend.approve();
        expect(await state.pollLinkRequest(), LinkRequestPhase.done);
        await pumpEventQueue();

        // The ack went out only once the answer was on the device.
        expect(backend.ackSawStoredAnswer, isTrue);
        expect(backend.to('/v1/link/ack'), hasLength(1));
        expect(state.premium.isOn, isTrue);
        expect(state.premium.source, PremiumSource.account);
        expect(state.accountSignedIn, isTrue);
        expect(state.accountNumberKnown, isFalse);
        expect(await PremiumSub.url(), _subB);
        expect(state.profiles.where((p) => p.premium), hasLength(1));
        expect(state.linkTicket, isNull);
        expect(await const PendingLinkStore().load(), isNull);
        final stored = await const AccountStore().load();
        expect(stored!.deviceToken, 'tok-b');
        expect(stored.manage, isFalse);
      },
    );

    test(
      'a lost poll answer is collected again, and makes no second device',
      () async {
        final state = fresh();
        await state.startLinkRequest();
        backend.approve();
        backend.loseNextApprovedPoll = true;

        expect(await state.pollLinkRequest(), LinkRequestPhase.waiting);
        expect(state.premium.isOn, isFalse);
        expect(backend.to('/v1/link/ack'), isEmpty);

        expect(await state.pollLinkRequest(), LinkRequestPhase.done);
        expect(backend.devicesMade, 1);
        expect(backend.to('/v1/link/ack'), hasLength(1));
        expect(state.premium.isOn, isTrue);
      },
    );

    test(
      'a lost ack is sent again, across a restart, without a second take',
      () async {
        final first = fresh();
        await first.startLinkRequest();
        backend.approve();
        backend.ackFailures = 1;

        // Nothing to lose here, so the new account is in force already; the
        // record stays until the server has heard.
        expect(await first.pollLinkRequest(), LinkRequestPhase.storing);
        expect(first.premium.isOn, isTrue);
        expect((await const PendingLinkStore().load())!.handoff, isNotNull);

        // Asking again while the ack is lost reads the account once, not
        // on every try.
        backend.ackFailures = 2;
        final statusBefore = backend.to('/v1/account/status').length;
        expect(await first.pollLinkRequest(), LinkRequestPhase.storing);
        expect(await first.pollLinkRequest(), LinkRequestPhase.storing);
        await pumpEventQueue();
        expect(backend.to('/v1/account/status').length, statusBefore);

        final second = await restarted();
        expect(second.linkPhase, LinkRequestPhase.done);
        expect(backend.to('/v1/link/ack'), hasLength(4));
        expect(backend.to('/v1/link/poll'), hasLength(1));
        expect(await const PendingLinkStore().load(), isNull);
        expect(second.premium.isOn, isTrue);
        expect(await PremiumSub.url(), _subB);
      },
    );

    test(
      'a restart right after storing the answer finishes from the record',
      () async {
        await const PendingLinkStore().save(
          PendingLink(
            ticket: LinkTicket(
              linkId: 'L1',
              pollSecret: 'secret-1',
              qrPayload: 'hideip://link?v=1&id=L1',
              code: '7KQM-3XHP',
              expiresAt: DateTime.now().add(const Duration(minutes: 5)),
            ),
            handoff: LinkHandoff(
              deviceToken: 'tok-b',
              deviceId: 'dev_b',
              subUrl: _subB,
              manage: true,
              expires: DateTime.now().add(const Duration(days: 30)),
            ),
          ),
        );
        backend.manageB = true;
        final state = await restarted();

        expect(state.linkPhase, LinkRequestPhase.done);
        expect(backend.to('/v1/link/poll'), isEmpty);
        expect(backend.to('/v1/link/ack'), hasLength(1));
        expect(state.premium.isOn, isTrue);
        expect(state.accountCanManage, isTrue);
      },
    );

    test(
      'a request still waiting is asked about again after a restart',
      () async {
        final first = fresh();
        await first.startLinkRequest();
        backend.approve();

        final second = await restarted();
        expect(second.linkPhase, LinkRequestPhase.done);
        expect(second.premium.isOn, isTrue);
      },
    );

    test('a server without pairing v2 gets no code and no dead end', () async {
      backend.capsStatus = 404;
      final state = fresh();
      expect(await state.startLinkRequest(), LinkRequestPhase.unsupported);
      expect(backend.to('/v1/link/start'), isEmpty);
      expect(state.linkTicket, isNull);
    });

    test('a lapsed, withdrawn or out-of-time request ends cleanly', () async {
      final cases = {
        'link_expired': LinkRequestPhase.expired,
        'unknown_link': LinkRequestPhase.expired,
        'link_cancelled': LinkRequestPhase.cancelled,
        'device_revoked': LinkRequestPhase.revoked,
        'subscription_inactive': LinkRequestPhase.inactive,
      };
      for (final e in cases.entries) {
        await const PendingLinkStore().clear();
        backend = _Backend();
        final state = fresh();
        await state.startLinkRequest();
        backend.pollError = e.key;
        expect(await state.pollLinkRequest(), e.value, reason: e.key);
        expect(state.linkTicket, isNull);
        expect(await const PendingLinkStore().load(), isNull);
        expect(state.premium.isOn, isFalse);
        // A new code can be asked for straight away.
        backend.pollError = null;
        expect(await state.startLinkRequest(), LinkRequestPhase.waiting);
      }
    });

    test('cancel withdraws the request on the server too', () async {
      final state = fresh();
      await state.startLinkRequest();
      await state.cancelLinkRequest();
      await pumpEventQueue();
      expect(state.linkPhase, LinkRequestPhase.idle);
      expect(backend.body(backend.to('/v1/link/cancel').single), {
        'link_id': 'L1',
        'poll_secret': 'secret-1',
      });
      expect(await const PendingLinkStore().load(), isNull);
    });
  });

  group('moving from one account to another', () {
    test(
      'it asks first, and moves only once the new account is confirmed',
      () async {
        final state = fresh();
        await state.signInWithAccountNumber(_numberA);
        await pumpEventQueue();
        expect(state.accountNumber, _numberA);
        expect(state.linkRequestNeedsConfirm, isTrue);

        expect(await state.startLinkRequest(), LinkRequestPhase.needsConfirm);
        expect(backend.to('/v1/link/start'), isEmpty);

        expect(
          await state.startLinkRequest(confirmSwitch: true),
          LinkRequestPhase.waiting,
        );
        backend.approve();
        backend.ackFailures = 1;

        expect(await state.pollLinkRequest(), LinkRequestPhase.storing);
        // Stored, not confirmed: still on the first account.
        expect(state.accountNumber, _numberA);
        expect(await PremiumSub.url(), _subA);
        expect((await const AccountStore().load())!.deviceToken, 'tok-a');

        expect(await state.pollLinkRequest(), LinkRequestPhase.done);
        await pumpEventQueue();
        expect(state.accountNumber, isNull);
        expect(state.accountNumberKnown, isFalse);
        expect(state.lastAccountNumber, _numberA);
        expect(await PremiumSub.url(), _subB);
        expect((await const AccountStore().load())!.deviceToken, 'tok-b');
        // Its place on the first account is given back.
        final revoke = backend.to('/v1/account/revoke').single;
        expect(backend.body(revoke)['device_id'], 'dev_a');
      },
    );

    test(
      'a move the server no longer knows leaves the device where it was',
      () async {
        final state = fresh();
        await state.signInWithAccountNumber(_numberA);
        await pumpEventQueue();
        await state.startLinkRequest(confirmSwitch: true);
        backend.approve();
        backend.ackStatus = 404;

        expect(await state.pollLinkRequest(), LinkRequestPhase.expired);
        expect(state.accountNumber, _numberA);
        expect(await PremiumSub.url(), _subA);
        expect(state.premium.isOn, isTrue);
        expect(await const PendingLinkStore().load(), isNull);
      },
    );

    test('a move confirmed after a restart still goes through', () async {
      final first = fresh();
      await first.signInWithAccountNumber(_numberA);
      await pumpEventQueue();
      await first.startLinkRequest(confirmSwitch: true);
      backend.approve();
      backend.ackFailures = 1;
      await first.pollLinkRequest();
      expect(first.accountNumber, _numberA);

      final second = await restarted();
      expect(second.linkPhase, LinkRequestPhase.done);
      expect(second.accountNumber, isNull);
      expect(await PremiumSub.url(), _subB);
    });
  });

  group('permissions and recovery', () {
    test('a device without the right to manage keeps its place', () async {
      final state = fresh();
      await state.startLinkRequest();
      backend.approve(manage: false);
      await state.pollLinkRequest();
      await pumpEventQueue();

      // Its status has no device list, which is not a removal.
      await state.refreshAccount(force: true);
      expect(state.accountSignedIn, isTrue);
      expect(state.premium.isOn, isTrue);
      expect(state.accountCanManage, isFalse);
      expect(state.canLinkDevices, isFalse);
      expect(state.pairingAuth, isNull);

      final before = backend.requests.length;
      final preview = await state.pairingPort.preview(code: '7KQM-3XHP');
      expect(preview.error, PairingError.notPermitted);
      expect(
        backend.requests
            .skip(before)
            .where((r) => r.url.path == '/v1/link/preview'),
        isEmpty,
      );
    });

    test('a device given the right to manage can approve', () async {
      final state = fresh();
      await state.startLinkRequest();
      backend.approve(manage: true);
      await state.pollLinkRequest();
      await pumpEventQueue();
      expect(state.accountCanManage, isTrue);
      expect(state.canLinkDevices, isTrue);
      expect(state.pairingAuth!.token, 'tok-b');
    });

    test(
      'an added device whose time ran out comes back by its own token',
      () async {
        final state = fresh();
        await state.startLinkRequest();
        backend.approve(manage: true);
        await state.pollLinkRequest();
        await pumpEventQueue();
        expect(state.premium.isOn, isTrue);

        backend.activeB = false;
        await state.refreshAccount(force: true);
        await pumpEventQueue();
        expect(state.premium.isOn, isFalse);
        expect(state.accountSignedIn, isTrue);

        backend.activeB = true;
        await state.refreshAccount(force: true);
        await pumpEventQueue();
        expect(backend.to('/v1/link/refresh'), isNotEmpty);
        expect(state.premium.isOn, isTrue);
        expect(await PremiumSub.url(), _subB);
      },
    );
  });

  group('approving from this device', () {
    test('preview and approve go with this device token and v2', () async {
      final state = fresh();
      await state.signInWithAccountNumber(_numberA);
      await pumpEventQueue();

      final caps = await state.pairingPort.capabilities();
      expect(caps.v2, isTrue);
      final preview = await state.pairingPort.preview(code: '7kqm 3xhp');
      expect(preview.request!.device.kind, DeviceKind.tv);
      final sent = backend.body(backend.to('/v1/link/preview').single);
      expect(sent['v'], 2);
      expect(sent['token'], 'tok-a');
      expect(sent['code'], '7KQM3XHP');

      final statusBefore = backend.to('/v1/account/status').length;
      final approved = await state.pairingPort.approve(
        linkId: preview.request!.linkId,
        grantManage: false,
      );
      await pumpEventQueue();
      expect(approved.ok, isTrue);
      expect(approved.device!.kind, DeviceKind.tv);
      expect(
        backend.body(backend.to('/v1/link/approve').single)['link_id'],
        'L9',
      );
      // The device count is read again.
      expect(
        backend.to('/v1/account/status').length,
        greaterThan(statusBefore),
      );
    });

    test(
      'the account list shows a TV as a TV, with rights and this device',
      () async {
        final state = fresh();
        await state.signInWithAccountNumber(_numberA);
        await pumpEventQueue();
        final status = await state.refreshAccount(force: true);
        final rows = status!.devices!
            .map((d) => AccountDevice.fromLinked(d, current: d.id == 'dev_a'))
            .toList();
        expect(rows.map((d) => d.kind), [DeviceKind.phone, DeviceKind.tv]);
        expect(rows.first.manage, isTrue);
        expect(rows.first.current, isTrue);
        expect(status.manage, isTrue);
      },
    );

    test(
      'an old server: nothing of v2 is offered, removal still works',
      () async {
        backend.capsStatus = 404;
        final state = fresh();
        await state.signInWithAccountNumber(_numberA);
        await pumpEventQueue();

        expect(
          (await state.pairingPort.preview(linkId: 'L9')).error,
          PairingError.unsupported,
        );
        expect(
          (await state.pairingPort.setManage('dev_tv', manage: true)).error,
          PairingError.unsupported,
        );
        final removed = await state.pairingPort.revoke('dev_tv');
        expect(removed.ok, isTrue);
        expect(backend.to('/v1/link/revoke'), isEmpty);
        expect(
          backend.body(backend.to('/v1/account/revoke').single)['device_id'],
          'dev_tv',
        );
      },
    );

    test('a device does not approve its own request', () async {
      final state = fresh();
      await state.signInWithAccountNumber(_numberA);
      await pumpEventQueue();
      await state.startLinkRequest(confirmSwitch: true);

      expect(
        (await state.pairingPort.preview(code: '7kqm-3xhp')).error,
        PairingError.self,
      );
      expect(
        (await state.pairingPort.preview(linkId: 'L1')).error,
        PairingError.self,
      );
      expect(
        (await state.pairingPort.approve(
          linkId: 'L1',
          grantManage: true,
        )).error,
        PairingError.self,
      );
      expect(backend.to('/v1/link/preview'), isEmpty);
      expect(backend.to('/v1/link/approve'), isEmpty);
    });

    test('nothing is approved from a device with no account', () async {
      final state = fresh();
      expect(state.pairingAuth, isNull);
      expect(
        (await state.pairingPort.approve(
          linkId: 'L9',
          grantManage: false,
        )).error,
        PairingError.unauthorized,
      );
      expect(backend.to('/v1/link/approve'), isEmpty);
    });
  });
}
