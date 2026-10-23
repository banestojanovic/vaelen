#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
UPDATER="$ROOT/Scripts/vaelen-dev-update"
DEV="$ROOT/Scripts/vaelen-dev"

grep -Fq 'APPLICATIONS="$HOME/Applications"' "$UPDATER"
grep -Fq 'CANONICAL="$APPLICATIONS/Vaelen.app"' "$UPDATER"
grep -Fq 'STAGED_APP="$APPLICATIONS/.Vaelen.candidate-$STAMP.app"' "$UPDATER"
grep -Fq 'OLD_APP="$APPLICATIONS/Vaelen.previous-$STAMP.app"' "$UPDATER"
grep -Fq 'LEGACY="/Applications/Vaelen.app"' "$UPDATER"
grep -Fq 'LEGACY_GUI="$LEGACY/Contents/MacOS/Vaelen"' "$UPDATER"
grep -Fq 'LEGACY_CORE="$LEGACY/Contents/Resources/vaelend"' "$UPDATER"
grep -Fq 'multiple or unrecognized GUI/Core owners are running' "$UPDATER"
grep -Fq 'process_count_for_bundle_executable' "$UPDATER"
process_helpers_source="$(sed -n '/^process_pid_for_command() {/,/^}/p; /^process_count_for_command() {/,/^}/p; /^process_count_for_bundle_executable() {/,/^}/p' "$UPDATER")"
eval "$process_helpers_source"
canonical_gui="/Users/test user/Applications/Vaelen.app/Contents/MacOS/Vaelen"
legacy_gui="/Applications/Vaelen.app/Contents/MacOS/Vaelen"
process_command_output="$canonical_gui
$canonical_gui
$legacy_gui
/other/Vaelen.app/Contents/MacOS/Vaelen
${canonical_gui}Extra"
process_pid_output="  101 $canonical_gui
  105 $canonical_gui
  102 $legacy_gui
  103 /other/Vaelen.app/Contents/MacOS/Vaelen
  104 ${canonical_gui}Extra"
ps() {
  case "$*" in
    *'pid=,comm='*) printf '%s\n' "$process_pid_output" ;;
    *) printf '%s\n' "$process_command_output" ;;
  esac
}
[[ "$(process_count_for_command "$canonical_gui")" == 2 ]] || exit 1
[[ "$(process_count_for_command "$legacy_gui")" == 1 ]] || exit 1
[[ "$(process_pid_for_command "$canonical_gui")" == 101 ]] || exit 1
[[ "$(process_pid_for_command "$legacy_gui")" == 102 ]] || exit 1
[[ -z "$(process_pid_for_command "/Users/test user/Applications/Vaelen.app/Contents/MacOS/VaelenX")" ]] || exit 1
[[ "$(process_count_for_bundle_executable "/Vaelen.app/Contents/MacOS/Vaelen")" == 4 ]] || exit 1
grep -Fq 'if [[ ! -e "$APPLICATIONS" && ! -L "$APPLICATIONS" ]]; then' "$UPDATER"
grep -Fq 'mkdir "$APPLICATIONS" || die "could not create home Applications directory"' "$UPDATER"
grep -Fq 'real directory owned by the current user' "$UPDATER"
bootstrap_line="$(grep -nF 'if [[ ! -e "$APPLICATIONS" && ! -L "$APPLICATIONS" ]]; then' "$UPDATER" | cut -d: -f1)"
mkdir_line="$(grep -nF 'mkdir "$APPLICATIONS" || die "could not create home Applications directory"' "$UPDATER" | cut -d: -f1)"
guard_line="$(grep -nF 'real directory owned by the current user' "$UPDATER" | cut -d: -f1)"
app_check_line="$(grep -nF '[[ -d "$CANONICAL" && -f "$STATE_DB" ]]' "$UPDATER" | cut -d: -f1)"
(( bootstrap_line < mkdir_line && mkdir_line < guard_line && guard_line < app_check_line ))
! grep -Fq 'with administrator privileges' "$UPDATER"
grep -Fq 'CANONICAL_APP="$HOME/Applications/Vaelen.app"' "$DEV"
grep -Fq 'CANONICAL_APP="$HOME/Applications/Vaelen.app"' "$ROOT/Tests/VaelenDevProcessOwnershipTests.sh"
grep -Fq 'HOME/Applications/Vaelen.app' "$ROOT/Scripts/install-cli.sh"
grep -Fq '/ "Applications/Vaelen.app/Contents/Resources/Vaelen_VaelenCore.bundle/Contents/Resources"' "$ROOT/Scripts/prepare-bundled-php.py"
echo 'per-user app update contract: PASS'
