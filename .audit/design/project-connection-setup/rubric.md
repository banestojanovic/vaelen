# Architecture candidate rubric

Artifact: usage-first architecture sketch, domain types, public Core API, file transaction/recovery model, module map, and rationale for reviewed connection setup.

Score each 1–5 with concrete evidence:

1. **Byte and dotenv correctness:** preserves unrelated bytes and handles Laravel dotenv syntax without silently normalizing ambiguous target keys.
2. **Stale-write and concurrency safety:** binds approval to project, receipt, file identity and bytes; detects external edits at the replacement boundary.
3. **Crash recovery and restore:** every crash point is recoverable or safely refuses; restore never overwrites later edits; recovery data is protected.
4. **Secret containment:** generated password is absent from SQLite, logs, arguments, diagnostics, ordinary IPC/UI output, and unprotected temp/backup files.
5. **Interface depth and fit:** smallest coherent Core-owned API, short call chain, fits actor/IPC/CLI/Settings architecture, and does not expand provisioning scope.

Each candidate must produce a structurally distinct design. Candidate A: targeted byte-preserving `.env` patch with durable before-image. Candidate B: two-phase file transaction/journal design emphasizing filesystem recovery. Both must be free to reject their assigned direction if evidence requires it. Do not edit product source.
