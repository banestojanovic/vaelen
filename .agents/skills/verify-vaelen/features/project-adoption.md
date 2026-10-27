# Review and apply project adoption

## Scope

`val project adopt [project] [--json]` asks Core for a redacted, read-only review and a short-lived confirmation UUID. `val project adopt --apply <confirmation> [project] ...` creates a new strict V2 `vaelen.yml` and records only the service bindings named on that command. The apply request must explicitly confirm either `--no-web` or one reviewed existing route with `--web-host`, `--document-root`, `--secure` or `--insecure`, and `--select-route`, or an explicitly reviewed new route with the same complete web fields and `--create-route`.

Core rejects expired or reused confirmations, changed project, route, discovery, or catalog evidence, existing manifests, Herd state, route ownership conflicts, missing explicit PHP or Node choices when those runtimes were detected, and service bindings that do not match an existing catalog instance and package. Manifest creation uses an atomic no-replace operation. Service claims are written in a SQLite transaction. Core removes a newly created manifest if claim persistence fails. Adoption does not read secret values from `.env`, modify `.env`, interpret `herd.yml`, change route ownership, or run service lifecycle operations. Route ownership association remains pending project activation. `--create-route` records `web.createRoute: true` in the manifest and does not mutate route or Caddy state during adoption.

`val project up` is the supported activation command; `project activate` remains an alias. `up` starts only a catalogued PostgreSQL 18.6 instance whose manifest binding, record, endpoint, data directory, and health match. It restores the project's claim before starting. It can associate an unchanged legacy route or create a route only when V2 `web.createRoute` records explicit review of the host, document root, and HTTP/HTTPS mode. Creation requires a `.test` hostname and healthy router, DNS, and standard ports; HTTPS also requires an already trusted Local CA. A failed Caddy apply retains the same durable route identity for retry. `down` releases only this project's claims and retains its developer-owned route. It stops PostgreSQL only when no manual or other project claim remains, then verifies stopped health before releasing the claim. PHP and Node stay running as shared runtimes. Project bindings for MySQL, Mailpit, and Valkey remain unsupported. These commands never edit `.env` or `herd.yml`, silently change TLS trust or unrelated routes, or delete project/service data.

## Focused checks

Run through `Scripts/test.sh`:

```sh
Scripts/test.sh --filter ProjectAdoption
Scripts/test.sh --filter ProjectAdoptionCLIParsingTests
Scripts/test.sh --filter ProjectEnvironmentTests
Scripts/test.sh --filter ProjectReconciliationTests
Scripts/test.sh --filter ProjectAdoptionApplyTests
Scripts/tests/val-project-route-lifecycle-test.sh
```

`ProjectAdoptionApplyTests` covers manifest creation, V1 rejection, `.env` byte preservation, and overwrite refusal. The IPC tests cover successful review and apply, stale discovery evidence, duplicate confirmation use, existing manifest preservation, catalog version mismatch, conflicting route ownership, and reviewed route creation intent without mutation during adoption. The private-Core route fixture invokes built `val project adopt/up/down` children with real Caddy and PHP-FPM, verifies HTTP/HTTPS responses, `.env` preservation, and route retention across down/up. CLI tests cover review and explicit apply parsing plus human output sanitization.

## Coverage limit

The route fixture injects DNS, standard-port, and trust observations and uses `curl -k` for HTTPS. It does not verify system DNS, PF, privileged ports, Keychain trust, or certificate validation against the local CA. It skips when installed Caddy 2.11.4 or a usable installed PHP-FPM package is unavailable. The tests do not cover filesystem failure after manifest creation, SQLite rollback injection, confirmation expiry by waiting, concurrent external manifest creation, or the installed app. This is CLI/Core route acceptance, not complete Herd migration acceptance. Native UI adoption and activation remain future work.
