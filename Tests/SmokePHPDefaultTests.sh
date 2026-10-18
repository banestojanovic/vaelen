#!/usr/bin/env bash
# Focused test: smoke's PHP readiness check uses the authoritative current
# default, never a hardcoded version. An undeterminable default resolves empty
# so the check fails instead of verifying the wrong runtime.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/val-default" <<'VAL'
#!/usr/bin/env bash
printf 'PHP runtimes\nDefault: 8.4.24 · Running: 8.3.33, 8.4.24\n'
VAL
cat > "$tmp/val-nodefault" <<'VAL'
#!/usr/bin/env bash
printf 'PHP runtimes\nDefault: —\n'
VAL
chmod +x "$tmp/val-default" "$tmp/val-nodefault"

source "$ROOT/Scripts/vaelen-dev"

VAL="$tmp/val-default"
got="$(smoke_php_default_version)"
[[ "$got" == "8.4.24" ]] || { echo "FAIL: expected authoritative default 8.4.24, got '$got'" >&2; exit 1; }

VAL="$tmp/val-nodefault"
got="$(smoke_php_default_version)"
[[ -z "$got" ]] || { echo "FAIL: expected empty default when none is set, got '$got'" >&2; exit 1; }

echo "SmokePHPDefaultTests: PASS"
