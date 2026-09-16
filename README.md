# hideip.net

A small, no-account VPN client. It runs a [sing-box](https://github.com/SagerNet/sing-box)
core inside a system tunnel (a `VpnService` on Android, a packet tunnel
extension on iOS) and connects to servers you bring yourself, imported from a
share link, a QR code, a config file or a subscription URL. Both the Android
and the iOS app are built from this repo.

There is no sign-up and no telemetry. Profiles live on the device. The point is
to be a clean, auditable front end for a proxy core you already trust, not a
managed service.

## Features

- Imports `vless://`, `vmess://`, `ss://`, `trojan://`, `hysteria2://`,
  `tuic://`, `anytls://`, `socks://`, `http(s)://` and `wireguard://` links,
  WireGuard `.conf` files, and subscription URLs or files in plain, base64,
  Clash YAML or sing-box JSON form.
- VLESS over Reality with `xtls-rprx-vision`, Shadowsocks (with ShadowTLS),
  Trojan, VMess and the rest, all handled by the sing-box core. WireGuard runs
  as a sing-box endpoint.
- QR import that works on devices without Google Play Services (uses ZXing
  directly, so it decodes on GrapheneOS and other de-Googled ROMs too).
- A foreground tunnel with an ongoing notification, a Disconnect action, and
  live up/down traffic counters. Kill switch and Android Always-on support.
- Server latency check before you connect, search over the server list,
  server renaming.
- Public IP readout with country and network, from hideip.net's own endpoint,
  so you can confirm the tunnel actually changed your exit IP.
- A world map of exit locations. Tapping a country that has no node yet casts
  an anonymous vote (just the country code, no identifiers) for where to build
  next; the contract is in [docs/voting-api.md](docs/voting-api.md).
- Optional Premium locations, with Speed mode (WireGuard, falling back to the
  stealth profile where it is blocked) and linked devices: one subscription
  shared with a browser extension or another client, approved from the phone.
- Profiles and keys encrypted at rest; Android backups disabled so a restore
  cannot clone the device identity.
- Light, dark and system themes.

## Download

- **Google Play**: <https://play.google.com/store/apps/details?id=net.hideip.vpn>
- **App Store**: <https://apps.apple.com/app/id6793134083>
- **GitHub Releases**: <https://github.com/dataprimehk/hideip.net-app/releases>

Every tagged release carries two APKs. Take the `arm64-v8a` one on any phone
from the last several years; `armeabi-v7a` is only for older 32-bit devices.

### Verify what you downloaded

Each release also ships `SHA256SUMS.txt`. Put it next to the APK and run:

```sh
sha256sum --ignore-missing -c SHA256SUMS.txt
```

On macOS the command is `shasum -a 256 --ignore-missing -c SHA256SUMS.txt`.

The GitHub APKs are signed with the same release key on every release, so a new
build installs straight over the previous one and your profiles stay put. You
can check the signing certificate yourself:

```sh
apksigner verify --print-certs hideip.net-1.1.1-arm64-v8a.apk
```

It must print:

```
Signer #1 certificate DN: CN=Dataprime LTD, O=Dataprime LTD, L=Hong Kong, C=HK
Signer #1 certificate SHA-256 digest: 8980ca20cb32bd32e90cbb7bd66bfd42da291dd724386a593626192969ac3ae8
```

Google Play ships its own copy of the app, re-signed by Play App Signing, so a
Play install and a GitHub install carry different signatures and will not
update over one another. Pick one source and stay with it.

### Obtainium

If you use [Obtainium](https://github.com/ImranR98/Obtainium), add

```
https://github.com/dataprimehk/hideip.net-app
```

as a source. It tracks the GitHub releases and offers each new version as soon
as it is tagged.

## Build

You need the Flutter SDK (Dart 3.12+) and the Android SDK.

```sh
flutter pub get
flutter run            # debug, on a connected device
flutter build apk      # release APK
flutter build appbundle
```

The sing-box core is a build artifact, not committed, and the app build does
not download it. Build it once from the pinned source with

```sh
scripts/build-libbox.sh --all     # or --android / --ios
```

The script needs the exact Go version recorded in `native-core/source.env`,
plus the Android NDK for the AAR and a full Xcode installation for the iOS
framework. It verifies the sing-box commit, the module checksums and
`govulncheck` before installing `android/app/libs/libbox.aar` and
`ios/Frameworks/Libbox.xcframework`. `scripts/verify-libbox-artifacts.sh`
checks the installed artifacts against `native-core/verified-1.1.1.txt`.

Android release builds need `android/key.properties` pointing at a signing
keystore; without it the release task fails instead of signing with the debug
key. Debug builds need no key.

The launcher icons are generated from `assets/icon/` with:

```sh
dart run flutter_launcher_icons
```

### Project layout

- `lib/core/` parsing, sing-box config generation, encrypted profile storage,
  subscriptions, the signed catalog, WireGuard (Speed mode and imports),
  device linking, voting, IP and ping helpers.
- `lib/state/` the app state and the connection flow.
- `lib/ui/redesign/` the screens (home with the world map, locations, server
  details, import and QR scan, linked devices, Premium, onboarding, settings)
  and the shared widget kit.
- `lib/vpn_controller.dart` the Dart side of the `MethodChannel`.
- `android/.../HideipVpnService.kt` the `VpnService`, the kill switch and the
  foreground notification.
- `android/.../MainActivity.kt` the native bridge: VPN consent, the Android
  13+ notification permission and the sensitive clipboard.
- `ios/PacketTunnel/` the network extension that runs the core on iOS.
- `native-core/` the pinned inputs and the verification record for the
  sing-box core build.
- `docs/` the voting and app-events API contracts.

## Permissions

| Permission | Why |
| --- | --- |
| `INTERNET`, `ACCESS_NETWORK_STATE` | network access |
| `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_SPECIAL_USE` | keep the tunnel alive |
| `POST_NOTIFICATIONS` | the ongoing connection notification (optional; declining it still lets the tunnel run) |
| `CAMERA` | scanning a server QR code (only used on the scan screen) |

## License

GPLv3. See [LICENSE](LICENSE). sing-box is licensed separately under GPLv3 by
its authors.
