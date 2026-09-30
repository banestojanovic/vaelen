#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/run"

cat > "$tmp/bin/security" <<'SECURITY'
#!/usr/bin/env bash
cat <<'IDENTITIES'
  1) BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB "Apple Development: expected"
  2) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Apple Development: other team"
  2 valid identities found
IDENTITIES
SECURITY

cat > "$tmp/bin/codesign" <<'CODESIGN'
#!/usr/bin/env bash
if [[ "${1:-}" == --force ]]; then exit 0; fi
case "$2" in
  */BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB.app) team=EXPECTEDTEAM01 ;;
  */AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA.app) team=OTHERTEAM00001 ;;
  *) echo "unexpected signing probe: $*" >&2; exit 2 ;;
esac
printf 'Identifier=dev.vaelen.app\nTeamIdentifier=%s\n' "$team"
CODESIGN
chmod +x "$tmp/bin/security" "$tmp/bin/codesign"

source "$repo_root/Scripts/vaelen-dev"
PATH="$tmp/bin:$PATH"
export PATH
selected="$(select_signing_identity "$tmp/run" EXPECTEDTEAM01)"
[[ "$selected" == $'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB\tEXPECTEDTEAM01' ]] || {
  echo "configured team identity was not selected: $selected" >&2
  exit 1
}
[[ ! -e "$tmp/run/signing-probes" ]] || { echo 'signing probe fixture was not cleaned' >&2; exit 1; }
echo 'Vaelen signing identity selection tests: PASS'
