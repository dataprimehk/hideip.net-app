/// What the account and pairing screens need from device pairing v2
/// (`/v1/link/*`, pairing v2 rev 1): capabilities, preview, approve,
/// permissions and the device list with its removal. The screens talk to
/// [PairingPort] only; the HTTP client behind it belongs to the app core.
///
/// Until the core has a v2 client, [LegacyPairingPort] answers for it: it
/// says pairing v2 is not there, so no screen offers a code entry or a
/// preview that would lead nowhere, and it serves the 1.2.0 list and removal
/// through the existing [DeviceLinkService].
library;

export '../../../core/pairing.dart'
    show
        PairingCapabilities,
        PairingError,
        pairingErrorOf,
        PairingTarget,
        PairingRequest,
        PairingPreviewResult,
        PairingApproveResult,
        DeviceChangeResult,
        pairingCodeAlphabet,
        normalizePairingCode,
        pairingCodeCharsValid,
        displayPairingCode;

import '../../../core/premium.dart';
import '../../../state/app_state.dart';
import '../../../core/pairing.dart';

/// Pairing v2 as the screens see it. Every method answers; none throws.
/// The token, the account number and the request bodies (`v: 2`) are the
/// implementation's business.
abstract interface class PairingPort {
  /// K1. Cached by the implementation; never blocks long.
  Future<PairingCapabilities> capabilities();

  /// K3, by the id in a scanned QR code or by a typed code: exactly one of
  /// the two. The code goes as typed; the server normalizes it too.
  Future<PairingPreviewResult> preview({String? linkId, String? code});

  /// K4. [linkId] comes from the preview, so a typed code is spent on the
  /// preview only.
  Future<PairingApproveResult> approve({
    required String linkId,
    required bool grantManage,
  });

  /// K8: the devices on the account, or null when they could not be read.
  Future<List<AccountDevice>?> devices();

  /// K8 removal. With pairing v2, [confirmLastManager] answers the
  /// `last_manager` question (K7).
  Future<DeviceChangeResult> revoke(
    String deviceId, {
    bool confirmLastManager = false,
  });

  /// K7 `POST /v1/link/permissions`.
  Future<DeviceChangeResult> setManage(
    String deviceId, {
    required bool manage,
    bool confirmLastManager = false,
  });
}

/// The pairing a 1.2.0 core can do: the device list and its removal through
/// the subscription token, nothing of v2. Approving a scanned QR code and
/// showing a code stay in the 1.2.0 sheets of `linked_devices_screen.dart`.
class LegacyPairingPort implements PairingPort {
  final AppState state;
  LegacyPairingPort(this.state);

  @override
  Future<PairingCapabilities> capabilities() async =>
      PairingCapabilities.legacy;

  @override
  Future<PairingPreviewResult> preview({String? linkId, String? code}) async =>
      const PairingPreviewResult.failed(PairingError.unsupported);

  @override
  Future<PairingApproveResult> approve({
    required String linkId,
    required bool grantManage,
  }) async => const PairingApproveResult.failed(PairingError.unsupported);

  @override
  Future<List<AccountDevice>?> devices() async {
    final token = state.subToken;
    if (token == null) return null;
    final list = await state.deviceLinks.devices(token);
    // This phone's own entry, when it is on the list through an account
    // number; a store subscription's token is not a device of its own.
    final own = state.premium.source == PremiumSource.account
        ? state.accountDeviceId
        : null;
    return list
        ?.map((d) => AccountDevice.fromLinked(d, current: d.id == own))
        .toList(growable: false);
  }

  @override
  Future<DeviceChangeResult> revoke(
    String deviceId, {
    bool confirmLastManager = false,
  }) async {
    final token = state.subToken;
    if (token == null) {
      return const DeviceChangeResult.failed(PairingError.unauthorized);
    }
    final ok = await state.deviceLinks.revoke(
      subToken: token,
      deviceId: deviceId,
    );
    return ok
        ? const DeviceChangeResult.ok()
        : const DeviceChangeResult.failed(PairingError.network);
  }

  @override
  Future<DeviceChangeResult> setManage(
    String deviceId, {
    required bool manage,
    bool confirmLastManager = false,
  }) async => const DeviceChangeResult.failed(PairingError.unsupported);
}
