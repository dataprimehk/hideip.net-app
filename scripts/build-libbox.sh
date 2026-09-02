#!/bin/sh
# Build the Android AAR and iOS XCFramework from one verified source graph.
set -eu

REPO_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
. "$REPO_DIR/native-core/source.env"

MODULE_MANIFEST="$REPO_DIR/native-core/backport-modules.txt"
ANDROID_TARGET="$REPO_DIR/android/app/libs/libbox.aar"
APPLE_TARGET="$REPO_DIR/ios/Frameworks/Libbox.xcframework"
REPORT_DIR="$REPO_DIR/build/native-core"
COMMON_TAGS=with_gvisor,with_quic,with_wireguard,with_utls,with_clash_api,badlinkname,tfogo_checklinkname0
ANDROID_TAGS=$COMMON_TAGS
APPLE_TAGS=$COMMON_TAGS,with_dhcp,grpcnotrace
MODE=${1:---all}

case "$MODE" in
  --all|--android|--ios|--verify-source) ;;
  *)
    echo "Usage: $0 [--all|--android|--ios|--verify-source]" >&2
    exit 64
    ;;
esac

if [ ! -f "$MODULE_MANIFEST" ]; then
  echo "Missing dependency manifest: $MODULE_MANIFEST" >&2
  exit 1
fi

ACTUAL_GO=$(go env GOVERSION)
if [ "$ACTUAL_GO" != "$GO_VERSION" ]; then
  echo "Go toolchain mismatch: expected $GO_VERSION, found $ACTUAL_GO" >&2
  exit 1
fi
export GOTOOLCHAIN=local

BUILD_ROOT=$(mktemp -d /tmp/hideip-libbox.XXXXXX)
SOURCE_DIR="$BUILD_ROOT/sing-box"
TOOLS_DIR="$BUILD_ROOT/tools"
OUTPUT_DIR="$BUILD_ROOT/output"
mkdir -p "$TOOLS_DIR" "$OUTPUT_DIR" "$REPORT_DIR"

cleanup() {
  case "$BUILD_ROOT" in
    /tmp/hideip-libbox.*) rm -rf "$BUILD_ROOT" ;;
    *) echo "Refusing to clean unexpected path: $BUILD_ROOT" >&2 ;;
  esac
}
trap cleanup EXIT HUP INT TERM

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$SING_BOX_TAG" \
  https://github.com/SagerNet/sing-box.git "$SOURCE_DIR"
ACTUAL_COMMIT=$(git -C "$SOURCE_DIR" rev-parse HEAD)
if [ "$ACTUAL_COMMIT" != "$SING_BOX_COMMIT" ]; then
  echo "sing-box commit mismatch: expected $SING_BOX_COMMIT, found $ACTUAL_COMMIT" >&2
  exit 1
fi

cd "$SOURCE_DIR"
while IFS=' ' read -r MODULE VERSION EXTRA; do
  if [ -z "$MODULE" ]; then
    continue
  fi
  if [ -z "$MODULE" ] || [ -z "$VERSION" ] || [ -n "${EXTRA:-}" ]; then
    echo "Invalid dependency manifest line: $MODULE $VERSION ${EXTRA:-}" >&2
    exit 1
  fi
  go mod edit -require="$MODULE@$VERSION"
done < "$MODULE_MANIFEST"
go mod tidy
go mod verify

while IFS=' ' read -r MODULE VERSION EXTRA; do
  if [ -z "$MODULE" ]; then
    continue
  fi
  RESOLVED=$(go list -m -f '{{.Path}} {{.Version}}' "$MODULE")
  if [ "$RESOLVED" != "$MODULE $VERSION" ]; then
    echo "Dependency mismatch: expected $MODULE $VERSION, found $RESOLVED" >&2
    exit 1
  fi
done < "$MODULE_MANIFEST"

GOBIN="$TOOLS_DIR" go install "golang.org/x/vuln/cmd/govulncheck@$GOVULNCHECK_VERSION"
GOBIN="$TOOLS_DIR" go install github.com/sagernet/gomobile/cmd/gomobile \
  github.com/sagernet/gomobile/cmd/gobind
export PATH="$TOOLS_DIR:$PATH"

"$TOOLS_DIR/govulncheck" -version > "$REPORT_DIR/govulncheck-version.txt"
"$TOOLS_DIR/govulncheck" -tags="$ANDROID_TAGS" ./experimental/libbox \
  > "$REPORT_DIR/govulncheck-source-android.txt" || {
    cat "$REPORT_DIR/govulncheck-source-android.txt" >&2
    echo "Source govulncheck found a reachable vulnerability for the Android tags" >&2
    exit 1
  }
