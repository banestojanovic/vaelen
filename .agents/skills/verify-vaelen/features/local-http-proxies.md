# Manage local HTTP proxies

The local proxy feature is implemented. Its installed Settings create/remove journey was accepted on 2026-10-24; the broader Open and Copy URL actions still need installed UI review.

## Current checks

Run the focused checks from the repository root:

```bash
swift test --skip-update --disable-automatic-resolution --filter LocalProxyTests
swift test --skip-update --disable-automatic-resolution --filter LocalProxyEndToEndTests
swift test --skip-update --disable-automatic-resolution --filter testOfficialCaddyForwardsLocalHTTPProxyPathQueryAndErrorStatus
swift test --skip-update --disable-automatic-resolution --filter ProtocolTests
swift test --skip-update --disable-automatic-resolution --filter HumanOutputTests
swift test --skip-update --disable-automatic-resolution --filter DispatcherTests
swift test --skip-update --disable-automatic-resolution --filter CaddyRouterTests
```

The Core end-to-end test invokes the actual `val proxy` child through a private Core Unix socket. It checks add, repeated identical add, list, invalid input, upstream conflict, same-host non-proxy conflict, removal, persistence across Core restart, preservation of the unrelated route, and refusal to follow an upstream redirect. The official Caddy test uses a separately owned local HTTP upstream and verifies the forwarded path, query, and upstream `418` response. These tests do not prove the complete installed-app journey.

## Required acceptance

## Installed acceptance (2026-10-24)

The installed Vaelen Settings > Network & Security journey added a temporary `.test` proxy to loopback port 39991, showed it as the second configured route, and removed it with the Settings action. `val proxy list --json` agreed after both mutations. The pre-existing `bakalar.test` proxy remained unchanged; upstream reachability was intentionally false because no service listened on port 3001. Exact project, route, and proxy snapshots matched the preflight state after cleanup. Supporting generated evidence in `artifacts/verification/vaelen-five-task-20261024/` was removed during local cleanup.

This verifies installed add/remove and CLI parity only. Open and Copy URL actions and successful upstream forwarding were not part of this installed journey; isolated Caddy forwarding remains covered by the focused automated test above.
