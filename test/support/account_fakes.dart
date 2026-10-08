import 'package:flutter/material.dart';
import 'package:hideip_vpn/core/account_service.dart';
import 'package:hideip_vpn/state/app_state.dart';
import 'package:hideip_vpn/ui/redesign/account/account_device.dart';
import 'package:hideip_vpn/ui/redesign/account/account_port.dart';
import 'package:hideip_vpn/ui/redesign/account/pairing_port.dart';
import 'package:hideip_vpn/ui/redesign/hip_sheet.dart';
import 'package:hideip_vpn/ui/redesign/shell.dart';

const testNumber = '8236387788950319';

/// The account as a screen sees it, set by hand, every call counted.
class FakeAccountPort extends ChangeNotifier implements AccountPort {
  @override
  bool signedIn = true;
  @override
  bool numberKnown = true;
  String? _number = testNumber;
  @override
  String? get number => numberKnown ? _number : null;
  set number(String? v) => _number = v;
  @override
  String? lastNumber = testNumber;
  @override
  String? deviceId = 'dev_own';
  @override
  DateTime? expires = DateTime(2026, 11, 10);
  @override
  bool active = true;
  @override
  bool deviceSignedOut = false;
  @override
  AccountIssue? issue;
  @override
  bool canManage = true;
  @override
  bool canLinkDevices = true;
  @override
  bool plansOffered = false;
  @override
  bool premiumOn = true;
  @override
  bool premiumFromAccount = true;
  @override
  bool storeLinked = false;
  @override
  String? storeName;
  @override
  DateTime? storeRenews;
  @override
  bool storeLinkedElsewhere = false;
  @override
  bool hasStoreEntitlement = false;
  @override
  bool storeEntitlementLive = false;
  @override
  String? freshNumber;

  /// What a status call answers. Null is no answer at all.
  AccountOverview? overview = AccountOverview(
    AccountResult.ok,
    devices: sampleDevices(3),
    deviceLimit: 5,
  );

  int refreshes = 0;
  int signOuts = 0;
  int deletes = 0;
  final List<String> removed = [];
  final List<String> signIns = [];
  final List<String> toasts = [];
  AccountResult removeResult = AccountResult.ok;

  @override
  Listenable get changes => this;

  @override
  void ackFreshNumber() {
    freshNumber = null;
    notifyListeners();
  }

  @override
  Future<AccountOverview?> refresh({bool force = false}) async {
    refreshes++;
    return overview;
  }

  @override
  Future<AccountSignIn> signIn(String digits) async {
    signIns.add(digits);
    return const AccountSignIn(AccountResult.ok);
  }

  @override
  Future<AccountResult> removeDevice(String deviceId) async {
    removed.add(deviceId);
    return removeResult;
  }

  @override
  Future<AccountRotate> rotate({required bool revokeDevices}) async =>
      const AccountRotate(AccountResult.network);

  @override
  Future<void> signOut() async {
    signOuts++;
    signedIn = false;
    notifyListeners();
  }

  @override
  Future<AccountResult> deleteNumber() async {
    deletes++;
    return AccountResult.ok;
  }

  @override
  void toast(String message) => toasts.add(message);
}

/// The devices of the mockup: this phone, a browser, a laptop, then a TV
/// and a tablet.
List<AccountDevice> sampleDevices(int n, {bool withManage = false}) => [
  AccountDevice(
    id: 'dev_own',
    kind: DeviceKind.phone,
    name: 'iPhone 16 Pro',
    createdAt: DateTime(2026, 10, 6),
    manage: withManage ? true : null,
    current: true,
  ),
  AccountDevice(
    id: 'dev_chrome',
    kind: DeviceKind.extension,
    name: 'Chrome',
    createdAt: DateTime(2026, 9, 26),
    manage: withManage ? false : null,
  ),
  AccountDevice(
    id: 'dev_mac',
    kind: DeviceKind.desktop,
    name: 'MacBook Air',
    createdAt: DateTime(2026, 10, 3),
    manage: withManage ? false : null,
  ),
  AccountDevice(
    id: 'dev_tv',
    kind: DeviceKind.tv,
    name: 'Living room TV',
    createdAt: DateTime(2026, 10, 7),
    manage: withManage ? false : null,
  ),
  AccountDevice(
    id: 'dev_tab',
    kind: DeviceKind.tablet,
    name: 'iPad',
    createdAt: DateTime(2026, 10, 7),
    manage: withManage ? false : null,
  ),
].take(n).toList();

