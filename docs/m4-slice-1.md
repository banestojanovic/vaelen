# M4 Slice 1: `.test` DNS Capability

## Boundary

`vaelendns` is a Vaelen-owned, unprivileged process bound only to `127.0.0.1:53535`. It answers A queries in the `.test` namespace with `127.0.0.1`; it is not a project router or an Internet DNS proxy.

The only privileged system state is `/etc/resolver/test`, with deterministic content:

```text
nameserver 127.0.0.1
port 53535
```

The typed helper boundary accepts only the fixed resolver operation. It rejects unsupported ports and arbitrary paths, content, commands, and ownership claims.

## Conflict And Takeover

An existing resolver whose ownership is not present in Vaelen's ledger is reported as `conflict` and is preserved. Normal install does not replace it. The explicit `--takeover` operation is the development-facing equivalent of “Replace Existing .test Resolver…”; production UX must add confirmation and explanation before invoking the same typed operation.

Takeover records the previous exact content in the system-modification ledger. Removal first compares current content with the exact Vaelen content and refuses on mismatch. The recorded previous state is evidence for a future restoration operation, never authority to overwrite changed external state.

## Development Authorization

The development bridge is enabled only when `VAELEN_ENABLE_DEVELOPMENT_PRIVILEGED_DNS=1` is present. It invokes fixed `sudo -n` operations and never handles passwords. The developer must authorize sudo externally. This bridge must be replaced by the signed Authorization Services/XPC helper installation path before public distribution.

## Commands

```text
val dns status
val dns status --json
val dns install
val dns install --takeover
val dns remove
```

All commands go through `val` and `vaelend`; the CLI never writes `/etc/resolver/test`.

## Verification

Build and M0-M3 regression currently pass. Direct macOS resolver acceptance requires external authorization for the development bridge, then `scutil --dns`, `dscacheutil`, arbitrary `.test` resolution, and the existing M3 route request without a Host override. HTTPS, ports 80/443, and M4 tagging are intentionally out of scope.
