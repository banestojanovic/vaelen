#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
UPDATER="$ROOT/Scripts/vaelen-dev-update"

schema_gate="$(sed -n '/^validate_schema_compatibility() {/,/^}/p' "$UPDATER")"
[[ -n "$schema_gate" ]] || { echo 'schema compatibility function is missing' >&2; exit 1; }
eval "$schema_gate"
migration_classifier="$(sed -n '/^migration_outcome() {/,/^}/p' "$UPDATER")"
[[ -n "$migration_classifier" ]] || { echo 'migration outcome classifier is missing' >&2; exit 1; }
eval "$migration_classifier"
cli_unavailable_gate="$(sed -n '/^cli_unavailable_is_safe_without_core() {/,/^}/p' "$UPDATER")"
[[ -n "$cli_unavailable_gate" ]] || { echo 'CLI-unavailable safety gate is missing' >&2; exit 1; }
eval "$cli_unavailable_gate"
path_config="$(sed -n '/^configure_paths() {/,/^}/p' "$UPDATER")"
[[ -n "$path_config" ]] || { echo 'updater path configuration is missing' >&2; exit 1; }
eval "$path_config"
die() { echo "$*" >&2; exit 1; }
TEST_MODE=0
HOME_ROOT=''
SUPPORT=''
ARTIFACTS=''
APPLICATIONS=''
CANONICAL=''
SOCKET=''
STATE_DB=''
CLI_LINK=''
process_pid_helper="$(sed -n '/^process_pid_for_command() {/,/^}/p' "$UPDATER")"
[[ -n "$process_pid_helper" ]] || { echo 'process identity helper is missing' >&2; exit 1; }
eval "$process_pid_helper"
process_count_helpers="$(sed -n '/^process_count_for_command() {/,/^}/p; /^process_count_for_bundle_executable() {/,/^}/p; /^assert_no_gui_core_processes() {/,/^}/p' "$UPDATER")"
[[ -n "$process_count_helpers" ]] || { echo 'process conflict helpers are missing' >&2; exit 1; }
eval "$process_count_helpers"
socket_owner_helper="$(sed -n '/^process_owns_socket() {/,/^}/p' "$UPDATER")"
[[ -n "$socket_owner_helper" ]] || { echo 'socket ownership helper is missing' >&2; exit 1; }
eval "$socket_owner_helper"
validate_schema_compatibility 8 8 9
validate_schema_compatibility 9 9 9
[[ "$(migration_outcome 9 9 8)" == target-reached ]]
[[ "$(migration_outcome 8 9 8)" == pre-migration ]]
[[ "$(migration_outcome 10 9 8)" == advanced ]]
if validate_schema_compatibility 8 7 9 2>/dev/null; then
  echo 'installed Core/live DB mismatch unexpectedly passed' >&2
  exit 1
fi
if validate_schema_compatibility 9 9 8 2>/dev/null; then
  echo 'candidate below live DB unexpectedly passed' >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
ps() { [[ "$*" == *'pid=,comm='* ]] && printf '%s\n' "${PROCESS_LIST:-}"; }
installed_core="/Applications/Vaelen.app/Contents/Resources/vaelend"
socket="$tmp/core.sock"
PROCESS_LIST=''
cli_unavailable_is_safe_without_core 3 "$installed_core" "$socket"
PROCESS_LIST="  123 $installed_core"
if cli_unavailable_is_safe_without_core 3 "$installed_core" "$socket"; then
  echo 'unavailable CLI with a live installed Core unexpectedly passed' >&2
  exit 1
fi
PROCESS_LIST=''
: > "$socket"
if cli_unavailable_is_safe_without_core 3 "$installed_core" "$socket"; then
  echo 'unavailable CLI with a Core socket unexpectedly passed' >&2
  exit 1
fi
rm "$socket"
if cli_unavailable_is_safe_without_core 4 "$installed_core" "$socket"; then
  echo 'protocol-incompatible CLI unexpectedly passed' >&2
  exit 1
