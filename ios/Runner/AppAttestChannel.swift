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
///   generateAssertion(keyId: String, clientDataHash: FlutterStandardTypedData)
///       -> String, the assertion object (base64)
///
/// Failures arrive as a FlutterError whose code Dart maps to its own type:
/// "unsupported", "server_unavailable" (retry with the same key),
/// "invalid_key" (the key is gone, start over), "invalid_input" and
/// "unknown".
///
/// Nothing is stored here. The key id lives in Dart, and only after the
/// server has accepted the attestation made with it.
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
        case "generateAssertion":
            generateAssertion(call, result)
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
                    result(AppAttestChannel.failure(error))
                }
            }
        }
    }

    private func attestKey(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard DCAppAttestService.shared.isSupported else {
            result(FlutterError(code: "unsupported", message: nil, details: nil))
            return
        }
        guard let input = AppAttestChannel.keyAndHash(call) else {
            result(FlutterError(code: "invalid_input", message: nil, details: nil))
            return
        }
        DCAppAttestService.shared.attestKey(input.keyId, clientDataHash: input.hash) { object, error in
            DispatchQueue.main.async {
                if let object = object, error == nil {
                    result(object.base64EncodedString())
                } else {
                    result(AppAttestChannel.failure(error))
                }
            }
        }
    }

    private func generateAssertion(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard DCAppAttestService.shared.isSupported else {
            result(FlutterError(code: "unsupported", message: nil, details: nil))
            return
        }
        guard let input = AppAttestChannel.keyAndHash(call) else {
            result(FlutterError(code: "invalid_input", message: nil, details: nil))
            return
        }
        DCAppAttestService.shared.generateAssertion(input.keyId, clientDataHash: input.hash) { object, error in
            DispatchQueue.main.async {
                if let object = object, error == nil {
                    result(object.base64EncodedString())
                } else {
                    result(AppAttestChannel.failure(error))
                }
            }
        }
    }

    /// The key id and the 32-byte client data hash both calls take, or nil
    /// when either is missing or the wrong size.
    private static func keyAndHash(_ call: FlutterMethodCall) -> (keyId: String, hash: Data)? {
        guard let args = call.arguments as? [String: Any],
              let keyId = args["keyId"] as? String, !keyId.isEmpty,
              let hash = args["clientDataHash"] as? FlutterStandardTypedData,
              hash.data.count == 32
        else {
            return nil
        }
        return (keyId, hash.data)
    }

    private static func failure(_ error: Error?) -> FlutterError {
        var code = "unknown"
        if let dcError = error as? DCError {
            switch dcError.code {
            case .serverUnavailable:
                code = "server_unavailable"
            case .invalidKey:
                code = "invalid_key"
            case .invalidInput:
                code = "invalid_input"
            case .featureUnsupported:
                code = "unsupported"
            default:
                code = "unknown"
            }
        }
        return FlutterError(code: code, message: nil, details: nil)
    }
}
