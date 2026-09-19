# M12 Freeze Acceptance

## Milestone

**M12 — Project PHP Route Target Convergence**

Release version: `0.0.13-dev`
Build identity: `m12-php-route-target-convergence-schema-4`
SQLite schema: `5`
IPC schema: `4`
Architecture decision: [ADR-0012](adr/ADR-0012-php-route-target-convergence.md)

M12 is frozen and complete. No M13 work is included in this release.

## Proven Behavior

* A linked registered project with an exact durable M11 `ProjectID` route
  association is the mutation authority.
* The declared PHP family resolves to an exact eligible Vaelen PHP package.
* Current and desired FastCGI target ownership must be proven.
* Caddy must be observable, healthy, and semantically agreed with durable
  state before mutation.
* A stopped, unhealthy, unreadable, malformed, or semantically unsupported
  provider blocks mutation.
* PHP-FPM's desired target must be healthy.
* Target execution uses an exact `RouteID` and never implicitly starts Caddy.
* M12 does not create routes, associate routes, mutate document roots or TLS,
  install PHP, adopt external targets, mutate Laravel/application state, or
  stop an old shared FPM runtime because a route moves away.

## Convergence And Recovery

SQLite `RouteIntent` is durable desired route truth; live Caddy is observed
provider truth. Provider equality is semantic rather than raw JSON equality.

When persisted, provider, and desired targets are equal and prerequisites are
healthy, `route.php-target` is satisfied/non-executable. The strict no-op
performs no RouteIntent write, transition creation, Caddy apply/load, or PHP
restart.

An authorized transition persists the desired RouteIntent and exact durable
RouteID/ProjectID provenance atomically before applying the full desired Caddy
configuration. Core then observes and verifies semantic convergence before
completing the transition. Persistence failure leaves the provider untouched;
provider failure leaves the desired state and pending provenance durable. Retry
and restart finalize only an exactly explained authorized divergence. Stale,
malformed, or unexplained divergence fails closed.

The transition record is narrowly scoped to PHP route-target convergence. It is
not a generic workflow, transaction, rollback, provider-cache, or job system.

## Live Acceptance Evidence

Syncproof:

* ProjectID: `02D5F0AF-6259-46AB-9875-2D5B7E2838E6`
* RouteID: `484F36C5-6DBD-4D48-9FC6-012926D32D14`
* Hostname: `syncproof.test`
* Document root: `/Users/banes/Code/syncproof/public`
* TLS: `local`
* Declared PHP: `8.4`
* Resolved PHP: `8.4.23`
* FastCGI target: `php-8.4.23.sock`

Live convergence was proven:

```text
persisted == provider == desired == php-8.4.23.sock
```

Current and desired target ownership were proven. No route-target transition
was present.

The strict no-op activation left RouteIntent, Caddy configuration and PID, and
PHP-FPM PID unchanged. No M12 Caddy apply/load or PHP restart occurred.

The public product path was exercised without host overrides or backend-port
substitution:

```text
syncproof.test
  -> Vaelen DNS
  -> public 80/443 through existing PF integration
  -> Caddy
  -> PHP-FPM 8.4.23
  -> Laravel
```

Observed results:

* `http://syncproof.test/integrations`: `308` to HTTPS.
* `https://syncproof.test/`: Laravel `302` to `/integrations`.
* `https://syncproof.test/integrations`: Laravel `302` to `/login`.
* PHP execution: `X-Powered-By: PHP/8.4.23`.
* TLS: trusted, `ssl_verify_result=0`.
* MySQL: Vaelen-owned `8.4.11`, healthy at `127.0.0.1:13306`.

Final Caddy configuration hash:

```text
13165d5e800a26c0473ae98441de33924c30dd92ff3372ad425178e6fb975127
```

Syncproof files remained unchanged:

```text
.env       09fe8e715a270dd96893b64a2dd1b9c3a92ac07a60ed3ada5dcfee60e25d1c3c
vaelen.yml b77b28c7faf497f7887d2dc263841372047b5be03850ae5d9286710e61e585b2
```

## Regression Gate

* `swift build`: passed.
* `swift test`: 143 passed, 1 skipped, 0 failures.
* Xcode package build: passed.
* `git diff --check`: passed.

M12 is ready for ADR freeze, milestone documentation, commit, tag, and push.
