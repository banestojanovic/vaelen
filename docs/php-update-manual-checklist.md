# Manual checklist — update activity, completion, and menu-bar refresh

Against the installed signed app. No manual Refresh, restart, or reopening
should be needed for anything below.

## Installation activity

1. **Settings → PHP**, install or update any family (leaving the live 8.4.24
   default in place is fine — use 8.2.33 install or 8.5.x if offered).
2. While downloading: a determinate bar with a live percentage and transferred /
   total bytes, naming the CLI/FPM archives.
3. After 100%: the bar must not freeze as the whole story. Expect a visible
   sequence — **Verifying package… → Installing PHP… → Starting PHP…** (when the
   replacement starts) **→ Updating project routing…** (when routes converge) —
   each with a small activity indicator. "Download complete" may appear only as
   clearly labelled finished context.
4. Cached reinstalls finish fast with a truthful "Using verified cached
   downloads" note — no artificial slowness.

## Accurate completion

1. A fully successful update shows a success message naming the replacement and
   selects it, showing its exact version, settings, paths, running state, and
   default role.
2. Start, Stop, Make Default, Remove, Install, and Update each read differently
   when done — a finished default switch must never say "installed successfully".
3. If routing or startup does not converge, expect a specific partial-success
   message plus **Retry convergence** — not "operation failed", and not a silent
   success. Retry finishes the work without reinstalling.
4. A stale error from an earlier attempt must never sit beside a newer success.

## Automatic menu-bar refresh

1. After any PHP state change (install, update, start, stop, default switch),
   open the menu-bar popover: service state, default/runtime indicators, and
   project PHP badges must already be current.
2. Project rows that inherit the default follow the new default; explicitly
   pinned projects keep their exact version.
3. No manual Refresh, app restart, or popover reopening required. (Report
   refresh runs asynchronously after the operation completes; it never extends
   the installation activity itself.)

## Completed Syncproof repair and package cleanup

On 2026-10-02, the explicitly authorized repair associated Syncproof's existing
route with its linked project and reconciled through project activation. Route
identity and TLS settings were preserved; trusted HTTPS returned 200.

After confirming they were not pinned, serving routes, running, or default,
PHP 8.3.29 and 8.4.23 and their generated instance directories were removed.
Saved settings were preserved. Final installed smoke passed with default
8.4.24 and working ports 80/443. The earlier orphan-route 502 is resolved;
do not repeat route repair or cleanup as part of manual visual review.
