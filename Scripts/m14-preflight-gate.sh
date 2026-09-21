#!/bin/bash
set -u
set -o pipefail

# M14 pre-mutation gate: fixed, observation-only inputs. There is no discovery,
# fallback, retry, repair, or lifecycle authority in this helper.
ARCHIVE="${VAELEN_VALIDATION_ARCHIVE:-/Users/banes/Library/Application Support/Vaelen/M14Validation/vaelen-release-validation-fresh-20260920-1829.xcarchive}"
APP="$ARCHIVE/Products/Applications/Vaelen.app"
APP_EXEC="$APP/Contents/MacOS/Vaelen"
DAEMON="$APP/Contents/Resources/vaelend"
AGENT="$APP/Contents/Library/LaunchAgents/dev.vaelen.vaelend.agent.plist"
LABEL='dev.vaelen.vaelend'
TEAM='TFKZJV643G'
EXPECTED_APP_SHA="${VAELEN_VALIDATION_APP_SHA:-1c0bc45c3b0c371b520ebd146e0030bf7aaba43e9c9bb2cdb4858ea0e4a41583}"
EXPECTED_DAEMON_SHA="${VAELEN_VALIDATION_DAEMON_SHA:-afa83c9e8d3b8aa9b74725e75a027dffc1a0d452ddb745e211a53f7230ff1154}"
RUNTIME='/Users/banes/Library/Application Support/Vaelen/runtime'
SOCKET="$RUNTIME/sockets/core.sock"
VAELEND_LOCK="$RUNTIME/locks/vaelend.lock"
BOOTSTRAP_LOCK="$RUNTIME/locks/lifecycle-bootstrap.lock"

pass=0
fail=0
record() {
  printf 'operation=%s status=%s detail=%s\n' "$1" "$2" "$3"
  case "$2" in PASS|ABSENT) ;; *) fail=$((fail + 1));; esac
  [ "$2" = PASS ] && pass=$((pass + 1))
}

printf 'gate=m14-pre-mutation-gate version=1 mode=observation-only\n'
printf 'constant.archive=%s\nconstant.app=%s\nconstant.app_executable=%s\nconstant.daemon=%s\nconstant.launch_agent=%s\nconstant.label=%s\nconstant.team=%s\n' "$ARCHIVE" "$APP" "$APP_EXEC" "$DAEMON" "$AGENT" "$LABEL" "$TEAM"
printf 'hash_semantics.app_sha256=Contents/MacOS/Vaelen executable digest evidence_only_not_trust_anchor\n'
printf 'hash_semantics.daemon_sha256=Contents/Resources/vaelend executable digest evidence_only_not_trust_anchor\n'

if [ -d "$ARCHIVE" ]; then record artifact_exists PASS exact_archive_path_exists; else record artifact_exists FAIL exact_archive_path_absent; fi
if [ -d "$APP" ]; then record app_exists PASS exact_app_path_exists; else record app_exists FAIL exact_app_path_absent; fi
if [ -x "$APP_EXEC" ]; then record app_executable_exists PASS exact_executable_exists; else record app_executable_exists FAIL exact_executable_absent; fi
if [ -x "$DAEMON" ]; then record daemon_executable_exists PASS exact_executable_exists; else record daemon_executable_exists FAIL exact_executable_absent; fi
if [ -f "$AGENT" ]; then record launch_agent_exists PASS exact_launch_agent_exists; else record launch_agent_exists FAIL exact_launch_agent_absent; fi

# Exact accepted hashes are provenance evidence only, never trust anchors.
app_sha=$(shasum -a 256 "$APP_EXEC" 2>/dev/null) || app_sha=''
if [ -n "$app_sha" ] && [ "${app_sha%% *}" = "$EXPECTED_APP_SHA" ]; then record app_executable_sha256 PASS "$EXPECTED_APP_SHA"; else record app_executable_sha256 FAIL expected_sha256_mismatch; fi
daemon_sha=$(shasum -a 256 "$DAEMON" 2>/dev/null) || daemon_sha=''
if [ -n "$daemon_sha" ] && [ "${daemon_sha%% *}" = "$EXPECTED_DAEMON_SHA" ]; then record daemon_executable_sha256 PASS "$EXPECTED_DAEMON_SHA"; else record daemon_executable_sha256 FAIL expected_sha256_mismatch; fi

