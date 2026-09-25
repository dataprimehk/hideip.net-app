#!/usr/bin/env bash
# Fails when app copy points anywhere a purchase could happen outside the
# App Store and Google Play. Every file under the scanned roots is read line
# by line, and adjacent Dart string literals are also read joined, so a word
# split across two literals is still caught. The only exceptions are exact
# lines in exact files, listed below; no file is ever exempt as a whole.
set -euo pipefail
root="${STORE_COPY_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$root"
if [[ ! -d lib ]]; then
  echo "No lib/ directory under $root; nothing was checked." >&2
  exit 1
fi
python3 - <<'PY'
import os
import re
import sys

PATTERN = re.compile(
    r"t\.me|telegram|tg://|@hideip|stars|stripe|crypto|bitcoin|monero|usdt"
    r"|hideip\.net/(?:pay|buy|shop|premium)|\$[0-9]|\blicense\b|license key"
    r"|\bbuy (?:at|on|online|with)\b|buy online|\bon our website\b|\bby card\b"
    r"|checkout|discount|cheaper|redeem|promo code|coupon|voucher",
    re.IGNORECASE,
)

ROOTS = ["lib", "assets", "ios/Runner", "android/app/src/main/res", "CHANGELOG.md"]

CRYPTO_IMPORT = "import 'package:cryptography/cryptography.dart';"

# Exact lines that match only as code or history, never as copy: the
# cryptography package, Dart record fields and Swift closure arguments
# (`$1`), the store's own fallback prices, the StoreKit test configuration,
# and dependency names in the changelog.
ALLOWED = {
    "lib/core/catalog.dart": {CRYPTO_IMPORT},
    "lib/core/wg_keys.dart": {CRYPTO_IMPORT},
    "lib/core/secret_prefs.dart": {CRYPTO_IMPORT},
    "lib/core/premium.dart": {
        "static const yearly = PlanInfo('Yearly', r'$29.99', 'year', 'billed yearly',",
        "trial: true, perMonth: r'$2.50');",
        "PlanInfo('Monthly', r'$4.99', 'month', 'billed monthly');",
    },
    "lib/ui/redesign/import_screen.dart": {
        "_DetectBox(text: det.$1, tone: _Tone.ok)",
    },
    "lib/ui/redesign/worldmap.dart": {
        "if (pts.isNotEmpty) return fit(pts.map((p) => p.$2).toList());",
        "activeP ??= nodes.isEmpty ? null : nodes.first.$2;",
    },
    "lib/core/votes.dart": {
        "final byCount = b.$2.compareTo(a.$2);",
        "return byCount != 0 ? byCount : a.$1.compareTo(b.$1);",
    },
    "lib/core/deep_link.dart": {
        "return DeepLinkImport(split.$1, split.$2);",
    },
    "lib/core/location.dart": {
        "lat: c?.$1,",
        "lon: c?.$2,",
        "lat: pin?.$1,",
        "lon: pin?.$2,",
    },
    "lib/core/share_link_parser.dart": {
        "host = hp.$1;",
        "port = hp.$2;",
    },
    "ios/Runner/Premium.storekit": {
        '"name" : "Offer Code Redeem Sheet"',
    },
    "CHANGELOG.md": {
        "- The sing-box core is rebuilt with Go 1.26.6 and updated golang.org/x/crypto",
        "core: GO-2026-6355 and GO-2026-6354 in x/crypto, and GO-2026-6218,",
    },
    "ios/Runner/VpnChannel.swift": {
        "($0.protocolConfiguration as? NETunnelProviderProtocol)?",
        "defaults.map { Int64($0.integer(forKey: key)) } ?? 0",
    },
}

LITERAL = re.compile(r"""r?'(?:[^'\\\n]|\\.)*'|r?"(?:[^"\\\n]|\\.)*\"""")


def files():
    for top in ROOTS:
        if os.path.isfile(top):
            yield top
        elif os.path.isdir(top):
            for base, dirs, names in os.walk(top):
                dirs.sort()
                for name in sorted(names):
                    yield os.path.join(base, name)


def text_of(path):
    with open(path, "rb") as f:
        raw = f.read()
    if b"\0" in raw[:8192]:
        return None
    return raw.decode("utf-8", errors="replace")


def joined_hits(path, text):
    """Words split across adjacent string literals ('tele' 'gram')."""
    out = []
    run = []
    last_end = None
    for m in LITERAL.finditer(text):
        if run and text[last_end:m.start()].strip() == "":
            run.append(m)
        else:
            out.extend(check_run(path, text, run))
            run = [m]
        last_end = m.end()
    out.extend(check_run(path, text, run))
    return out


def check_run(path, text, run):
    if len(run) < 2:
        return []
    pieces = [m.group(0).lstrip("r")[1:-1] for m in run]
    joined = "".join(pieces)
    if not PATTERN.search(joined) or any(PATTERN.search(p) for p in pieces):
        return []
    line = text.count("\n", 0, run[0].start()) + 1
    return ["%s:%d: (joined) %s" % (path, line, joined)]


hits = []
for path in files():
    text = text_of(path)
    if text is None:
        continue
    allowed = ALLOWED.get(path, set())
    for number, line in enumerate(text.splitlines(), 1):
        if PATTERN.search(line) and line.strip() not in allowed:
            hits.append("%s:%d: %s" % (path, number, line.strip()))
    if path.endswith(".dart"):
        hits.extend(joined_hits(path, text))

if hits:
    sys.stderr.write("\n".join(hits) + "\n")
    sys.exit(1)
print("Store copy checks passed.")
PY
