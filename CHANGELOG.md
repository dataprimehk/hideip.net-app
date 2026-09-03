# Changelog

Notable changes to the hideip.net app. The same history is published at
https://hideip.net/apps/changelog.

## 1.1.1 (unreleased)

Build 7. iOS 15 or later.

### Security
- The sing-box core is rebuilt with Go 1.26.6 and updated golang.org/x/crypto
  (v0.56.0), x/mod (v0.40.0), x/net (v0.58.0) and x/text (v0.41.0). This
  closes the eight advisories govulncheck reported as reachable in the 1.1.0
  core: GO-2026-6355 and GO-2026-6354 in x/crypto, and GO-2026-6218,
  GO-2026-6091, GO-2026-6090, GO-2026-6089, GO-2026-5972 and GO-2026-5026 in
  the Go standard library. It also removes GO-2026-6180 and GO-2026-6179 in
  x/mod, which the binary scan matched at module level; the source scan
  never found a call path to them. The build script now prints the
  govulncheck report when a scan fails, and CI keeps the reports as an
  artifact.

### Added
- Edit an imported server in place. The detail screen has an Edit config row
  that reopens the importer on the original WireGuard file or link; saving
  keeps the server's position, name and location.
- Swipe a server row to the left, on Home and on Locations, to reach Edit and
  Delete. The row stops on the two buttons whatever the length of the swipe;
  Delete asks first. hideip.net rows do not move.