"$TOOLS_DIR/govulncheck" -tags="$APPLE_TAGS" ./experimental/libbox \
  > "$REPORT_DIR/govulncheck-source-apple.txt" || {
    cat "$REPORT_DIR/govulncheck-source-apple.txt" >&2
    echo "Source govulncheck found a reachable vulnerability for the Apple tags" >&2
    exit 1
  }
GOOS=android GOARCH=arm64 CGO_ENABLED=1 \
  go list -deps -tags="$ANDROID_TAGS" ./experimental/libbox |
  LC_ALL=C sort > "$REPORT_DIR/android-packages.txt"
if grep -q '^golang.org/x/crypto/openpgp\($\|/\)' "$REPORT_DIR/android-packages.txt"; then
  echo "Unmaintained x/crypto/openpgp code is reachable in the Android package graph" >&2
  exit 1
fi
go list -m all | LC_ALL=C sort > "$REPORT_DIR/modules.txt"

LD_FLAGS="-X github.com/sagernet/sing-box/constant.Version=$SING_BOX_TAG -X internal/godebug.defaultGODEBUG=multipathtcp=0 -s -w -buildid= -checklinkname=0"

build_android() {
  if [ -z "${ANDROID_HOME:-}" ] || [ ! -d "$ANDROID_HOME" ]; then
    echo "ANDROID_HOME must point to an installed Android SDK" >&2
    exit 1
  fi
  ANDROID_NDK_HOME=${ANDROID_NDK_HOME:-"$ANDROID_HOME/ndk/$ANDROID_NDK_VERSION"}
  if [ ! -f "$ANDROID_NDK_HOME/source.properties" ]; then
    echo "Pinned Android NDK $ANDROID_NDK_VERSION is not installed" >&2
    exit 1
  fi
  ACTUAL_NDK=$(sed -n 's/^Pkg.Revision[[:space:]]*=[[:space:]]*//p' \
    "$ANDROID_NDK_HOME/source.properties")
  if [ "$ACTUAL_NDK" != "$ANDROID_NDK_VERSION" ]; then
    echo "Android NDK mismatch: expected $ANDROID_NDK_VERSION, found $ACTUAL_NDK" >&2
    exit 1
  fi
  export ANDROID_NDK_HOME
  "$TOOLS_DIR/gomobile" bind -o "$OUTPUT_DIR/libbox.aar" \
    -target android -androidapi "$ANDROID_API" \
    -javapkg=io.nekohasekai -libname=box \
    -trimpath -buildvcs=false -ldflags "$LD_FLAGS" \
    -tags "$ANDROID_TAGS" ./experimental/libbox

  mkdir -p "$OUTPUT_DIR/aar"
  unzip -q "$OUTPUT_DIR/libbox.aar" -d "$OUTPUT_DIR/aar"
  : > "$REPORT_DIR/govulncheck-android-binaries.txt"
  find "$OUTPUT_DIR/aar/jni" -type f -name libbox.so -print | LC_ALL=C sort |
    while IFS= read -r BINARY; do
      ABI=$(basename "$(dirname "$BINARY")")
      ABI_REPORT="$OUTPUT_DIR/govulncheck-$ABI.txt"
      echo "ABI $ABI" >> "$REPORT_DIR/govulncheck-android-binaries.txt"
      if "$TOOLS_DIR/govulncheck" -mode=binary "$BINARY" > "$ABI_REPORT"; then
        cat "$ABI_REPORT" >> "$REPORT_DIR/govulncheck-android-binaries.txt"
      else
        FOUND_IDS=$(sed -n 's/^Vulnerability #[0-9][0-9]*: \(GO-[0-9-][0-9-]*\)$/\1/p' "$ABI_REPORT" |
          LC_ALL=C sort -u)
        if [ "$FOUND_IDS" != "GO-2026-5932" ]; then
          cat "$ABI_REPORT" >&2
          echo "Unexpected binary vulnerability in Android ABI $ABI" >&2
          exit 1
        fi
        cat "$ABI_REPORT" >> "$REPORT_DIR/govulncheck-android-binaries.txt"
        echo "TRIAGED: binary-only module match; source scan is clean and openpgp is absent from the Android package graph." \
          >> "$REPORT_DIR/govulncheck-android-binaries.txt"
      fi
      echo >> "$REPORT_DIR/govulncheck-android-binaries.txt"
    done

  install_file "$OUTPUT_DIR/libbox.aar" "$ANDROID_TARGET"
}

