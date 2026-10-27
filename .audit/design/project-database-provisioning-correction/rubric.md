# Correction design rubric

Design one retry path for `failedBeforeDDL` attempts and one exact-target validation path for receipt status. Include PostgreSQL session log guards and the fixtures needed to inspect ready-state Settings controls.

Score each candidate from 0 to 2 on each criterion.

1. Reuses the immutable operation request and cannot retry uncertain DDL.
2. Keeps Core as the sole owner of project, claim, service, and cluster validation.
3. Gives CLI and Settings an explicit retry action without duplicating request state.
4. Suppresses and reads back relevant PostgreSQL log settings before secret SQL and rejects unsupported audit logging.
5. Provides direct regression tests for the failure and recovery cases.
6. Makes the smallest coherent change across IPC, CLI, Settings, Core, and engine modules.