fi

HOME="$tmp/default-home" VAELEN_DEV_UPDATE_TEST_MODE='' VAELEN_DEV_UPDATE_TEST_ROOT='' configure_paths
[[ "$TEST_MODE" == 0 && "$SUPPORT" == "$tmp/default-home/Library/Application Support/Vaelen" ]]
[[ "$ARTIFACTS" == "$tmp/default-home/Library/Application Support/Vaelen-dev-harness/updates" ]]
[[ "$APPLICATIONS" == "$tmp/default-home/Applications" && "$CLI_LINK" == "$tmp/default-home/.local/bin/val" ]]
if (HOME="$tmp/default-home" VAELEN_DEV_UPDATE_TEST_MODE=1 VAELEN_DEV_UPDATE_TEST_ROOT='' configure_paths) 2>/dev/null; then
  echo 'mode-only opt-in unexpectedly passed' >&2
  exit 1
fi
if (HOME="$tmp/default-home" VAELEN_DEV_UPDATE_TEST_MODE='' VAELEN_DEV_UPDATE_TEST_ROOT=/private/tmp/fixture configure_paths) 2>/dev/null; then
  echo 'root-only opt-in unexpectedly passed' >&2
  exit 1
fi
if (HOME="$tmp/default-home" VAELEN_DEV_UPDATE_TEST_MODE=true VAELEN_DEV_UPDATE_TEST_ROOT=/private/tmp/fixture configure_paths) 2>/dev/null; then
  echo 'malformed mode opt-in unexpectedly passed' >&2
  exit 1
fi

fixture="$(mktemp -d /private/tmp/vaelen-dev-update-contract.XXXXXX)"
fixture_link="${fixture}-link"
empty_fixture="$(mktemp -d /private/tmp/vaelen-dev-update-empty.XXXXXX)"
trap 'rm -rf "$tmp" "$fixture" "$fixture_link" "$empty_fixture"' EXIT
if (VAELEN_DEV_UPDATE_TEST_MODE=1 VAELEN_DEV_UPDATE_TEST_ROOT="$empty_fixture" configure_paths) 2>/dev/null; then
  echo 'missing marker unexpectedly passed' >&2
  exit 1
fi
printf 'vaelen-dev-update-test-fixture-v1\n' > "$fixture/.vaelen-dev-update-test-fixture"
HOME="$tmp/default-home" VAELEN_DEV_UPDATE_TEST_MODE=1 VAELEN_DEV_UPDATE_TEST_ROOT="$fixture" configure_paths
[[ "$TEST_MODE" == 1 && "$HOME_ROOT" == "$fixture/home" ]]
[[ "$SUPPORT" == "$fixture/home/Library/Application Support/Vaelen" ]]
[[ "$ARTIFACTS" == "$fixture/home/Library/Application Support/Vaelen-dev-harness/updates" ]]
[[ "$APPLICATIONS" == "$fixture/home/Applications" && "$CANONICAL" == "$fixture/home/Applications/Vaelen.app" ]]
[[ "$CLI_LINK" == "$fixture/home/.local/bin/val" ]]
[[ "$SOCKET" == "$SUPPORT/runtime/sockets/core.sock" && "$STATE_DB" == "$SUPPORT/state/vaelen.sqlite" ]]
[[ "$TEST_MODE" == 1 ]]
[[ "$HOME" == "$tmp/default-home" ]]
PROCESS_LIST="/Applications/Vaelen.app/Contents/MacOS/Vaelen"
if (ps() { printf '%s\n' "$PROCESS_LIST"; }; assert_no_gui_core_processes) 2>/dev/null; then
  echo 'fixture mode accepted a running legacy GUI' >&2
  exit 1
fi
PROCESS_LIST="/Users/test/Applications/Alternate.app/Contents/Resources/vaelend"
if (ps() { printf '%s\n' "$PROCESS_LIST"; }; assert_no_gui_core_processes) 2>/dev/null; then
  echo 'fixture mode accepted a Core from an alternate app bundle' >&2
  exit 1
