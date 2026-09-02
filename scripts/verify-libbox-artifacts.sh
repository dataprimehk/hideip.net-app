#!/bin/sh
# Verify that installed native artifacts are the reviewed 1.1.1 build outputs.
set -eu

REPO_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
RECORD="$REPO_DIR/native-core/verified-1.1.1.txt"
AAR="$REPO_DIR/android/app/libs/libbox.aar"
XCFRAMEWORK="$REPO_DIR/ios/Frameworks/Libbox.xcframework"
MODE=${1:---all}

case "$MODE" in
  --all) REQUIRED_INPUTS="$RECORD $AAR $XCFRAMEWORK" ;;
  --android) REQUIRED_INPUTS="$RECORD $AAR" ;;
  *)
    echo "Usage: $0 [--all|--android]" >&2
    exit 64
    ;;
esac

for REQUIRED in $REQUIRED_INPUTS; do
  if [ ! -e "$REQUIRED" ]; then
    echo "Missing native verification input: $REQUIRED" >&2
    exit 1
  fi
done

VERIFY_ROOT=$(mktemp -d /tmp/hideip-libbox-verify.XXXXXX)
cleanup() {
  case "$VERIFY_ROOT" in
    /tmp/hideip-libbox-verify.*) rm -rf "$VERIFY_ROOT" ;;
    *) echo "Refusing to clean unexpected path: $VERIFY_ROOT" >&2 ;;
  esac
}
trap cleanup EXIT HUP INT TERM
unzip -q "$AAR" -d "$VERIFY_ROOT/aar"

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

expected_hash() {
  sed -n "s/^$1=//p" "$RECORD"
}

verify_hash() {
  KEY=$1
  FILE=$2
  EXPECTED=$(expected_hash "$KEY")
  ACTUAL=$(sha256_file "$FILE")
  if [ -z "$EXPECTED" ] || [ "$ACTUAL" != "$EXPECTED" ]; then
    echo "SHA-256 mismatch for $KEY: expected $EXPECTED, found $ACTUAL" >&2
    exit 1
  fi
}

verify_hash android_aar_sha256 "$AAR"
verify_hash android_arm64-v8a_libbox_sha256 "$VERIFY_ROOT/aar/jni/arm64-v8a/libbox.so"
verify_hash android_armeabi-v7a_libbox_sha256 "$VERIFY_ROOT/aar/jni/armeabi-v7a/libbox.so"
verify_hash android_x86_libbox_sha256 "$VERIFY_ROOT/aar/jni/x86/libbox.so"
verify_hash android_x86_64_libbox_sha256 "$VERIFY_ROOT/aar/jni/x86_64/libbox.so"
if [ "$MODE" = "--all" ]; then
  verify_hash apple_ios_arm64_libbox_sha256 \
    "$XCFRAMEWORK/ios-arm64/Libbox.framework/Versions/A/Libbox"
  verify_hash apple_simulator_arm64_x86_64_libbox_sha256 \
    "$XCFRAMEWORK/ios-arm64_x86_64-simulator/Libbox.framework/Versions/A/Libbox"
fi

echo "All reviewed hideip.net 1.1.1 native artifact hashes match."
