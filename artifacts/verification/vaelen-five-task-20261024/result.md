# Vaelen five-task session — 2026-10-24

Checkout: `dev` at `6086e730e23d79d0afc42510e252ff1278fcedf6` before this session's documentation and evidence updates. No product source code changed.

## Results

1. **Installed `val site info`: passed.** A disposable Laravel-marker project and PHP Artisan stand-in verified effective child invocation, exact `about --no-ansi` arguments, fixture working directory, output and exit status 7 propagation, zero configured routes, 40-column plain human output, help/invalid argument behavior, and refusal of unsupported project type without child execution. This validates Vaelen's installed dispatch contract; it does not run Laravel itself.
2. **Installed proxy Settings journey: passed.** Added temporary `codex-five-20261024.test` targeting loopback port 39991, confirmed it in Settings and `val proxy list --json`, then removed it in Settings. Existing `bakalar.test` remained intact. No upstream was expected at the test port or at the pre-existing port 3001. Exact project/route/proxy state comparisons passed after cleanup.
3. **Installed menu-bar Projects popover: passed.** Native popover exposed EXPO/LARAVEL/WORDPRESS project groups, six linked projects, six discovered projects, and project actions; list matched `val links`, `val parked`, and `val sites`.
4. **Suite failure investigation: diagnosed, full suite unverified.** Current direct reproduction of `testDiscoveredVersionReusesItsRecordedDigestOnReinstall` fails because the verified cache lacks PHP 8.4.24 and the test explicitly requests `Scripts/refresh-php-catalog-from-provider.sh`. That refresh would download and alter generated package/catalog state, so it was not run. Safe focused tests for `SiteCommandsTests`, PHP process isolation, recorded FPM ownership, and six-route warm/cold switching passed. Historical full-run failures include cache write permissions and other service-sensitive failures; they do not establish a current source regression.
5. **PHP 7.4 source check: no supported artifact found.** Both configured provider feeds were searched; neither contains a PHP 7.4 macOS arm64 CLI/FPM package. Upstream static-php-cli v2 documentation says PHP 7.4 builds are unsupported; PHP's official lifecycle page records end of support on 2022-11-28. No unofficial build was enabled.

## Cleanup and state

The temporary project fixture was deleted. The temporary proxy was removed. `links`, `parked`, and `proxy` JSON snapshots after each UI/CLI acceptance match the preflight captures byte-for-byte. Doctor remained healthy. `git diff --check` passed. CUA inspection left the installed Vaelen app running.

## Evidence

- Installed CLI captures: `site-info-human.txt`, `site-info-exit7.json`, `site-info-invocations.jsonl`, `site-info-unsupported.stderr`, `site-info-help.txt`, `site-info-invalid.stderr`.
- Proxy UI captures: `proxy-added.json`, `proxy-after-ui.json`, `sites-added.json`, `sites-after-proxy.json`.
- Before/after state: `preflight/`, `links-after-*.json`, `parked-after-*.json`, `proxy-after-site-info.json`, `doctor-after.json`.
- PHP feed captures: `php-v2-feed.json`, `php-v3-feed.json`.
- Retained current suite repro: `.audit/test-failures/swift-test.tj4rSh`.