fi
PROCESS_LIST=''
if (ps() { printf '%s\n' "$PROCESS_LIST"; }; assert_no_gui_core_processes); then :; else exit 1; fi
[[ ! -e "$fixture/home" ]] || { echo 'process refusal fixture unexpectedly created home state' >&2; exit 1; }
shutdown_note_line="$(grep -nF 'note "Requesting normal GUI shutdown"' "$UPDATER" | cut -d: -f1)"
fixture_refusal_line="$(grep -nF '  assert_no_gui_core_processes' "$UPDATER" | cut -d: -f1 | head -1)"
mkdir_line="$(grep -nF 'mkdir "$APPLICATIONS"' "$UPDATER" | cut -d: -f1)"
(( fixture_refusal_line < mkdir_line && fixture_refusal_line < shutdown_note_line )) || exit 1
test_shutdown_branch_line="$(grep -nF 'elif [[ "$GUI_COUNT" == 1 ]]; then' "$UPDATER" | cut -d: -f1)"
apple_script_quit_line="$(grep -nF 'tell application id "dev.vaelen.app" to quit' "$UPDATER" | cut -d: -f1)"
promotion_guard_line="$(grep -nF 'if [[ "$TEST_MODE" == 1 ]]; then assert_no_gui_core_processes; fi' "$UPDATER" | cut -d: -f1)"
promotion_line="$(grep -nF 'note "Promoting candidate while retaining the prior app"' "$UPDATER" | cut -d: -f1)"
fixture_open_line="$(grep -nF '  launch_fixture_app' "$UPDATER" | cut -d: -f1)"
(( test_shutdown_branch_line < apple_script_quit_line && promotion_guard_line < promotion_line && promotion_line < fixture_open_line )) || exit 1

fixture_safety="$(sed -n '/^validate_updater_fixture() {/,/^}/p' "$UPDATER")"
eval "$fixture_safety"
fixture_launch_helpers="$(sed -n '/^launch_fixture_app() {/,/^}/p; /^assert_fixture_launch() {/,/^}/p' "$UPDATER")"
eval "$fixture_launch_helpers"
VAELEN_DEV_UPDATE_TEST_ROOT="$fixture"
VAELEN_DEV_UPDATE_TEST_MODE=1
fixture_core="$CANONICAL/Contents/Resources/vaelend"
alias_core="${fixture_core/#\/private\/tmp\//\/tmp\/}"
PROCESS_LIST="  321 $alias_core"
[[ "$(process_pid_for_command "$fixture_core")" == 321 ]]
[[ "$(ps() { printf '%s\n' "$alias_core"; }; process_count_for_command "$fixture_core")" == 1 ]]
[[ -z "$(TEST_MODE=0 process_pid_for_command "$fixture_core")" ]]
PROCESS_LIST="  321 ${alias_core/$(basename "$fixture")/different-fixture}"
[[ -z "$(process_pid_for_command "$fixture_core")" ]]
lsof() {
  [[ "$*" == '-nP -Fpn -p 321' ]] || return 1
  printf 'p321\nf6\nn%s\n' "${SOCKET#/private}"
}
process_owns_socket 321 "$SOCKET"
if process_owns_socket 322 "$SOCKET"; then
  echo 'socket ownership accepted the wrong Core PID' >&2
  exit 1
fi
lsof() { printf 'p321\nf6\nn/tmp/different-fixture/core.sock\n'; }
if process_owns_socket 321 "$SOCKET"; then
  echo 'socket ownership accepted another fixture path' >&2
  exit 1
fi

