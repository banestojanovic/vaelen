# Manual review checklist — PHP families and standard ports

Everything here runs against the installed signed app in `/Applications/Vaelen.app`.
Nothing below mutates projects, routes, TLS state, MySQL data, or your database.

## 1. Bundled offline activation

1. Open **Settings → PHP**.
2. Confirm **PHP 8.5.9** appears as an installation option with no download needed
   on first activation (it ships inside the app).
3. Install it. Progress should be brief and should say it is using the bundled
   package — it should not look like a slow network download.
4. Before you start it, confirm: no PHP-FPM is running, the global default did not
   change, and no project changed.
5. Confirm its settings are editable immediately, without reopening Settings.

## 2. Update discovery

1. In **Settings → PHP**, press **Check for Updates**.
2. Confirm the check reports what it actually knows:
   - a successful check shows versions as current;
   - a failed check shows cached availability with the last successful time and a
     Retry — it must never say "up to date" just because pinned files still exist;
   - patches the provider advertises but Vaelen has not yet verified appear
     separately as *not yet installable*.
3. Leave the app for a few minutes and confirm the periodic check does not
   re-request more than roughly every 12 hours.

## 3. Update a family

1. Confirm each installed runtime shows one row with its exact patch, running
   state, default role, and project use — no second unexplained rows.
2. Confirm the update indicator appears beside **PHP** in the sidebar and beside
   the affected row, with a tooltip naming the target version. It must not sit on
   the default star or the running dot.
3. Press **Update**. Confirm:
   - progress shows a determinate bar with a percentage from the start, both
     archives, and no reset when the second archive starts;
   - after 100% you see one stage message at a time with an activity indicator —
     *Verifying*, then *Installing*, then startup/routing/cleanup work — and
     "Download complete" only as subdued context, never as completion;
   - verified cache reuse says so plainly and finishes quickly.
4. Confirm the completion message names the removed superseded patch.
   **"Installed and ready" must not appear if startup, default handover, routing,
   or cleanup failed** — that case shows the partial outcome plus
   **Retry convergence**, which finishes the work without reinstalling.
5. Confirm the interface selects the **replacement** and shows its exact version,
   settings, paths, running state, and default role.
6. Confirm the superseded patch is gone from the list (package, socket, and
   generated artifacts removed; download cache may remain but never counts as
   installed).
7. Confirm Start/Stop, Update, Make Default, and Remove sit in one compact row
   near the header — no duplicate actions below the configuration form.

## 4. Pins, dependencies, and project pins

1. Pin a project to the older patch, then try updating that line: the update
   must be refused before anything changes, naming the project and the required
   runtime. The pin must be unchanged afterward.
2. Confirm a project pinned to an older exact patch still resolves to that patch,
   with its runtime running and its settings unchanged.
3. Try removing a runtime a pinned project needs, or one still serving a route.
   The product must refuse, name the dependency, and leave everything unchanged.

## 5. Settings preservation across removal and reinstall

1. Note a version's settings, remove that version, and reinstall it.
2. Confirm the same settings come back, and that its saved override relationship is
   unchanged.

## 6. Standard ports

1. Run `val ports status`. If it reports **Needs repair**, the state is a verified
   incomplete Vaelen PF configuration — Vaelen's own anchor is present and correct
   but `/etc/pf.conf` no longer loads it.
2. Run `val ports install`. Approve the normal macOS authorization prompt if one
   appears (the CLI uses the same Core capability as the GUI; the GUI route is
   **Settings → Network & Security → Standard Ports**).
3. Confirm afterwards:
   - `val ports status` reports enabled and forwarding active;
   - HTTP on **port 80** and HTTPS on **port 443** respond;
   - trusted HTTPS for `syncproof.test` and your own `.test` sites works;
   - unrelated `/etc/pf.conf` content is preserved — Vaelen restores only its own
     three-line reference and never rewrites the anchor during a repair;
   - ports keep working after quitting and relaunching Vaelen.
4. If status instead reports a **foreign** anchor or a **different** reference
   directive, that is refused on purpose. Vaelen will not overwrite rules it
   cannot prove are its own, and it will name the specific reason rather than
   reporting "observation unavailable".
