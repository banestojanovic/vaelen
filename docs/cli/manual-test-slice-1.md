# `val` presentation foundation — manual test sheet

These checks were completed through the stable installed `val` after the provenance-reviewed recovery. Canonical signed Vaelen GUI/Core remained healthy; no Core/service restart occurred. Baseline had five linked projects, five routes, and one existing parked root (`/Users/banes/Code`), all unchanged. That root was not parked/unparked during the check.

| Command | Preconditions | Expected output | Expected state change | Safe reversal |
|---|---|---|---|---|
| `val list` (also `val --help`) | CLI points at this release candidate; no Core connection required. | Same catalog from both forms; includes only implemented commands and `list`; advertises `parks` as roots, not discovered sites. | None. | None. |
| `val links`; `val links --json` | Core available; five existing links are baseline read-only data. | Human header and aligned rows; JSON object `{projects:[...]}` unchanged. | None. | None. |
| `val parks`; `val parks --json`; `val paths` | Core available; capture existing roots first. | `parks`/`paths` describe registered roots, human or JSON. They are not Herd `parked` discovered-site results. | None. | None. |
| `val route list`; `val route list --json` | Core/router available; capture five route records first. | Human routes include hostname/target/TLS; JSON `{routes:[...]}` unchanged. | None. | None. |
| `val status`; `val status --json`; `val doctor`; `val doctor --json` | Core/services in expected state. | Status/Doctor human reports; JSON parseable and ANSI-free. Pipe output remains uncolored. | None. | None. |
| `COLUMNS=40 val list`, `COLUMNS=40 val links`, `COLUMNS=40 val route list` | Pipe output; `COLUMNS=40`. | No human-output line exceeds 40 columns; values are wrapped rather than dropped. | None. | None. |
| `NO_COLOR=1 val doctor`; `TERM=dumb val doctor` | Core available. | No ANSI escapes. | None. | None. |
| `val php resolve --path` | Effective PHP resolver available in Core and current working directory. | Exactly one plain filesystem path; no heading or ANSI. | None. | None. |
| `val php exec -- -r 'echo "child-stream\\n"; exit(7);'` | PHP available; run in a disposable/current safe directory. | Exact child output, no Vaelen prefix/color; exit code 7 propagated. | No files or Vaelen state expected. | None. |
| `val status --bad`, `val list --json`, `val php versions --json extra` | No service mutation occurs; run with stdout/stderr captured. | Usage/error on stderr, plain when piped; invalid syntax exits 1. | None. | None. |

## Recorded installed acceptance

- Stable path: `~/.local/bin/val` → `~/Library/Application Support/Vaelen/bin/val`.
- Installed executable SHA-256: `871238091ab2c5a090122e3b3357d8f0441ef14296b1d78833d7c54f8b53e275`.
- Ownership-record file SHA-256: `4d8228630036705eedd7eaaf8b1ba3843a26212deb8bedabb6960bd1ad9ca39c`; record content equals installed executable SHA-256.
- Pre-recovery binary and record copies plus transaction manifest remain in `~/Library/Application Support/Vaelen/bin/.val-recovery-20260925T130344Z-11463/`.
- All commands above were run through the installed path. JSON was parsed; terminal-line width checks passed at 40 columns; child output including its intentional ANSI sequence was byte-for-byte preserved and exit code 7 was propagated. Invalid `status --bad` exited 1.
- Artifacts: repository `artifacts/cli-slice1/installed-final/`; complete parity matrix: `docs/cli/herd-parity.md`.

For a future, separately reviewed stable-CLI mismatch, normal `Scripts/install-cli.sh` still refuses by default. The special `--recover-known-replacement` requires exact pins for the observed binary hash and recorded owner content, the known stable symlink, matching Vaelen build identity, and a reason; it preserves both old files and writes a rollback journal. Do not use this recovery option for an unowned or otherwise unexplained executable.

For every read-only test, compare Core linked projects, parked roots and all route records before/after. Do not use park/unpark, route mutation, trust controls or service lifecycle commands as formatting probes.