mkdir -p "$CANONICAL/Contents/MacOS" "$ARTIFACTS"
RUN="$ARTIFACTS/launch-contract"
mkdir "$RUN"
cat > "$CANONICAL/Contents/MacOS/Vaelen" <<'CHILD'
#!/bin/bash
set -eu
[[ "$VAELEN_TEST_SUPPORT_ROOT_ENABLED" == 1 && "$VAELEN_TEST_ALLOW_CORE_START" == 1 ]]
[[ "$VAELEN_TEST_SUPPORT_ROOT" == "$HOME/Library/Application Support/Vaelen" ]]
[[ "$CFFIXED_USER_HOME" == "$HOME" ]]
[[ "$1" == --verification-open-settings=services ]]
printf '%s\n' "$HOME" "$VAELEN_TEST_SUPPORT_ROOT" > "$VAELEN_TEST_SUPPORT_ROOT/launch-environment.txt"
CHILD
chmod +x "$CANONICAL/Contents/MacOS/Vaelen"
mkdir -p "$SUPPORT/state"
sqlite3 "$STATE_DB" 'PRAGMA user_version=8;
CREATE TABLE projects (id TEXT);
CREATE TABLE parked_paths (id TEXT);
CREATE TABLE route_intents (id TEXT, project_id TEXT, project_path TEXT);
CREATE TABLE system_modifications (capability TEXT);
CREATE TABLE tls_capability (id INTEGER);
CREATE TABLE route_target_transitions (route_id TEXT);
CREATE TABLE park_route_ownership (route_id TEXT);
CREATE TABLE dns_resolver_ownership (id INTEGER);
INSERT INTO route_intents VALUES ("1", NULL, NULL), ("2", NULL, NULL), ("3", NULL, NULL), ("4", NULL, NULL), ("5", NULL, NULL);'
printf '{"caddy": false}\n' > "$SUPPORT/state/service-intents.json"
validate_updater_fixture

assert_unsafe_fixture_refused() {
  if (validate_updater_fixture) 2>/dev/null; then
    echo 'unsafe fixture passed validation' >&2
    exit 1
  fi
  if (ps() { :; }; launch_fixture_app; wait "$FIXTURE_GUI_PID") 2>/dev/null; then
    echo 'unsafe fixture launched app' >&2
    exit 1
  fi
  [[ ! -e "$SUPPORT/launch-environment.txt" ]] || { echo 'unsafe fixture executed app child' >&2; exit 1; }
}
for unsafe_intents in '{"caddy": true}' '{}' '{"caddy": 0}' '{"caddy": false, "mysql": 1}' '{"caddy": false, "mysql": true}' '[]' 'invalid'; do
  printf '%s\n' "$unsafe_intents" > "$SUPPORT/state/service-intents.json"
  assert_unsafe_fixture_refused
done
rm "$SUPPORT/state/service-intents.json"
assert_unsafe_fixture_refused
printf '{"caddy": false}\n' > "$SUPPORT/state/service-intents.json"
for unsafe_schema in 0 7 9; do
  sqlite3 "$STATE_DB" "PRAGMA user_version=$unsafe_schema;"
  assert_unsafe_fixture_refused
done
sqlite3 "$STATE_DB" 'PRAGMA user_version=8;'
for table in projects parked_paths system_modifications tls_capability dns_resolver_ownership route_target_transitions park_route_ownership; do
  sqlite3 "$STATE_DB" "INSERT INTO $table VALUES ('unsafe');"
  assert_unsafe_fixture_refused
  sqlite3 "$STATE_DB" "DELETE FROM $table;"
done
for column in project_id project_path; do
  sqlite3 "$STATE_DB" "UPDATE route_intents SET $column = 'unsafe' WHERE id = '1';"
  assert_unsafe_fixture_refused
  sqlite3 "$STATE_DB" "UPDATE route_intents SET $column = NULL WHERE id = '1';"
done
for tls_material in certificates/ca.der certificates/leaf/example.pem unexpected-key; do
  mkdir -p "$SUPPORT/tls/$(dirname "$tls_material")"
  printf 'copied TLS material\n' > "$SUPPORT/tls/$tls_material"
  assert_unsafe_fixture_refused
  rm "$SUPPORT/tls/$tls_material"
