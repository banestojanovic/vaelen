# Manage local HTTP proxies

The local proxy feature is a task candidate. It is not installed or accepted.

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

Settings create, list, remove, and Open or Copy URL actions require manual GUI verification. Do not use an installed app, installed CLI, or live Vaelen state for this recipe.
