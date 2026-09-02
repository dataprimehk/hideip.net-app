# Native core recipe for hideip.net 1.1.1

Android and iOS use the same official sing-box `v1.13.12` source commit,
Go toolchain, dependency backport, and gomobile generator. The immutable inputs
are recorded in `source.env` and `backport-modules.txt`.

Build both release artifacts from the repository root:

```sh
export ANDROID_HOME="$HOME/Library/Android/sdk"
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
scripts/build-libbox.sh --all
```

The build fails unless the local Go version exactly matches the pinned version.
It also fails if the tag no longer resolves to the recorded full commit, a
backported module resolves to another version, `go mod verify` fails, source
`govulncheck` reports a reachable vulnerability, or binary `govulncheck` finds
an untriaged vulnerability in any Android ABI.

`GO-2026-5932` has no fixed `x/crypto` version because it marks the legacy
OpenPGP package itself as unsafe by design. Go binary scanning conservatively
reports that module even though source scanning finds no call path. The recipe
accepts only that exact binary-only result, and only after verifying that no
`golang.org/x/crypto/openpgp` package is present in the Android package graph.
Every other source or binary finding fails the build.

Generated outputs are intentionally not committed:

- `android/app/libs/libbox.aar`
- `ios/Frameworks/Libbox.xcframework`
- `build/native-core/` module lists, vulnerability reports, and SHA-256 records

The app build consumes only those local artifacts. It does not fall back to the
opaque third-party JitPack AAR. Keep `source.env`, the dependency manifest, this
recipe, and the corresponding source available with distributed GPLv3 builds.

Before packaging the reviewed 1.1.1 release candidate, verify that the installed
artifacts still match `verified-1.1.1.txt`:

```sh
scripts/verify-libbox-artifacts.sh
```