done
for process_record in instances/php/8.3/process.json instances/caddy/process.json instances/mysql/process.json; do
  mkdir -p "$SUPPORT/$(dirname "$process_record")"
  printf '{}\n' > "$SUPPORT/$process_record"
  assert_unsafe_fixture_refused
  rm "$SUPPORT/$process_record"
done
validate_updater_fixture
(ps() { :; }; launch_fixture_app; wait "$FIXTURE_GUI_PID")
[[ "$(cat "$SUPPORT/launch-environment.txt")" == "$(printf '%s\n' "$HOME_ROOT" "$SUPPORT")" ]]
[[ ! -e "$HOME/Library/Application Support/Vaelen/launch-environment.txt" ]]
GUI_PID=321 CORE_PID=322 FIXTURE_GUI_PID=999
if (assert_fixture_launch) 2>/dev/null; then
  echo 'fixture accepted a GUI other than the directly launched child' >&2
  exit 1
fi
mkdir -p "$SUPPORT/bin" "$SUPPORT/state" "$tmp/host"
printf '{"mysql": true}\n' > "$tmp/host/intents.json"
printf '{"caddy": true}\n' > "$SUPPORT/state/service-intents.json"
cat > "$tmp/host/val" <<'HOST_CLI'
#!/bin/bash
printf 'host CLI executed\n' >> "$READINESS_CALL_LOG"
exit 1
HOST_CLI
cat > "$SUPPORT/bin/val" <<'FIXTURE_CLI'
#!/bin/bash
printf 'fixture %s\n' "$*" >> "$READINESS_CALL_LOG"
printf 'Health healthy\n'
FIXTURE_CLI
chmod +x "$tmp/host/val" "$SUPPORT/bin/val"
export READINESS_CALL_LOG="$tmp/readiness-calls"
(
  export VAELEN_READINESS_VAL="$tmp/host/val" VAELEN_READINESS_INTENTS="$tmp/host/intents.json"
  readiness_setup="$(sed -n '/^configure_paths$/,/^source .*vaelen-service-readiness/p' "$UPDATER")"
  eval "$readiness_setup"
  [[ "$VAL" == "$SUPPORT/bin/val" && "$INTENTS" == "$SUPPORT/state/service-intents.json" ]]
  wait_enabled_services
)
[[ "$(cat "$READINESS_CALL_LOG")" == 'fixture routing status' ]]
rm -rf "$fixture/home"
APP_MODEL="$ROOT/App/Vaelen/Vaelen/AppModel.swift"
grep -Fq 'export VAELEN_TEST_ALLOW_CORE_START=1' "$UPDATER"
python3 - "$ROOT/Sources/VaelenDaemon/main.swift" "$APP_MODEL" "$tmp" <<'PRIVILEGE_CONTRACT'
from pathlib import Path
import subprocess
import sys
daemon, app = (Path(name).read_text() for name in sys.argv[1:3])
isolated = daemon.split('if VaelenTestRuntimePaths.isolatedSupportRoot() != nil {', 1)[1].split('} else {', 1)[0]
assert 'helper = UnavailablePrivilegedDNSHelper()' in isolated
assert 'privilegedPorts = UnavailableStandardPortsPrivileged()' in isolated
assert 'HelperPrivilegedDNS()' not in isolated and 'HelperStandardPortsPrivileged()' not in isolated
assert 'DevelopmentPrivilegedDNSHelper()' not in isolated
assert 'StandardPortsCapability(privileged: privilegedPorts,' in daemon
startup = app.split('                let coreStarted: Bool', 1)[1].split('                guard coreStarted else', 1)[0]
refresh_guard = app.split('    func refresh(whileRelationshipMutationInFlight: Bool = false) async {', 1)[1].split('        guard !relationshipMutationInFlight', 1)[0]
assert 'VAELEN_TEST_ALLOW_CORE_START' in refresh_guard and 'isolatedSupportRoot() == nil' in refresh_guard
registration = app.split('private func registerCurrentPrivilegedHelper() async throws -> Bool {', 1)[1].split('        guard #available', 1)[0]
daemon_guard = daemon.split('        do {', 1)[1].split('            let paths = CoreEndpointPaths()', 1)[0]
source = r"""
import Foundation
var starts = 0
var registrations = 0
var connections = 0
struct VaelenTestRuntimePaths { static func isolatedSupportRoot() -> String? { ProcessInfo.processInfo.environment["ROOT_PRESENT"] == "1" ? "/fixture" : nil } }
struct CoreProcessManager { static let shared = CoreProcessManager(); func start() throws { starts += 1 } }
struct CoreStartupHelperGate { static func run(reconcileHelper: () async throws -> Bool, startCore: () throws -> Void) async throws -> Bool { let ok = try await reconcileHelper(); if ok { try startCore() }; return ok } }
enum HarnessState { case unavailable }
final class Harness {
 var state = HarnessState.unavailable
 var isSettingsFixture = false
 func registerCurrentPrivilegedHelper() async throws -> Bool {
REGISTRATION
 registrations += 1; return true
 }
 func startup() async throws -> Bool {
 let error = NSError(domain: "unavailable", code: 1)
 let coreStarted: Bool
STARTUP
 return coreStarted
 }
 func hypotheticalExistingCoreStartup() {
REFRESH_GUARD
 connections += 1
 }
}
func daemonCheck() throws {
DAEMON_GUARD
}
@main struct Main { static func main() async {
 let allowed = (try? await Harness().startup()) ?? false
 let registrationAllowed = (try? await Harness().registerCurrentPrivilegedHelper()) ?? false
 let daemonAllowed = (try? daemonCheck()) != nil
 Harness().hypotheticalExistingCoreStartup()
 print("\(allowed) \(starts) \(registrations) \(registrationAllowed) \(daemonAllowed) \(connections > 0) \(connections)")
} }
""".replace('REGISTRATION', registration).replace('STARTUP', startup).replace('REFRESH_GUARD', refresh_guard).replace('DAEMON_GUARD', daemon_guard)
path = Path(sys.argv[3]) / 'runtime-boundary.swift'
path.write_text(source)
binary = str(path.with_suffix(''))
subprocess.run(['swiftc', '-parse-as-library', str(path), '-o', binary], check=True)
for flag, root, expected in [('1', '0', 'false 0 0 false false'), ('1', '1', 'true 1 0 false true'), ('0', '1', 'false 0 0 false true'), ('0', '0', 'true 1 2 true true')]:
    import os
    env = dict(os.environ, VAELEN_TEST_ALLOW_CORE_START=flag, ROOT_PRESENT=root)
    result = subprocess.check_output([binary], env=env, text=True).strip()
    app_allowed = root == '1' or flag != '1'
    expected = f'{expected} {str(app_allowed).lower()} {int(app_allowed)}'
    assert result == expected, (flag, root, result, expected)
