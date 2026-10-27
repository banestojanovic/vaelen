#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
UPDATER="$ROOT/Scripts/vaelen-dev-update"
DEV="$ROOT/Scripts/vaelen-dev"

grep -Fq 'HOME_ROOT="$HOME"' "$UPDATER"
grep -Fq 'APPLICATIONS="$HOME_ROOT/Applications"' "$UPDATER"
grep -Fq 'CANONICAL="$APPLICATIONS/Vaelen.app"' "$UPDATER"
grep -Fq 'STAGED_APP="$APPLICATIONS/.Vaelen.candidate-$STAMP.app"' "$UPDATER"
grep -Fq 'OLD_APP="$APPLICATIONS/Vaelen.previous-$STAMP.app"' "$UPDATER"
grep -Fq 'LEGACY="/Applications/Vaelen.app"' "$UPDATER"
grep -Fq 'LEGACY_GUI="$LEGACY/Contents/MacOS/Vaelen"' "$UPDATER"
grep -Fq 'LEGACY_CORE="$LEGACY/Contents/Resources/vaelend"' "$UPDATER"
grep -Fq 'multiple or unrecognized GUI/Core owners are running' "$UPDATER"
grep -Fq 'test mode refuses existing Vaelen GUI/Core processes' "$UPDATER"
grep -Fq 'process_count_for_bundle_executable "/Contents/MacOS/Vaelen"' "$UPDATER"
grep -Fq 'process_count_for_bundle_executable "/Contents/Resources/vaelend"' "$UPDATER"
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
[[ "$(process_count_for_bundle_executable "/Contents/MacOS/Vaelen")" == 4 ]] || exit 1
grep -Fq 'if [[ ! -e "$APPLICATIONS" && ! -L "$APPLICATIONS" ]]; then' "$UPDATER"
grep -Fq 'mkdir "$APPLICATIONS" || die "could not create home Applications directory"' "$UPDATER"
grep -Fq 'real directory owned by the current user' "$UPDATER"
configure_line="$(grep -n '^configure_paths$' "$UPDATER" | cut -d: -f1)"
bootstrap_line="$(grep -nF 'if [[ ! -e "$APPLICATIONS" && ! -L "$APPLICATIONS" ]]; then' "$UPDATER" | cut -d: -f1)"
mkdir_line="$(grep -nF 'mkdir "$APPLICATIONS" || die "could not create home Applications directory"' "$UPDATER" | cut -d: -f1)"
guard_line="$(grep -nF 'home Applications directory must be a real directory owned by the current user' "$UPDATER" | cut -d: -f1)"
app_check_line="$(grep -nF '[[ -d "$CANONICAL" && -f "$STATE_DB" ]]' "$UPDATER" | cut -d: -f1)"
(( configure_line < bootstrap_line && bootstrap_line < mkdir_line && mkdir_line < guard_line && guard_line < app_check_line )) || exit 1
grep -Fq '[[ ! -e "$OLD_APP" && ! -L "$OLD_APP" && ! -e "$STAGED_APP" && ! -L "$STAGED_APP" ]]' "$UPDATER"
! grep -Fq 'with administrator privileges' "$UPDATER"
grep -Fq 'CANONICAL_APP="$HOME/Applications/Vaelen.app"' "$DEV"
grep -Fq 'CANONICAL_APP="$HOME/Applications/Vaelen.app"' "$ROOT/Tests/VaelenDevProcessOwnershipTests.sh"
grep -Fq 'HOME/Applications/Vaelen.app' "$ROOT/Scripts/install-cli.sh"
grep -Fq '/ "Applications/Vaelen.app/Contents/Resources/Vaelen_VaelenCore.bundle/Contents/Resources"' "$ROOT/Scripts/prepare-bundled-php.py"
quit_body="$(sed -n '/^    func quitVaelen() async {/,/^    private var serviceOperationIsBusy/p' "$ROOT/App/Vaelen/Vaelen/AppModel.swift")"
invalid_guard_line="$(printf '%s\n' "$quit_body" | grep -nF 'if VaelenTestRuntimePaths.hasInvalidCoreRuntime()' | cut -d: -f1)"
terminate_line="$(printf '%s\n' "$quit_body" | grep -nF 'terminateAfterCleanQuit()' | head -n 1 | cut -d: -f1)"
return_line="$(printf '%s\n' "$quit_body" | grep -nF 'return' | head -n 1 | cut -d: -f1)"
shutdown_line="$(printf '%s\n' "$quit_body" | grep -nF 'shutdownClient.shutdown()' | cut -d: -f1)"
activity_line="$(printf '%s\n' "$quit_body" | grep -nF 'VaelenActivitySignal.markInactive()' | cut -d: -f1)"
[[ -n "$invalid_guard_line" && -n "$terminate_line" && -n "$return_line" && -n "$shutdown_line" && -n "$activity_line" ]]
(( invalid_guard_line < terminate_line && terminate_line < return_line && return_line < shutdown_line && return_line < activity_line ))
echo 'per-user app update contract: PASS'