/// Pairing v2 by hand: answers are queued, calls recorded.
class FakePairingPort implements PairingPort {
  PairingCapabilities caps;
  FakePairingPort({this.caps = PairingCapabilities.legacy});

  static const v2 = PairingCapabilities(
    pairing: 2,
    kinds: {'phone', 'tablet', 'desktop', 'tv', 'extension'},
    features: {'preview', 'ack', 'cancel', 'permissions', 'signout'},
  );

  final List<({String? linkId, String? code})> previews = [];
  final List<({String linkId, bool grantManage})> approvals = [];
  final List<({String id, bool confirm})> revokes = [];
  final List<({String id, bool manage, bool confirm})> manages = [];

  PairingPreviewResult previewResult = PairingPreviewResult.ok(sampleRequest());
  final List<PairingApproveResult> approveResults = [];
  final List<DeviceChangeResult> revokeResults = [];
  final List<DeviceChangeResult> manageResults = [];
  List<AccountDevice>? deviceList = sampleDevices(3, withManage: true);

  @override
  Future<PairingCapabilities> capabilities() async => caps;

  @override
  Future<PairingPreviewResult> preview({String? linkId, String? code}) async {
    previews.add((linkId: linkId, code: code));
    return previewResult;
  }

  @override
  Future<PairingApproveResult> approve({
    required String linkId,
    required bool grantManage,
  }) async {
    approvals.add((linkId: linkId, grantManage: grantManage));
    if (approveResults.isNotEmpty) return approveResults.removeAt(0);
    return PairingApproveResult.ok(
      device: const AccountDevice(
        id: 'dev_new',
        kind: DeviceKind.tv,
        name: 'Living room TV',
      ),
      manage: grantManage,
    );
  }

  @override
  Future<List<AccountDevice>?> devices() async => deviceList;

  @override
  Future<DeviceChangeResult> revoke(
    String deviceId, {
    bool confirmLastManager = false,
  }) async {
    revokes.add((id: deviceId, confirm: confirmLastManager));
    if (revokeResults.isNotEmpty) return revokeResults.removeAt(0);
    return const DeviceChangeResult.ok();
  }

  @override
  Future<DeviceChangeResult> setManage(
    String deviceId, {
    required bool manage,
    bool confirmLastManager = false,
  }) async {
    manages.add((id: deviceId, manage: manage, confirm: confirmLastManager));
    if (manageResults.isNotEmpty) return manageResults.removeAt(0);
    return const DeviceChangeResult.ok();
  }
}

PairingRequest sampleRequest({
  DeviceKind kind = DeviceKind.tv,
  String name = 'Living room TV',
  bool active = true,
  Duration expiresIn = const Duration(seconds: 412),
}) => PairingRequest(
  linkId: 'link_abc',
  code: '7KQM-3XHP',
  device: PairingTarget(kind: kind, name: name, platform: 'android'),
  expiresIn: expiresIn,
  canGrantManage: kindCanManage(kind),
  accountActive: active,
  devicesUsed: 3,
  deviceLimit: 5,
);

/// With [sheets], sheets really open on that navigator; without, they close
/// at once with nothing chosen.
HipNav fakeNav({
  List<HipScreen>? went,
  List<HipScreen>? paywalls,
  GlobalKey<NavigatorState>? sheets,
}) => HipNav(
  go: (s, [_]) => went?.add(s),
  back: () {},
  ctx: () => null,
  showSheet: <T>(List<Widget> children) async => sheets == null
      ? null
      : showHipSheet<T>(sheets.currentContext!, children: children),
  openDetail: (_) {},
  openImport: () {},
  openImportWith: (_) {},
  openPaywall: ({required HipScreen from, String? locId}) =>
      paywalls?.add(from),
  claimBack: (_) {},
  releaseBack: (_) {},
);

/// Words that would point a user to a purchase outside the stores.
const forbiddenWords = [
  't.me',
  'telegram',
  'stars',
  'stripe',
  'crypto',
  'bitcoin',
  'monero',
  'usdt',
  'hideip.net/premium',
  'buy online',
  'checkout',
  'discount',
  'cheaper',
  'redeem',
  'license key',
  'promo code',
  'coupon',
  'voucher',
  ' bot',
];