PRIVILEGE_CONTRACT
grep -Fq 'if [[ "$TEST_MODE" == 1 ]]; then assert_fixture_launch; fi' "$UPDATER"

mkdir "$fixture/redirect"
ln -s redirect "$fixture/home"
if (VAELEN_DEV_UPDATE_TEST_MODE=1 VAELEN_DEV_UPDATE_TEST_ROOT="$fixture" configure_paths) 2>/dev/null; then
  echo 'symlink fixture home unexpectedly passed' >&2
  exit 1
fi
rm "$fixture/home"
rmdir "$fixture/redirect"

for symlink_target in bin runtime sockets core.sock gui core \
  state/vaelen.sqlite state/vaelen.sqlite-wal state/vaelen.sqlite-shm \
  state/local-proxy-ownership.sqlite state/local-proxy-ownership.sqlite-wal state/local-proxy-ownership.sqlite-shm \
  state/service-intents.json config/routing/Caddyfile runtime/routing/owned.json \
  instances/dns/responder.json logs/caddy/access.log tls/certificates/leaf/test.pem cache/downloads/package.tmp packages/php/nested; do
  support="$fixture/home/Library/Application Support/Vaelen"
  case "$symlink_target" in
    bin|runtime) link_path="$support/$symlink_target" ;;
    gui) link_path="$CANONICAL/Contents/MacOS/Vaelen" ;;
    core) link_path="$CANONICAL/Contents/Resources/vaelend" ;;
    sockets) mkdir -p "$support/runtime"; link_path="$support/runtime/sockets" ;;
    core.sock) mkdir -p "$support/runtime/sockets"; link_path="$support/runtime/sockets/core.sock" ;;
    *) link_path="$support/$symlink_target" ;;
  esac
  mkdir -p "$(dirname "$link_path")" "$fixture/redirect-$symlink_target"
  ln -s "$fixture/redirect-$symlink_target" "$link_path"
  if (VAELEN_DEV_UPDATE_TEST_MODE=1 VAELEN_DEV_UPDATE_TEST_ROOT="$fixture" configure_paths) 2>/dev/null; then
    echo "symlinked $symlink_target fixture path unexpectedly passed" >&2
    exit 1
  fi
  rm "$link_path"
