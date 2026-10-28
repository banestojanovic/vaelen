#!/bin/sh
set -eu

cd "$(dirname "$0")/../.."
SUPPORT="$HOME/Library/Application Support/Vaelen"
PHP_PACKAGE="$SUPPORT/packages/php/8.4.27"
PHP="$PHP_PACKAGE/php"
COMPOSER="/opt/homebrew/Cellar/composer/2.9.8/bin/composer"
FIXTURE="$PWD/Tests/Fixtures/Laravel13/app"
PROBE="$PWD/Scripts/tests/fixtures/laravel-connection-probe.php"
EVIDENCE=$(mktemp -d /private/tmp/vaelen-laravel-connection-evidence.XXXXXX)
PREP=$(mktemp -d /private/tmp/vaelen-laravel-connection-prep.XXXXXX)
chmod 700 "$PREP"
chmod 700 "$EVIDENCE"
cleanup() {
    if [ -f "$PREP/composer-active" ] && [ ! -f "$PREP/composer-pgid" ]; then
        : > "$PREP/composer-group-uncertain"
    fi
    if [ -f "$PREP/composer-pgid" ]; then
        python3 - "$PREP" <<'PY'
import os, signal, sys, time
from pathlib import Path
root = Path(sys.argv[1])
pidfile = root / "composer-pgid"
try:
    pgid = int(pidfile.read_text())
except FileNotFoundError:
    raise SystemExit(0)
for sig, grace in ((signal.SIGTERM, 2), (signal.SIGKILL, 2)):
    try:
        os.killpg(pgid, sig)
    except ProcessLookupError:
        pidfile.unlink(missing_ok=True)
        raise SystemExit(0)
    deadline = time.monotonic() + grace
    while time.monotonic() < deadline:
        try: os.killpg(pgid, 0)
        except ProcessLookupError:
            pidfile.unlink(missing_ok=True)
            raise SystemExit(0)
        time.sleep(0.05)
(root / "composer-group-uncertain").touch()
raise SystemExit(1)
PY
    fi
    if [ -f "$PREP/composer-group-uncertain" ]; then
        printf 'Preparation root retained because Composer process teardown was not confirmed: %s\n' "$PREP" >&2
    else
        rm -rf "$PREP"
    fi
    printf 'Evidence retained at %s\n' "$EVIDENCE"
}
trap cleanup EXIT

test -x "$PHP"
test -f "$COMPOSER"
test -f "$FIXTURE/composer.lock"
test -f "$PROBE"

python3 - "$PHP" "$PHP_PACKAGE/.vaelen-package.json" "$COMPOSER" "$FIXTURE" "$PREP" "$EVIDENCE" <<'PY'
import hashlib
import json
import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

php, metadata_path, composer, fixture, prep, evidence = map(Path, sys.argv[1:])
meta = json.loads(metadata_path.read_text())
assert meta.get("version") == "8.4.27", "expected Vaelen PHP 8.4.27"
assert os.path.realpath(meta.get("cliPath", "")) == str(php), "PHP metadata path mismatch"
prov = json.loads((fixture.parent / "provenance.json").read_text())
assert prov["source"]["tag"] == "v13.11.0"
assert prov["source"]["tagObject"] == "06d016a364a37430eec9cbc52209adce3d7667ce"
assert prov["source"]["sourceArchiveSHA256"] == "afd5c6f2d147287b6ccc04b505cc673e12bb583ceb4d68c763c5c2646431639d"
for relative, expected in prov["retainedFileSHA256"].items():
    actual = hashlib.sha256((fixture.parent / relative).read_bytes()).hexdigest()
    assert actual == expected, f"Laravel fixture provenance mismatch: {relative}"
lock = json.loads((fixture / "composer.lock").read_text())
locked = {item["name"]: item["version"] for item in lock["packages"]}
assert locked.get("laravel/framework") == "v13.39.0", "Laravel framework lock mismatch"
assert locked.get("vlucas/phpdotenv") == "v5.8.0", "phpdotenv lock mismatch"
lock_hash = hashlib.sha256((fixture / "composer.lock").read_bytes()).hexdigest()
version = subprocess.run([str(php), "-r", "echo PHP_VERSION;"], check=True, text=True, capture_output=True, env={"PATH": "/usr/bin:/bin", "HOME": str(prep)})
assert version.stdout == "8.4.27", "PHP runtime version mismatch"
app = prep / "app"
shutil.copytree(fixture, app)
home = prep / "composer-home"
cache = prep / "composer-cache"
home.mkdir(mode=0o700)
cache.mkdir(mode=0o700)
for name in ("config", "auth.json"):
    path = home / name
    assert not path.exists(), "isolated Composer home unexpectedly contains credentials"

