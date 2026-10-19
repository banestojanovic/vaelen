# Inspect managed logs

Run the isolated end-to-end proof from the worktree root:

```bash
./Scripts/tests/val-logs-ipc-test.sh
```

The script builds only `val` and runs `LogsIPCIntegrationTests`. The test starts a private Core Unix socket with disposable state, invokes the actual worktree CLI to list and tail fixture logs, then compares log and state snapshots. It does not start services or exercise the installed app.

Focused unit coverage is available with:

```bash
swift test --filter 'CoreLogCatalogTests|LogsCommandTests|ProtocolTests'
```

Core tests cover empty, missing, available, non-regular, bounded, and escaping-symlink cases. File reads cap at 128 KiB and requests cap at 10,000 lines. A tail may contain fewer requested lines when the byte cap requires truncation.
