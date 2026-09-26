#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/val" <<'VAL'
#!/usr/bin/env bash
case "$*" in
  'php status 8.4.23'|'mysql status'|'routing status'|'dns status'|'ports status')
    echo 'State      healthy'; echo 'Health     healthy';;
  'mailpit status') echo 'State      stopped'; echo 'Health     unavailable';;
  *) echo "unexpected val call: $*" >&2; exit 3;;
esac
VAL
chmod +x "$tmp/val"
cat > "$tmp/intents.json" <<'JSON'
{"php:8.4.23":true,"mysql":true,"caddy":true,"mailpit":false,"dns":true,"standard-ports":true}
JSON
mkdir -p "$tmp/support/state"
cp "$tmp/intents.json" "$tmp/support/state/service-intents.json"

source "$ROOT/Scripts/vaelen-dev"
VAL="$tmp/val"
SUPPORT="$tmp/support"
VAELEN_READINESS_TIMEOUT=1
VAELEN_READINESS_INTERVAL=0.01
export VAL SUPPORT VAELEN_READINESS_TIMEOUT VAELEN_READINESS_INTERVAL

pass="$(wait_for_enabled_services)"
grep -q 'php:8.4.23 healthy' <<< "$pass"
grep -q 'standard-ports healthy' <<< "$pass"
! grep -q 'mailpit' <<< "$pass"

cat > "$tmp/val" <<'VAL'
#!/usr/bin/env bash
echo 'State      stopped'
echo 'Health     unavailable'
VAL
chmod +x "$tmp/val"
if wait_for_enabled_services >"$tmp/out" 2>"$tmp/err"; then
  echo 'expected readiness timeout' >&2; exit 1
fi
grep -q 'TIMEOUT service=php:8.4.23' "$tmp/err"
grep -q 'last-observed="State      stopped; Health     unavailable"' "$tmp/err"
grep -Eq 'elapsed=[0-9.]+s' "$tmp/err"
echo 'Harness readiness tests: PASS'
