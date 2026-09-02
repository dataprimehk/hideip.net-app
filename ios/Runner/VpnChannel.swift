import Flutter
import NetworkExtension
import UIKit

/// Bridges Flutter <-> NETunnelProviderManager, the iOS counterpart of
/// MainActivity.kt.
///
/// Channel: net.hideip.vpn/control
///   prepare() -> saves the VPN profile; the first save shows the system
///                consent dialog. Returns true when allowed.
///   isPrepared() -> whether an enabled profile is already saved. Never
///                saves, so it never raises the consent dialog.
///   start(config, label) -> starts the PacketTunnel extension with the
///                sing-box config JSON
///   stop() -> stops the tunnel
///   status() -> {running, error}
///   stats() -> live traffic counters written by the extension
final class VpnChannel: NSObject {
    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "net.hideip.vpn/control", binaryMessenger: registrar.messenger())
        let instance = VpnChannel()
        channel.setMethodCallHandler { call, result in
            instance.handle(call, result: result)
        }
    }

    private var manager: NETunnelProviderManager?
    private let defaults = UserDefaults(suiteName: TunnelShared.appGroup)

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "prepare": prepare(result)
        case "isPrepared": isPrepared(result)
        case "start": start(call, result)
        case "stop": stop(result)
        case "status": status(result)
        case "stats": stats(result)
        case "setKillSwitch": setKillSwitch(call, result)
        case "setSensitiveClipboard": setSensitiveClipboard(call, result)
        default: result(FlutterMethodNotImplemented)
        }
    }

    private func setSensitiveClipboard(
        _ call: FlutterMethodCall, _ result: @escaping FlutterResult
    ) {
        guard let args = call.arguments as? [String: Any?],
              let text = args["text"] as? String, !text.isEmpty
        else {
            result(FlutterError(
                code: "no_clipboard_text", message: "text is required", details: nil))
            return
        }
        let requested = (args["ttlMs"] as? NSNumber)?.doubleValue ?? 60_000
        let ttl = min(max(requested, 5_000), 300_000) / 1_000
        DispatchQueue.main.async {
            UIPasteboard.general.setItems(
                [["public.utf8-plain-text": text]],
                options: [
                    .localOnly: true,
                    .expirationDate: Date().addingTimeInterval(ttl),
                ])
            result(true)
        }
    }

    /// Answers on the main thread; NetworkExtension completions arrive on
    /// arbitrary queues and Flutter results must not.
    private func answer(_ result: @escaping FlutterResult, _ value: Any?) {
        DispatchQueue.main.async { result(value) }
    }

    // MARK: - prepare

    private func prepare(_ result: @escaping FlutterResult) {
        loadManager { manager in
            if let manager, manager.isEnabled {
                self.answer(result, true)
                return
            }
            // No profile yet (or another VPN disabled ours): (re)save it. The
            // first save is what shows the system "Allow VPN" dialog, so a
            // denial surfaces here as an error, which the app treats like a
            // cancelled consent on Android.
            let target = manager ?? Self.makeManager()
            target.isEnabled = true
            target.saveToPreferences { error in
                if error != nil {
                    self.answer(result, false)
                    return
                }
                // Reload after save; starting a freshly saved profile without
                // a reload is a known NetworkExtension failure.
                target.loadFromPreferences { _ in
                    self.manager = target
                    self.answer(result, true)
                }
            }
        }
    }

    // MARK: - isPrepared

    /// Reads the existing consent without asking for it, the counterpart of
    /// `VpnService.prepare(context) == null` on Android, so Dart can tell
    /// "never asked" apart from "refused". A profile another VPN app disabled
    /// counts as not prepared: prepare() would have to save again, and that
    /// save is what shows the system sheet.
    private func isPrepared(_ result: @escaping FlutterResult) {
        loadManager { manager in
            self.answer(result, manager?.isEnabled == true)
        }
    }

    private static func makeManager() -> NETunnelProviderManager {
        let manager = NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = TunnelShared.providerBundleId
        // Cosmetic; iOS shows it in Settings. The real server lives in the
        // sing-box config passed per start.
        proto.serverAddress = "hideip.net"
        manager.protocolConfiguration = proto
        manager.localizedDescription = "hideip.net"
        return manager
    }

    private func loadManager(_ completion: @escaping (NETunnelProviderManager?) -> Void) {
        if let manager {
            completion(manager)
            return
        }
        NETunnelProviderManager.loadAllFromPreferences { managers, _ in
            let mine = managers?.first {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerBundleIdentifier == TunnelShared.providerBundleId
            }
            self.manager = mine
            completion(mine)
        }
    }

    // MARK: - kill switch

    /// The iOS kill switch is a property of the saved VPN profile, not of the
    /// running tunnel: on-demand rules make the system redial whenever a
    /// network is available, so a dropped tunnel comes back without the app.
    /// includeAllNetworks would add strict blocking on top, but on this
    /// packetFlow/gvisor stack it kills the tunnel's own traffic (system
    /// shows VPN up, nothing flows) — verified on device — so it stays off.
    private func setKillSwitch(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        let enabled = (call.arguments as? [String: Any?])?["enabled"] as? Bool ?? false
        defaults?.set(enabled, forKey: TunnelShared.keyKillSwitch)
        loadManager { manager in
            guard let manager else {
                // No profile yet; start() arms it once prepare has made one.
                self.answer(result, true)
                return
            }
            self.applyKillSwitch(enabled, to: manager) { _ in
                self.answer(result, true)
            }
        }
    }

    private func applyKillSwitch(
        _ enabled: Bool, to manager: NETunnelProviderManager,
        completion: @escaping (Error?) -> Void
    ) {
        manager.isOnDemandEnabled = enabled
        manager.onDemandRules = enabled ? [NEOnDemandRuleConnect()] : nil
        // Make sure profiles saved by the build that set this are healed.
        manager.protocolConfiguration?.includeAllNetworks = false
        manager.saveToPreferences { error in
            guard error == nil else {
                completion(error)
                return
            }
            // Reload after save, same as prepare(): acting on a freshly saved
            // profile without a reload is a known NetworkExtension failure.
            manager.loadFromPreferences { _ in completion(nil) }
        }
    }

    // MARK: - start / stop

    private func start(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any?],
              let config = args["config"] as? String, !config.isEmpty
        else {
            result(FlutterError(code: "no_config", message: "config is required", details: nil))
            return
        }
        loadManager { manager in
            guard let manager else {
                self.answer(result, FlutterError(
                    code: "no_profile", message: "VPN profile missing; call prepare first",
                    details: nil))
                return
            }
            let launch = {
                // A stale error from the previous session would trip the
                // status poll right after this start.
                self.defaults?.removeObject(forKey: TunnelShared.keyLastError)
                do {
                    try manager.connection.startVPNTunnel(options: [
                        TunnelShared.optionConfig: config as NSString,
                    ])
                    self.answer(result, true)
                } catch {
                    self.answer(result, FlutterError(
                        code: "start_failed", message: error.localizedDescription, details: nil))
                }
            }
            // Re-arm the kill switch if a manual disconnect disarmed it (see
            // stop()), or arm it for the first time on a fresh profile.
            let wanted = self.defaults?.bool(forKey: TunnelShared.keyKillSwitch) ?? false
            if wanted != manager.isOnDemandEnabled {
                self.applyKillSwitch(wanted, to: manager) { _ in launch() }
            } else {
                launch()
            }
        }
    }

    private func stop(_ result: @escaping FlutterResult) {
        loadManager { manager in
            guard let manager else {
                self.answer(result, true)
                return
            }
            if manager.isOnDemandEnabled {
                // With on-demand armed, iOS would redial the moment we hang
                // up; a user-requested disconnect must disarm first. The next
                // start() re-arms from the stored choice.
                manager.isOnDemandEnabled = false
                manager.saveToPreferences { _ in
                    manager.connection.stopVPNTunnel()
                    self.answer(result, true)
                }
            } else {
                manager.connection.stopVPNTunnel()
                self.answer(result, true)
            }
        }
    }

    // MARK: - status / stats

    private func status(_ result: @escaping FlutterResult) {
        loadManager { manager in
            // The Dart layer only knows running/not; report the transient
            // states as running so the optimistic connect isn't flipped back
            // by the first poll while the extension is still booting. A boot
            // failure lands as disconnected plus lastError a poll later.
            let running: Bool
            switch manager?.connection.status {
            case .connected, .connecting, .reasserting: running = true
            default: running = false
            }
            self.answer(result, [
                "running": running,
                "error": self.defaults?.string(forKey: TunnelShared.keyLastError) as Any,
            ])
        }
    }

    private func stats(_ result: @escaping FlutterResult) {
        func value(_ key: String) -> Int64 {
            defaults.map { Int64($0.integer(forKey: key)) } ?? 0
        }
        answer(result, [
            "uplink": value(TunnelShared.keyUplink),
            "downlink": value(TunnelShared.keyDownlink),
            "uplinkTotal": value(TunnelShared.keyUplinkTotal),
            "downlinkTotal": value(TunnelShared.keyDownlinkTotal),
        ])
    }
}
