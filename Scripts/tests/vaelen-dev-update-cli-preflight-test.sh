#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
source "$ROOT/Scripts/vaelen-dev-update-cli-preflight.sh"
# Tie the isolated gate test to the production updater's ordering, so a future
# refactor cannot accidentally move shutdown or replacement ahead of it.
gate_line="$(grep -n 'vaelen_update_cli_preflight "\$CLI" "\$CLI_OWNER" "\$CLI_LINK"' "$ROOT/Scripts/vaelen-dev-update" | cut -d: -f1)"
shutdown_line="$(grep -n '^note "Requesting normal GUI shutdown"' "$ROOT/Scripts/vaelen-dev-update" | cut -d: -f1)"
stage_line="$(grep -n '^note "Staging signed candidate in \$APPLICATIONS"' "$ROOT/Scripts/vaelen-dev-update" | cut -d: -f1)"
[[ -n "$gate_line" && "$gate_line" -lt "$shutdown_line" && "$gate_line" -lt "$stage_line" ]] || { echo 'CLI gate is not before production shutdown/staging' >&2; exit 1; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cli="$tmp/val" owner="$tmp/.val.sha256" link="$tmp/link"
gui="$tmp/gui-running" app="$tmp/app-unchanged" runtime="$tmp/runtime-unchanged"
touch "$gui" "$app" "$runtime"

assert_no_mutation() {
  [[ -f "$gui" && -f "$app" && -f "$runtime" ]]
}
run_gated_update() {
  vaelen_update_cli_preflight "$cli" "$owner" "$link" || return 1
  # Stand-ins for the first updater actions after successful preflight.
  rm "$gui"
  printf changed > "$app"
  rm "$runtime"
}

# Missing CLI and malformed/incorrect ownership both fail before stubbed
# shutdown/replacement/runtime actions. The valid case reaches those actions.
if run_gated_update 2>/dev/null; then echo 'missing CLI unexpectedly passed' >&2; exit 1; fi
assert_no_mutation
printf '#!/bin/sh\nexit 0\n' > "$cli"; chmod +x "$cli"
printf '%064d\n' 0 > "$owner"
if run_gated_update 2>/dev/null; then echo 'invalid owner unexpectedly passed' >&2; exit 1; fi
assert_no_mutation
printf '#!/bin/sh\n[[ "${1:-}" == status ]]\n' > "$cli"; chmod +x "$cli"
shasum -a 256 "$cli" | awk '{print $1}' > "$owner"
ln -s "$cli" "$link"
run_gated_update
[[ ! -e "$gui" && ! -e "$runtime" && "$(cat "$app")" == changed ]]
echo 'CLI preflight failure-before-mutation and valid-path check: PASS'