env = {
    "PATH": "/usr/bin:/bin",
    "HOME": str(home),
    "COMPOSER_HOME": str(home),
    "COMPOSER_CACHE_DIR": str(cache),
    "COMPOSER_ALLOW_SUPERUSER": "1",
    "COMPOSER_DISABLE_XDEBUG_WARN": "1",
    "COMPOSER_NO_INTERACTION": "1",
    "COMPOSER_PROCESS_TIMEOUT": "540",
    "TMPDIR": str(prep),
    "LC_ALL": "C",
}
log_path = Path(evidence) / "composer-install.log"
def run_composer(arguments, timeout, output_path=None):
    pid_path = prep / "composer-pgid"
    active_path = prep / "composer-active"
    active_path.touch()
    process = subprocess.Popen([str(php), str(composer), *arguments], cwd=app, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
    pid_path.write_text(str(process.pid))
    try:
        output, _ = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.communicate(timeout=2)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            try:
                process.communicate(timeout=2)
            except subprocess.TimeoutExpired:
                (prep / "composer-group-uncertain").touch()
                raise RuntimeError("Composer process could not be reaped; prep root must be retained")
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            try:
                os.killpg(process.pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.05)
        else:
            try: os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError: pass
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                try: os.killpg(process.pid, 0)
                except ProcessLookupError: break
                time.sleep(0.05)
            else:
                (prep / "composer-group-uncertain").touch()
                raise RuntimeError("Composer descendants remain; prep root must be retained")
        if output_path: output_path.write_bytes(output)
        pid_path.unlink(missing_ok=True)
        active_path.unlink(missing_ok=True)
        raise RuntimeError("Composer command timed out after bounded process-group termination")
    status = process.returncode
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        try: os.killpg(process.pid, 0)
        except ProcessLookupError: break
        time.sleep(0.05)
    else:
        try: os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError: pass
        (prep / "composer-group-uncertain").touch()
        raise RuntimeError("Composer descendants remain after command exit; prep root must be retained")
    pid_path.unlink(missing_ok=True)
    active_path.unlink(missing_ok=True)
    if output_path:
        with output_path.open("ab") as log: log.write(output)
    if status:
        raise RuntimeError(f"Composer command failed with exit={status}; see retained safe log")
    return output

run_composer(["install", "--no-interaction", "--no-progress", "--prefer-dist", "--no-scripts", "--no-plugins", "--no-dev", "--working-dir", str(app)], 600, log_path)
assert hashlib.sha256((app / "composer.lock").read_bytes()).hexdigest() == lock_hash, "Composer changed the committed lock"
run_composer(["check-platform-reqs", "--no-dev", "--working-dir", str(app)], 60, log_path)
versions = subprocess.run([str(php), "-r", "require $argv[1] . '/vendor/autoload.php'; echo Composer\\InstalledVersions::getPrettyVersion('laravel/framework'), PHP_EOL, Composer\\InstalledVersions::getPrettyVersion('vlucas/phpdotenv'), PHP_EOL;", str(app)], cwd=app, env=env, check=True, text=True, capture_output=True)
assert versions.stdout.splitlines() == ["v13.39.0", "v5.8.0"], "locked Laravel package version mismatch"
fixture_hash = hashlib.sha256("".join(f"{p.relative_to(fixture)}:{hashlib.sha256(p.read_bytes()).hexdigest()}\n" for p in sorted(fixture.rglob("*")) if p.is_file()).encode()).hexdigest()
composer_version = run_composer(["--version", "--no-ansi"], 20, log_path).decode().strip().split()
assert composer_version[2] == "2.9.8", "expected Composer 2.9.8"
probe_path = Path.cwd() / "Scripts/tests/fixtures/laravel-connection-probe.php"
summary = [
    "result=PASS",
    "php=8.4.27",
    f"composer={composer_version[2]}",
    f"laravel={versions.stdout.splitlines()[0]}",
    f"phpdotenv={versions.stdout.splitlines()[1]}",
    f"composer_lock_sha256={lock_hash}",
    f"fixture_sha256={fixture_hash}",
    f"probe_sha256={hashlib.sha256(probe_path.read_bytes()).hexdigest()}",
]
(Path(evidence) / "preparation.txt").write_text("\n".join(summary) + "\n")
print("Laravel dependency preparation passed for PHP 8.4.27, Laravel v13.39.0, and phpdotenv v5.8.0")
PY

VAELEN_TEST_LARAVEL_APP_ROOT="$PREP/app" \
VAELEN_TEST_LARAVEL_PROBE="$PROBE" \
VAELEN_PROJECT_DATABASE_EVIDENCE_DIR="$EVIDENCE/integration" \
Scripts/tests/val-project-database-provisioning-test.sh
printf '%s\n' 'result=PASS laravel=13.39.0 phpdotenv=5.8.0 cache=uncached,cached secret=not-retained' >> "$EVIDENCE/preparation.txt"