done
if (VAELEN_DEV_UPDATE_TEST_MODE=1 VAELEN_DEV_UPDATE_TEST_ROOT="$fixture/missing" configure_paths) 2>/dev/null; then
  echo 'missing fixture root unexpectedly passed' >&2
  exit 1
fi
if (VAELEN_DEV_UPDATE_TEST_MODE=1 VAELEN_DEV_UPDATE_TEST_ROOT="$fixture/nested" configure_paths) 2>/dev/null; then
  echo 'nested fixture root unexpectedly passed' >&2
  exit 1
fi
ln -s "$fixture" "$fixture_link"
if (VAELEN_DEV_UPDATE_TEST_MODE=1 VAELEN_DEV_UPDATE_TEST_ROOT="$fixture_link" configure_paths) 2>/dev/null; then
  echo 'symlink fixture root unexpectedly passed' >&2
  exit 1
fi
printf 'wrong-marker\n' > "$fixture/.vaelen-dev-update-test-fixture"
if (VAELEN_DEV_UPDATE_TEST_MODE=1 VAELEN_DEV_UPDATE_TEST_ROOT="$fixture" configure_paths) 2>/dev/null; then
  echo 'wrong marker unexpectedly passed' >&2
  exit 1
fi
printf 'vaelen-dev-update-test-fixture-v1\n' > "$fixture/.vaelen-dev-update-test-fixture"
mv "$fixture/.vaelen-dev-update-test-fixture" "$fixture/real-marker"
ln -s real-marker "$fixture/.vaelen-dev-update-test-fixture"
if (VAELEN_DEV_UPDATE_TEST_MODE=1 VAELEN_DEV_UPDATE_TEST_ROOT="$fixture" configure_paths) 2>/dev/null; then
  echo 'symlink marker unexpectedly passed' >&2
  exit 1
fi

grep -Fq 'MIGRATION_OUTCOME="$(migration_outcome "$POST_LAUNCH_SCHEMA" "$CANDIDATE_SCHEMA" "$LIVE_SCHEMA")"' "$UPDATER"
grep -Fq 'candidate-core-schema=%s' "$UPDATER"
grep -Fq 'online schema-$LIVE_SCHEMA DB evidence=$RUN/state-before.sqlite (never auto-restore)' "$UPDATER"
! grep -Fq '/usr/bin/open -n --env' "$UPDATER"
grep -Fq 'CFFIXED_USER_HOME="$HOME_ROOT"' "$UPDATER"
grep -Fq 'open "$CANONICAL" --args --verification-open-settings=services' "$UPDATER"
grep -Fq '"$(stat -f %u "$test_root")" == "$(id -u)"' "$UPDATER"
grep -Fq '"$(stat -f %u "$marker")" == "$(id -u)"' "$UPDATER"
grep -Fq '[[ ! -L "$path" ]] || die "test fixture path component must not be a symlink: $path"' "$UPDATER"
for checked_path in '"$SUPPORT/bin"' '"$SUPPORT/runtime"' '"$SUPPORT/runtime/sockets"' '"$SUPPORT/config"' '"$SUPPORT/instances"' '"$SUPPORT/packages"' '"$SUPPORT/tls"' '"$SUPPORT/logs"' '"$SUPPORT/cache"'; do
  grep -Fq "$checked_path" "$UPDATER" || { echo "missing fixture path validation for $checked_path" >&2; exit 1; }
