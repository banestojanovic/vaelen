# M3 Acceptance Evidence

M3 uses Caddy 2.11.4 from the official Caddy release asset. Installation
downloads the artifact and signed checksum files, verifies the checksum
signature with the development-only Cosign adapter, validates SHA-512 and the
arm64 executable, then atomically installs an immutable package at:

`~/Library/Application Support/Vaelen/packages/caddy/2.11.4`

Runtime package resolution is local and exact. Start, stop, status,
reconciliation, and integration tests do not contact GitHub.

## Routing

Core owns persisted desired route intent in the existing SQLite state store
(`route_intents`). Caddy configuration is observed runtime state and is never
the source of truth. Route mutations persist even while routing is stopped;
starting routing reconciles the persisted intent.

The provider boundary is:

`Route` -> `CaddyRouter` -> Caddy Admin API -> Caddy JSON

PHP routes use Caddy's standard `reverse_proxy` handler with the `fastcgi`
transport over the Vaelen PHP-FPM Unix socket. The official binary does not
expose `http.handlers.php_fastcgi` as a JSON module.

## Acceptance

- `alpha.test` and `beta.test` both served through Caddy; removing alpha preserved beta.
- Controlled PHP fixture served through PHP-FPM 8.4.23 at `~/Library/Application Support/Vaelen/runtime/sockets/php/php-8.4.23.sock`.
- `syncproof` `/` reached Laravel and `/login` returned HTTP 200 with the Inertia response.
- Repeated Caddy start/stop was idempotent.
- Restarting only `vaelend` preserved the Caddy PID and reconciled the persisted route.
- Externally terminating the owned Caddy process produced stopped/unhealthy routing state without touching unrelated processes.
- Occupying port 8787 produced a clear port conflict; the external listener remained alive and no Caddy process was created.
- Stopping Core caused routing operations and route mutations to fail through normal Core-unavailable semantics.
- Route intent survived Core restart.

## CLI and IPC

- `routing.status`, `routing.start`, and `routing.stop`
- `route.list`, `route.add`, and `route.remove`
- `val routing status|start|stop`
- `val route list [--json]`, `val route add`, and `val route remove`

The GUI displays Core and routing state. CLI and GUI never access SQLite or
Caddy directly.

## Limits

DNS, `/etc/resolver`, `/etc/hosts`, HTTPS, local CA trust, ports 80/443, and
privileged helpers are outside M3. M4 has not begun.
