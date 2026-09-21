#!/bin/bash
set -u
set -o pipefail

# M14 forensic capture.  Every path, label, command, and SQL statement below is
# fixed.  This helper has no lifecycle, recovery, cleanup, or discovery ability.
LABEL='gui/501/dev.vaelen.vaelend'
RUNTIME='/Users/banes/Library/Application Support/Vaelen/runtime'
SOCKET="$RUNTIME/sockets/core.sock"
VAELEND_LOCK="$RUNTIME/locks/vaelend.lock"
BOOTSTRAP_LOCK="$RUNTIME/locks/lifecycle-bootstrap.lock"
DB='/Users/banes/Library/Application Support/Vaelen/state/vaelen.sqlite'
REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." 2>/dev/null && pwd -P) || REPO_ROOT=''
ARTIFACT_REL='.build/VaelenApp/Build/Products/Debug/Vaelen.app'
ARTIFACT="$REPO_ROOT/$ARTIFACT_REL"
CONTROLLER="$ARTIFACT/Contents/MacOS/Vaelen"
INFO_PLIST="$ARTIFACT/Contents/Info.plist"

timestamp() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
emit() { printf '%s=%s\n' "$1" "${2//$'\n'/\\n}"; }
observe() {
  local name="$1"; shift
  local started ended output code
  started=$(timestamp)
  output=$("$@" 2>&1); code=$?
  ended=$(timestamp)
  emit "${name}.started_at" "$started"
  emit "${name}.ended_at" "$ended"
  emit "${name}.exit" "$code"
  emit "${name}.result" "${output:-<no-output>}"
}
path_observe() {
  local name="$1" path="$2"
  if [ ! -e "$path" ]; then
    emit "$name.status" ABSENT
    emit "$name.path" "$path"
    return
  fi
  emit "$name.status" OBSERVED
  emit "$name.path" "$path"
  observe "$name.stat" stat -f '%N|type=%HT|mode=%Mp%Lp|uid=%Su|gid=%Sg|size=%z|mtime=%Sm' -t '%Y-%m-%dT%H:%M:%S%z' "$path"
  observe "$name.ls" ls -lde "$path"
}

emit capture.status OBSERVED
emit capture.mode read_only_fixed_inputs
emit capture.started_at "$(timestamp)"
emit input.label "$LABEL"
emit input.runtime_root "$RUNTIME"
emit input.socket "$SOCKET"
emit input.vaelend_lock "$VAELEND_LOCK"
emit input.lifecycle_bootstrap_lock "$BOOTSTRAP_LOCK"
emit input.database "$DB"
emit input.artifact "$ARTIFACT"
emit input.controller "$CONTROLLER"

observe launchctl_print launchctl print "$LABEL"
observe ps_exact ps -axo pid=,ppid=,uid=,comm=,command=
path_observe runtime_root "$RUNTIME"
path_observe socket "$SOCKET"
path_observe vaelend_lock "$VAELEND_LOCK"
path_observe lifecycle_bootstrap_lock "$BOOTSTRAP_LOCK"
path_observe artifact "$ARTIFACT"
path_observe controller "$CONTROLLER"
path_observe info_plist "$INFO_PLIST"
if [ -e "$SOCKET" ]; then observe socket_lsof lsof -n -P -- "$SOCKET"; else emit socket_lsof.status ABSENT; fi
if [ -e "$VAELEND_LOCK" ]; then observe vaelend_lock_lsof lsof -n -P -- "$VAELEND_LOCK"; else emit vaelend_lock_lsof.status ABSENT; fi
if [ -e "$BOOTSTRAP_LOCK" ]; then observe lifecycle_bootstrap_lock_lsof lsof -n -P -- "$BOOTSTRAP_LOCK"; else emit lifecycle_bootstrap_lock_lsof.status ABSENT; fi

if [ -e "$CONTROLLER" ]; then
  observe controller_codesign codesign -dvvv -- "$CONTROLLER"
else
  emit controller_codesign.status ABSENT
fi
if [ -e "$INFO_PLIST" ]; then
  observe artifact_plutil plutil -p "$INFO_PLIST"
else
  emit artifact_plutil.status ABSENT
fi

if [ ! -f "$DB" ]; then
  emit sqlite.status ABSENT
else
  emit sqlite.status OBSERVED
  observe sqlite_queries sqlite3 -readonly "file:$DB?immutable=1" 'PRAGMA schema_version; SELECT * FROM projects; SELECT * FROM route_intents; SELECT * FROM system_modifications; SELECT * FROM tls_capability; SELECT * FROM route_target_transitions; SELECT * FROM lifecycle_intent; SELECT * FROM lifecycle_operations; SELECT * FROM lifecycle_ownership; SELECT * FROM bootstrap_receipts; SELECT * FROM bootstrap_invocations;'
fi
emit capture.ended_at "$(timestamp)"
emit mutation performed no
exit 0