done
grep -Fq 'export VAELEN_TEST_SUPPORT_ROOT_ENABLED=1' "$UPDATER"
grep -Fq 'export VAELEN_TEST_SUPPORT_ROOT="$SUPPORT"' "$UPDATER"
grep -Fq 'export VAELEN_READINESS_VAL="$SUPPORT/bin/val"' "$UPDATER"
grep -Fq 'export VAELEN_READINESS_INTENTS="$SUPPORT/state/service-intents.json"' "$UPDATER"
grep -Fq 'DERIVED="$VAELEN_DEV_UPDATE_TEST_ROOT/DerivedData/product-dev-release"' "$UPDATER"
configure_line="$(grep -n '^configure_paths$' "$UPDATER" | cut -d: -f1)"
mutation_line="$(grep -nF 'mkdir "$APPLICATIONS"' "$UPDATER" | cut -d: -f1)"
fixture_refusal_line="$(grep -nF '  assert_no_gui_core_processes' "$UPDATER" | cut -d: -f1 | head -1)"
[[ -n "$configure_line" && "$configure_line" -lt "$fixture_refusal_line" && "$fixture_refusal_line" -lt "$mutation_line" ]]
gate_line="$(grep -nF 'validate_schema_compatibility "$LIVE_SCHEMA" "$INSTALLED_CORE_SCHEMA" "$CANDIDATE_SCHEMA" || die' "$UPDATER" | cut -d: -f1)"
cli_line="$(grep -nF 'vaelen_update_cli_preflight "$CLI" "$CLI_OWNER" "$CLI_LINK"' "$UPDATER" | cut -d: -f1)"
shutdown_line="$(grep -nF 'note "Requesting normal GUI shutdown"' "$UPDATER" | cut -d: -f1)"
[[ -n "$gate_line" && "$gate_line" -lt "$cli_line" && "$cli_line" -lt "$shutdown_line" ]]
grep -Fq 'cli_unavailable_is_safe_without_core "$CLI_PREFLIGHT_STATUS" "$INSTALLED_CORE" "$SOCKET"' "$UPDATER"
fixture_entry_gate="$(grep -nF '  validate_updater_fixture || die "fixture safety check failed before update"' "$UPDATER" | cut -d: -f1)"
fixture_promotion_gate="$(grep -nF '  validate_updater_fixture || die "fixture safety check failed before promotion"' "$UPDATER" | cut -d: -f1)"
fixture_launch_gate="$(grep -nF '  validate_updater_fixture || die "fixture safety check failed before launch"' "$UPDATER" | cut -d: -f1)"
fixture_exec="$(grep -nF '  /usr/bin/env -i HOME=' "$UPDATER" | cut -d: -f1)"
(( fixture_entry_gate < mutation_line && fixture_promotion_gate < promotion_line && fixture_launch_gate < fixture_exec ))
! grep -Fq 'sqlite3 "$STATE_DB" <' "$UPDATER"
! grep -Fq 'cp "$RUN/state-before.sqlite" "$STATE_DB"' "$UPDATER"
! grep -Fq 'ditto "$RUN/state-before.sqlite" "$STATE_DB"' "$UPDATER"
echo 'schema 9 update compatibility contract: PASS'