# This is the repository's existing explicit API test. --skip-build keeps this
# gate from building; the test calls ArtifactPreflight.validate(appURL:) with
# exactly VAELEN_ARTIFACT_PREFLIGHT_PATH and performs no lifecycle mutation.
preflight_output=$(VAELEN_ARTIFACT_PREFLIGHT_PATH="$APP" swift test --skip-build --filter 'CanonicalSigningTrustBoundaryTests/testExplicitSignedArtifactPreflightWhenPathIsProvided' 2>&1)
preflight_exit=$?
if [ "$preflight_exit" -eq 0 ]; then record artifact_preflight PASS exact_app_url_api_test; elif printf '%s' "$preflight_output" | grep -q 'Permission denied'; then record artifact_preflight PERMISSION_DENIED swift_test_permission_denied; else record artifact_preflight OBSERVATION_FAILED swift_test_exit_$preflight_exit; fi

launchctl_output=$(launchctl print "gui/501/$LABEL" 2>&1)
launchctl_exit=$?
if [ "$launchctl_exit" -eq 0 ]; then record launchctl_print AMBIGUOUS exact_label_present; elif printf '%s' "$launchctl_output" | grep -Eiq 'could not find|service not found|not found'; then record launchctl_print ABSENT exact_label_absent; elif printf '%s' "$launchctl_output" | grep -Eiq 'permission denied|operation not permitted'; then record launchctl_print PERMISSION_DENIED launchctl_permission_denied; else record launchctl_print OBSERVATION_FAILED launchctl_exit_$launchctl_exit; fi

process_output=$(ps -axo pid=,comm=,command= | awk -v app="$APP_EXEC" -v daemon="$DAEMON" '$3 == app || $3 == daemon')
ps_exit=$?
if [ "$ps_exit" -ne 0 ]; then record canonical_process OBSERVATION_FAILED ps_exit_$ps_exit
elif [ -z "$process_output" ]; then record canonical_process ABSENT no_exact_canonical_process
elif printf '%s' "$process_output" | awk 'NR > 1 { found=1 } END { exit(found ? 0 : 1) }'; then record canonical_process AMBIGUOUS multiple_canonical_process_observations
else record canonical_process AMBIGUOUS canonical_process_observed; fi

if [ -S "$SOCKET" ]; then record core_socket AMBIGUOUS exact_canonical_socket_present; elif [ -e "$SOCKET" ]; then record core_socket OBSERVATION_FAILED exact_path_not_socket; else record core_socket ABSENT exact_canonical_socket_absent; fi

inspect_lock() {
  name="$1"; path="$2"
  if [ ! -e "$path" ]; then record "$name" ABSENT exact_lock_absent; return; fi
  output=$(lsof -n -P -- "$path" 2>&1); code=$?
  if [ "$code" -eq 0 ]; then
    if printf '%s' "$output" | awk 'NR > 1 { found=1 } END { exit(found ? 0 : 1) }'; then record "$name" AMBIGUOUS exact_lock_holder_present; else record "$name" OBSERVATION_FAILED lsof_no_holder_record; fi
  elif printf '%s' "$output" | grep -Eiq 'permission denied|operation not permitted'; then record "$name" PERMISSION_DENIED lsof_permission_denied
  elif [ "$code" -eq 1 ]; then record "$name" ABSENT no_lock_holder
  else record "$name" OBSERVATION_FAILED lsof_exit_$code; fi
}
inspect_lock vaelend_lock "$VAELEND_LOCK"
inspect_lock lifecycle_bootstrap_lock "$BOOTSTRAP_LOCK"

if [ "$fail" -eq 0 ]; then printf 'gate_result=PASS pass_count=%s fail_count=%s\n' "$pass" "$fail"; exit 0; fi
printf 'gate_result=FAIL pass_count=%s fail_count=%s\n' "$pass" "$fail"
exit 1