build_apple() {
  if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "A full Xcode installation is required for the iOS framework" >&2
    exit 1
  fi
  ACTUAL_XCODE=$(xcodebuild -version | sed -n '1s/^Xcode //p')
  ACTUAL_XCODE_BUILD=$(xcodebuild -version | sed -n '2s/^Build version //p')
  ACTUAL_IOS_SDK=$(xcrun --sdk iphoneos --show-sdk-version)
  if [ "$ACTUAL_XCODE" != "$XCODE_VERSION" ] || \
     [ "$ACTUAL_XCODE_BUILD" != "$XCODE_BUILD" ] || \
     [ "$ACTUAL_IOS_SDK" != "$IOS_SDK_VERSION" ]; then
    echo "Apple toolchain mismatch: expected Xcode $XCODE_VERSION ($XCODE_BUILD), iOS SDK $IOS_SDK_VERSION; found Xcode $ACTUAL_XCODE ($ACTUAL_XCODE_BUILD), iOS SDK $ACTUAL_IOS_SDK" >&2
    exit 1
  fi
  "$TOOLS_DIR/gomobile" bind -target ios,iossimulator -libname=box \
    -tags-not-macos=with_low_memory -trimpath -buildvcs=false \
    -ldflags "$LD_FLAGS" -tags "$APPLE_TAGS" ./experimental/libbox
  install_directory "$SOURCE_DIR/Libbox.xcframework" "$APPLE_TARGET"
}

backup_path() {
  TARGET=$1
  if [ -e "$TARGET" ]; then
    BACKUP_DIR="$REPORT_DIR/backups/$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p "$BACKUP_DIR"
    mv "$TARGET" "$BACKUP_DIR/$(basename "$TARGET")"
  fi
}

install_file() {
  SOURCE=$1
  TARGET=$2
  mkdir -p "$(dirname "$TARGET")"
  backup_path "$TARGET"
  mv "$SOURCE" "$TARGET"
}

install_directory() {
  SOURCE=$1
  TARGET=$2
  mkdir -p "$(dirname "$TARGET")"
  backup_path "$TARGET"
  mv "$SOURCE" "$TARGET"
}

case "$MODE" in
  --all)
    build_android
    build_apple
    ;;
  --android) build_android ;;
  --ios) build_apple ;;
  --verify-source) ;;
esac

{
  echo "sing_box_tag=$SING_BOX_TAG"
  echo "sing_box_commit=$SING_BOX_COMMIT"
  echo "go_version=$ACTUAL_GO"
  echo "govulncheck_version=$GOVULNCHECK_VERSION"
  echo "gomobile_module=$(go list -m -f '{{.Version}}' github.com/sagernet/gomobile)"
  echo "android_api=$ANDROID_API"
  echo "android_ndk_version=$ANDROID_NDK_VERSION"
  echo "xcode_version=$XCODE_VERSION"
  echo "xcode_build=$XCODE_BUILD"
  echo "ios_sdk_version=$IOS_SDK_VERSION"
  echo "android_tags=$ANDROID_TAGS"
  echo "apple_tags=$APPLE_TAGS"
  echo "modules_sha256=$(sha256_file "$REPORT_DIR/modules.txt")"
  if [ -f "$ANDROID_TARGET" ]; then
    echo "android_aar_sha256=$(sha256_file "$ANDROID_TARGET")"
    unzip -q "$ANDROID_TARGET" -d "$OUTPUT_DIR/installed-aar"
    find "$OUTPUT_DIR/installed-aar/jni" -type f -name libbox.so -print | LC_ALL=C sort |
      while IFS= read -r BINARY; do
        ABI=$(basename "$(dirname "$BINARY")")
        HASH=$(sha256_file "$BINARY")
        echo "android_${ABI}_libbox_sha256=$HASH"
      done
  fi
} > "$REPORT_DIR/provenance.txt"

if [ -d "$APPLE_TARGET" ]; then
  find "$APPLE_TARGET" -type f -print | LC_ALL=C sort |
    while IFS= read -r FILE; do
      RELATIVE=${FILE#"$APPLE_TARGET"/}
      HASH=$(sha256_file "$FILE")
      echo "$HASH  $RELATIVE"
    done > "$REPORT_DIR/apple-file-sha256.txt"
fi

echo "Native core verification/build complete. Reports: $REPORT_DIR"
