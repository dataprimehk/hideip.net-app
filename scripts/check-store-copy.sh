#!/usr/bin/env bash
set -euo pipefail
root="${STORE_COPY_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$root"
pattern='t\.me|telegram|stars|stripe|crypto|bitcoin|monero|usdt|hideip\.net/premium|buy online|checkout|discount|cheaper|redeem|license key|promo code|coupon|voucher'
# The work order requires protocol identifiers which also occur in its copy
# blacklist. Keep these exact source lines auditable; no UI file is exempt.
# TODO(filip): Confirm the technical-only exceptions to the store copy blacklist.
hits="$(grep -rniIE "$pattern" lib/ assets/ || true)"
filtered="$(printf '%s\n' "$hits" | python3 -c '
import re, sys
imports = {"lib/core/" + name for name in ["catalog.dart", "wg_keys.dart", "secret_prefs.dart"]}
allowed = {}
for line in sys.stdin:
 line = line.rstrip("\n")
 if not line: continue
 parts = line.split(":", 2)
 if len(parts) != 3: print(line); continue
 path, _, code = parts
 code = code.strip()
 if path in imports and re.fullmatch(r"import '\''package:cryptography/cryptography\.dart'\'';", code): continue
 if code in allowed.get(path, set()): continue
 print(line)
')"
if [[ -n "$filtered" ]]; then
  printf '%s\n' "$filtered" >&2
  exit 1
fi
echo 'Store copy checks passed.'
