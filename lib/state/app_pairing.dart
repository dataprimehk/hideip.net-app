/// Pairing v2 as the Account and Linked devices screens use it, served by
/// [AppState]: the state layer picks what this device proves itself with,
/// [PairingClient] does the asking.
library;

import '../core/account_service.dart';
import '../core/pairing.dart';
import 'app_state.dart';

/// Where this device's own request for access stands (the new device's
/// side of pairing v2).
enum LinkRequestPhase {
  /// Nothing has been asked.
  idle,

  /// This device runs on an account or on Premium already; moving it to
  /// another account needs the user's yes first.
  needsConfirm,

  /// The server has no pairing v2 (or could not be asked). The screen says
  /// so quietly; there is no code to show.
  unsupported,

  /// The QR code and the short code are up; nobody has approved yet.
  waiting,

  /// Approved and stored here; the server is being told, or the new
  /// account is going into force.
  storing,

  /// This device runs on the new account.
  done,

  /// The request lapsed, or its answer was not collected in time. A new
  /// code is the way on.
  expired,

  /// This device withdrew the request.
  cancelled,

  /// The approval was taken back before this device collected it.
  revoked,

  /// The account ran out of time before this device collected the answer.
  inactive,

  /// Too many requests from this network in a short while.
  tooManyAttempts,

  /// The request could not be opened (no answer).
  failed,
}

/// The approving half of pairing v2 for the screens. Every method answers;
/// none throws. It speaks pairing v2 only when the server does (see
/// [capabilities]); otherwise it answers [PairingError.unsupported], apart
/// from the device list and removal, which the first protocol has too.
///
/// It has the same members as `PairingPort` in the Account screen module,
/// so that interface can be put on it as it stands.
class AppPairingPort {
  final AppState _state;
  final PairingClient _client;
  AppPairingPort(this._state, this._client);

  Future<PairingCapabilities> capabilities() => _client.capabilities();

  Future<PairingPreviewResult> preview({String? linkId, String? code}) async {
    final caps = await _client.capabilities();
    if (!caps.v2) {
      return const PairingPreviewResult.failed(PairingError.unsupported);
    }
    if (_state.ownsLinkRequest(linkId: linkId, code: code)) {
      return const PairingPreviewResult.failed(PairingError.self);
    }
    final auth = _state.pairingAuth;
    if (auth == null) {
      return PairingPreviewResult.failed(_refusal());
    }
    return _client.preview(auth, linkId: linkId, code: code);
  }

  Future<PairingApproveResult> approve({
    required String linkId,
    required bool grantManage,
  }) async {
    final caps = await _client.capabilities();
    if (!caps.v2) {
      return const PairingApproveResult.failed(PairingError.unsupported);
    }
    if (_state.ownsLinkRequest(linkId: linkId)) {
      return const PairingApproveResult.failed(PairingError.self);
    }
    final auth = _state.pairingAuth;
    if (auth == null) {
      return PairingApproveResult.failed(_refusal());
    }
    final result = await _client.approve(
      auth,
      linkId: linkId,
      grantManage: grantManage,
    );
    if (result.ok && !result.already) _state.pairingChanged();
    return result;
  }

  /// The devices on the account. With a token the pairing list answers,
  /// marking this device; with the number alone the account status does,
  /// since a number never goes in a URL.
  Future<List<AccountDevice>?> devices() async {
    final auth = _state.pairingAuth;
    if (auth == null) return null;
    final token = auth.token;
    if (token != null) return _client.devices(token);
    final status = await _state.refreshAccount(force: true);
    if (status == null || status.result != AccountResult.ok) return null;
    final own = _state.accountDeviceId;
    return status.devices
        ?.map((d) => AccountDevice.fromLinked(d, current: d.id == own))
        .toList(growable: false);
  }

  Future<DeviceChangeResult> revoke(
    String deviceId, {
    bool confirmLastManager = false,
  }) async {
    final auth = _state.pairingAuth;
    if (auth == null) return DeviceChangeResult.failed(_refusal());
    final caps = await _client.capabilities();
    final DeviceChangeResult result;
    if (caps.v2) {
      result = await _client.revoke(
        auth,
        deviceId,
        confirmLastManager: confirmLastManager,
      );
    } else {
      result = await _legacyRevoke(auth, deviceId);
    }
    if (result.ok) _state.pairingChanged();
    return result;
  }

  Future<DeviceChangeResult> setManage(
    String deviceId, {
    required bool manage,
    bool confirmLastManager = false,
  }) async {
    final caps = await _client.capabilities();
    if (!caps.permissions) {
      return const DeviceChangeResult.failed(PairingError.unsupported);
    }
    final auth = _state.pairingAuth;
    if (auth == null) return DeviceChangeResult.failed(_refusal());
    final result = await _client.setManage(
      auth,
      deviceId,
      manage: manage,
      confirmLastManager: confirmLastManager,
    );
    if (result.ok) _state.pairingChanged();
    return result;
  }

  /// Removal the way a server from before pairing v2 does it: through the
  /// account when this device is on one, through the subscription token
  /// otherwise.
  Future<DeviceChangeResult> _legacyRevoke(
    PairingAuth auth,
    String deviceId,
  ) async {
    if (_state.accountSignedIn) {
      final r = await _state.removeAccountDevice(deviceId);
      return switch (r) {
        AccountResult.ok => const DeviceChangeResult.ok(),
        AccountResult.revoked => const DeviceChangeResult.failed(
          PairingError.accountRevoked,
        ),
        AccountResult.invalid || AccountResult.unknown =>
          const DeviceChangeResult.failed(PairingError.unauthorized),
        AccountResult.tooManyAttempts => const DeviceChangeResult.failed(
          PairingError.tooManyAttempts,
        ),
        _ => const DeviceChangeResult.failed(PairingError.network),
      };
    }
    final token = auth.token;
    if (token == null) {
      return const DeviceChangeResult.failed(PairingError.unauthorized);
    }
    final ok = await _state.deviceLinks.revoke(
      subToken: token,
      deviceId: deviceId,
    );
    return ok
        ? const DeviceChangeResult.ok()
        : const DeviceChangeResult.failed(PairingError.network);
  }

  /// Why this device may not manage, said without asking the server.
  PairingError _refusal() {
    if (!_state.accountSignedIn) return PairingError.unauthorized;
    if (_state.accountIssue == AccountIssue.revoked) {
      return PairingError.accountRevoked;
    }
    if (_state.accountDeviceSignedOut) return PairingError.unauthorized;
    return PairingError.notPermitted;
  }
}
