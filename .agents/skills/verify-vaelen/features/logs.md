# Inspect managed logs

Run the isolated end-to-end proof from the worktree root:

```bash
./Scripts/tests/val-logs-ipc-test.sh
```

The script builds only `val` and runs `LogsIPCIntegrationTests`. The test starts a private Core Unix socket with disposable state, invokes the actual worktree CLI to list and tail fixture logs, then compares log and state snapshots. It does not start services or exercise the installed app.

This candidate uses IPC compatibility version 7 and requires a matching Core. The isolated IPC script is the supported immediate test. Do not run this candidate CLI against an installed Core that may use an incompatible version.

Focused unit coverage is available with:

```bash
swift test --filter 'CoreLogCatalogTests|LogsCommandTests|ProtocolTests'
```

Core tests cover empty, missing, available, non-regular, bounded, and escaping-symlink cases. File reads cap at 128 KiB and requests cap at 10,000 lines. A tail may contain fewer requested lines when the byte cap requires truncation.

The native Settings → Services viewer reuses the same Core catalog and bounded
tail APIs. Its state model is covered separately by
`swift test --filter VaelenIPCTests.ManagedLogViewerModelTests`; fake-client
coverage does not prove window presentation, clipboard integration, or visual
appearance. Build the actual app with the configured Apple Development signing
identity before manual GUI review.