- Imported servers get a readable name. When the link or file carries none,
  the app suggests the city and country of the address, shows it in a name
  field before saving, and numbers a second server in the same place (#2, #3).
- Pick a server's location. The detail screen has a Location row with a
  country list and a city field for when the lookup got it wrong or the
  address gives nothing away.
- Hold the address on the Home screen for the details the lookup knows: city,
  country and network, with a Copy button.
- A Privacy screen under Settings that says exactly what the three one-time
  usage signals carry, with the switch at the bottom.

### Changed
- iOS 15 or later is required, up from 14.
- Home search matches the protocol, the host, the provider handle and the name
  the user typed, not only the city and country. Every word of the query has
  to match.
- The Home screen folds to one line while the search field is in use, so the
  results have the height, even with large text and the keyboard up.
- The whole address row on Home copies the address, not only the icon.
- Coming next on Locations is folded by default; the header shows the count.
- hideip.net servers carry a small tag where they sit beside imported ones.
- Settings section headers carry an icon.
- Haptics: one light pulse when the tunnel goes down, a click when the address
  is copied. The connect pulse no longer fires when the app opens on a tunnel
  that Always-on had kept up.

## 1.1.0 (2026-09-02)

Build 6 on Google Play and the App Store. iOS 14 or later.

### Added
- Speed mode for Premium: WireGuard on the hideip.net locations. The phone
  generates its own keypair and registers only the public key, up to five
  devices per subscription. Off by default. When the WireGuard handshake does
  not complete, which is what a network that blocks WireGuard looks like, the
  app switches back to the stealth profile on its own.
- Bring your own WireGuard, free: paste an `[Interface]`/`[Peer]` config, open
  a `.conf` file, scan it as a QR code, or use a `wireguard://` or `wg://` link.
  The tunnel MTU is capped at 1280. A config whose `AllowedIPs` does not cover
  the default route is refused instead of tunneling part of the traffic.
- Open file on the import screen: a WireGuard config, a subscription file,
  Clash YAML or sing-box JSON, minified or not.
- Linked devices: a phone that holds a Premium subscription can approve a
  browser extension or another client by scanning its pairing code or opening
  a `hideip://link` URL, and can hand out a short code for clients without a
  camera. Settings lists the linked devices and revokes any of them.
- Search on the home screen, filtering every list including locked locations.
- Recent servers lead the home list, and a server can be renamed.
- Country and network operator next to the public IP, from hideip.net's own
  `/v1/ip` endpoint.
- Import links on `https://hideip.net/import` and `/add`, registered as app
  links on both platforms, next to the `hideip://` scheme sellers already use.
  A link only prefills the import screen; nothing is added until you press
  the button.
- Copy config on the server details, with UUIDs, passwords, keys, tokens and
  subscription URLs redacted. The full config is available behind a
  confirmation, on a clipboard entry that expires after a minute.
- Three theme modes: light, dark and system.
- Notifications section in Settings: the system permission is asked only after
  an in-app explanation, and Android gets two channels (connection alerts,
  voting updates) so each can be silenced on its own. Nothing is posted to
  them in this release.
- Offline state on the home screen, cancel while connecting, and a sheet that
  explains a slow or failed connection.

### Changed
- Every screen redesigned: home, locations, import, settings, world map,
  Premium and onboarding, with sheets instead of Material dialogs. Motion is
  reduced when the system asks for it.
- The world map shows the vote quota and its reset date, lets you withdraw a
  vote, and marks the location that won.
- The QR scanner opens inline on the import screen, with a camera note before
  the system permission prompt.
- The first Connect raises the VPN consent on its own. The notification
  permission has its own moment in Settings or after the first vote, and the
  connect timers start once the consent is answered.
- JetBrains Mono ships as one variable font, so addresses, prices and the IP
  chip draw at the weight the design asks for. The static cuts in 1.0.0 drew
  every weight as Regular.
- New launcher icon on both platforms.
- The sing-box core (v1.13.12) is built from pinned source by
  `scripts/build-libbox.sh` instead of being pulled from JitPack. The recipe,
  the inputs and the SHA-256 of every output are in `native-core/`, and a
  workflow runs the same build on CI.
- Android release builds fail when the upload key is not configured, instead
  of signing with the debug key.
- iOS 14.0 is the minimum, up from 13.0, for the file picker.

### Fixed
- A subscription URL that answered 404 or 410 after a renewal dropped every
  Premium server while the store went on charging. The app now re-provisions
  once from the stored purchase proof, and reports the subscription as
  expired only when the backend refuses that proof.
- The VPN consent and the notification permission were raised together on the
  first Connect, and the 25 second connect timer could fail the attempt while
  the consent was still on screen.
- A link that opened the app on a cold start was handled twice.
- A hideip.net import link pasted or scanned into the importer was fetched as
  a subscription URL. It is now unwrapped.
- A crash in the vote sync when two votes drained at the same time.
- The Always-on VPN notice after a disconnect was the last Material dialog on
  the redesigned screens.

### Security
- Profiles, subscription URLs and the WireGuard keypair are encrypted at rest
  with AES-GCM; the keys live in the Android Keystore or the iOS Keychain. The
  Android service keeps its last tunnel config in an encrypted vault and
  migrates the plain file on first read. The iOS packet tunnel sets file
  protection on its config and keeps it out of backups.
- Android cloud backup and device-to-device transfer are disabled. A restored
  backup would clone the WireGuard device identity onto a second phone.
- Subscription and catalog fetches go through a bounded HTTP client: the host
  is resolved first and refused when it points at a loopback, private,
  link-local or metadata address; the TLS socket is pinned to the checked
  address; redirects repeat the check and cannot downgrade to plain HTTP;
  bodies stop at 2 MB; compressed responses are refused.
- The subscription parser stops at 500 profiles, 1000 entries and 32 levels of
  nesting, never echoes the input in an error, and runs off the UI isolate.
- An import link may only carry a payload the parser itself accepts; anything
  else is refused with a plain toast that does not repeat it.
- Premium servers can come from a signed catalog: Ed25519 signature, an epoch
  that only moves forward, a 512 KB ceiling, and no client User-Agent on the
  mirror requests. A release build without the production verification key
  skips the catalog and uses the subscription URL.
- The sing-box core is built from a recorded commit with a pinned Go
  toolchain, `go mod verify` and `govulncheck` on source and binaries.

### Privacy
- No third-party lookups. 1.0.0 asked ipify for the public IP and a
  geolocation service about imported servers; both now go to hideip.net's own
  `/v1/ip`, which already sees the same address during provisioning. Hostnames
  are resolved on the phone, so only an address leaves it.
- Three anonymous counters, each sent once per install: first open, first
  imported profile, first successful connection. The request carries the event
  name and the platform and nothing else, and a switch under Settings, Privacy
  turns it off. The contract is in `docs/app-events-api.md`. The stores' "no
  data collected" declarations stay accurate.

## 1.0.0 (2026-08-03)

First public release. Android on Google Play on 2026-08-03, iOS on the App
Store on 2026-08-11.

### Added
- Imports of `vless://` (Reality, `xtls-rprx-vision`), `vmess://`, `ss://`
  (with the ShadowTLS plugin as a chained outbound), `trojan://`,
  `hysteria2://`, `tuic://`, `anytls://`, `socks://` and `http(s)://` links.
- Subscription URLs: plain and base64 line lists, Clash YAML and sing-box JSON.
  Subscriptions refresh on launch, a re-import replaces the group instead of
  duplicating it, and the provider's plan status (traffic, expiry, panel link)
  is read from the `subscription-userinfo` headers.
- QR scan through ZXing, so it works on phones without Google Play Services.
- `hideip://` links, so a seller panel can open the importer with a payload.
- The sing-box core in an Android `VpnService` and in an iOS packet tunnel
  extension, with the TUN MTU at 1280.
- Latency check for every server before connecting.
- Public IP readout on the home screen.
- Kill switch: the tunnel is recovered instead of leaking when it drops.
- Android Always-on VPN: reconnect on system starts when opted in, with a
  notice while the system holds traffic.
- Foreground notification with a Disconnect action and traffic counters.
- World map home with anonymous country voting: the country code and nothing
  else, queued offline and synced later. The contract is in
  `docs/voting-api.md`.
- Premium locations: monthly and yearly plans through StoreKit 2 on iOS and
  Play Billing on Android, provisioned anonymously from the purchase proof.
  Shown only where the plans catalog is live.
- Dark mode and onboarding.
- Release builds ship arm64-v8a and armeabi-v7a only; analyze and tests run on
  CI.
