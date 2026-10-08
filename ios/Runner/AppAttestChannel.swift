import DeviceCheck
import Flutter
import Foundation

/// App Attest for the free location's key, the iOS counterpart of the proof
/// of work Android does in Dart. DeviceCheck only, no third-party SDK.
///
/// Channel: net.hideip.vpn/app_attest
///   isSupported() -> Bool
///   generateKey() -> String, the key id Apple returns (base64)
///   attestKey(keyId: String, clientDataHash: FlutterStandardTypedData)
///       -> String, the attestation object (base64)
///
/// Nothing is stored here. Dart asks for a fresh key per registration and
/// keeps neither the key id nor the attestation.
final class AppAttestChannel: NSObject {
    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "net.hideip.vpn/app_attest", binaryMessenger: registrar.messenger())
        let instance = AppAttestChannel()
        channel.setMethodCallHandler { call, result in
            instance.handle(call, result: result)
        }
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "isSupported":
            result(DCAppAttestService.shared.isSupported)
        case "generateKey":
            generateKey(result)
        case "attestKey":
            attestKey(call, result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func generateKey(_ result: @escaping FlutterResult) {
        guard DCAppAttestService.shared.isSupported else {
            result(FlutterError(code: "unsupported", message: nil, details: nil))
            return
        }
        DCAppAttestService.shared.generateKey { keyId, error in
            DispatchQueue.main.async {
                if let keyId = keyId, error == nil {
                    result(keyId)
                } else {
                    result(FlutterError(code: "generate_failed", message: nil, details: nil))
                }
            }
        }
    }

    private func attestKey(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard DCAppAttestService.shared.isSupported else {
            result(FlutterError(code: "unsupported", message: nil, details: nil))
            return
        }
        guard let args = call.arguments as? [String: Any],
              let keyId = args["keyId"] as? String, !keyId.isEmpty,
              let hash = args["clientDataHash"] as? FlutterStandardTypedData,
              hash.data.count == 32
        else {
            result(FlutterError(code: "bad_arguments", message: nil, details: nil))
            return
        }
        DCAppAttestService.shared.attestKey(keyId, clientDataHash: hash.data) { object, error in
            DispatchQueue.main.async {
                if let object = object, error == nil {
                    result(object.base64EncodedString())
                } else {
                    result(FlutterError(code: "attest_failed", message: nil, details: nil))
                }
            }
        }
    }
}
