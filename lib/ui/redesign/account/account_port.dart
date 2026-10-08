/// What the Account screen reads and asks for, and nothing else.
///
/// [AccountPort] is the account half of `AppState` (CONTRACT-V2, V6) as the
/// screen uses it; [PairingPort] is device pairing v2. Until the state layer
/// provides both itself through [AccountUiHost], [AppStateAccountPort] and
/// [LegacyPairingPort] read the 1.2.0 `AppState` as it is.
library;

import 'package:flutter/foundation.dart';

import '../../../core/account_service.dart';
import '../../../core/premium.dart';
import '../../../state/app_state.dart';
import '../shell.dart' show kPlansAvailable;
import 'account_device.dart';
import 'pairing_port.dart';

/// The account as the last status call saw it: its devices, and how many
/// it may have. The limit comes from the server, never a constant here.
@immutable
class AccountOverview {
  final AccountResult result;

  /// Null when the answer carried no readable list, which is not the same
  /// as an empty one.
  final List<AccountDevice>? devices;
  final int deviceLimit;

  const AccountOverview(
    this.result, {
    this.devices,
    this.deviceLimit = AccountService.defaultDeviceLimit,
  });

  AccountOverview withDevices(List<AccountDevice>? next) =>
      AccountOverview(result, devices: next, deviceLimit: deviceLimit);
}

abstract interface class AccountPort {
  /// Fires when anything below may read differently.
  Listenable get changes;

  // --- Reading -------------------------------------------------------------

  /// An account is kept on this device (V6 `accountSignedIn`).
  bool get signedIn;

  /// The number itself is kept here (`accountNumberKnown`).
  bool get numberKnown;

  /// The number, canonical, or null when it is not kept here. A secret.
  String? get number;

  /// The number used last, for a one-tap sign-in after signing out.
  String? get lastNumber;
  String? get deviceId;
  DateTime? get expires;
  bool get active;
  bool get deviceSignedOut;
  AccountIssue? get issue;

  /// The device may list and remove devices, add one, get a new number and
  /// delete the number (`accountCanManage`).
  bool get canManage;

  /// The device holds the token pairing approves with (`canLinkDevices`).
  bool get canLinkDevices;

  /// A store subscription may be offered on this build and device
  /// (`kPlansAvailable && plansOffered`).
  bool get plansOffered;

  /// Premium is on here right now, from whatever source.
  bool get premiumOn;

  /// Premium here comes from the account number, not a store subscription.
  bool get premiumFromAccount;

  bool get storeLinked;
  String? get storeName;
  DateTime? get storeRenews;
  bool get storeLinkedElsewhere;
  bool get hasStoreEntitlement;
  bool get storeEntitlementLive;

  /// A number a store purchase has just made, until it has been seen.
  String? get freshNumber;
  void ackFreshNumber();

  // --- Asking --------------------------------------------------------------

  /// The account status, asked of the server. Null when there was no answer.
  Future<AccountOverview?> refresh({bool force = false});
  Future<AccountSignIn> signIn(String digits);
  Future<AccountResult> removeDevice(String deviceId);
  Future<AccountRotate> rotate({required bool revokeDevices});
  Future<void> signOut();
  Future<AccountResult> deleteNumber();
  void toast(String message);
}

/// What the state layer implements once it serves both ports itself. Until
/// then the screens fall back to the adapters below.
abstract interface class AccountUiHost {
  AccountPort get accountPort;
  PairingPort get pairingPort;
}

AccountPort accountPortOf(AppState state) => state.accountPort;

PairingPort pairingPortOf(AppState state) => state.pairingPort;

/// The 1.2.0 `AppState`, read through [AccountPort]. Every member is a
/// straight pass-through; nothing is kept here.
class AppStateAccountPort implements AccountPort {
  final AppState state;
  AppStateAccountPort(this.state);

  @override
  Listenable get changes => state;
  @override
  bool get signedIn => state.accountSignedIn;
  @override
  bool get numberKnown => state.accountNumberKnown;
  @override
  String? get number => state.accountNumber;
  @override
  String? get lastNumber => state.lastAccountNumber;
  @override
  String? get deviceId => state.accountDeviceId;
  @override
  DateTime? get expires => state.accountExpires;
  @override
  bool get active => state.accountActive;
  @override
  bool get deviceSignedOut => state.accountDeviceSignedOut;
  @override
  AccountIssue? get issue => state.accountIssue;
  @override
  bool get canManage => state.accountCanManage;
  @override
  bool get canLinkDevices => state.canLinkDevices;
  @override
  bool get plansOffered => kPlansAvailable && state.plansOffered;
  @override
  bool get premiumOn => state.premium.isOn;
  @override
  bool get premiumFromAccount => state.premium.source == PremiumSource.account;
  @override
  bool get storeLinked => state.storeLinked;
  @override
  String? get storeName => state.storeName;
  @override
  DateTime? get storeRenews => state.storeRenews;
  @override
  bool get storeLinkedElsewhere => state.storeLinkedElsewhere;
  @override
  bool get hasStoreEntitlement => state.hasStoreEntitlement;
  @override
  bool get storeEntitlementLive => state.storeEntitlementLive;
  @override
  String? get freshNumber => state.freshAccountNumber;
  @override
  void ackFreshNumber() => state.ackFreshAccountNumber();

  @override
  Future<AccountOverview?> refresh({bool force = false}) async {
    final status = await state.refreshAccount(force: force);
    if (status == null) return null;
    final own = state.accountDeviceId;
    return AccountOverview(
      status.result,
      devices: status.devices
          ?.map((d) => AccountDevice.fromLinked(d, current: d.id == own))
          .toList(growable: false),
      deviceLimit: status.deviceLimit,
    );
  }

  @override
  Future<AccountSignIn> signIn(String digits) =>
      state.signInWithAccountNumber(digits);
  @override
  Future<AccountResult> removeDevice(String deviceId) =>
      state.removeAccountDevice(deviceId);
  @override
  Future<AccountRotate> rotate({required bool revokeDevices}) =>
      state.rotateAccountNumber(revokeDevices: revokeDevices);
  @override
  Future<void> signOut() => state.signOutAccount();
  @override
  Future<AccountResult> deleteNumber() => state.deleteAccountNumber();
  @override
  void toast(String message) => state.showToast(message);
}
