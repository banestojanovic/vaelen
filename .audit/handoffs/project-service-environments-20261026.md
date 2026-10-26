# Handoff: Vaelen project service environments — 2026-10-26

## What closed today

Completed the isolated live-Core adoption acceptance in the native Debug Settings app. A disposable linked project was reviewed, a deliberately stale review was rejected without mutation, and a fresh review was explicitly applied with PHP 8.4, Node 20, no route, PostgreSQL `adoption-db` (`postgresql-18.6`) as `database`, and Valkey `adoption-cache` (`valkey-9.1.2`) as `cache`.

Core verified the V2 declaration and exact service claims. The synthetic `.env` hash remained unchanged. No database or cache process was started. The exact app and embedded Core were stopped, and the token-owned scratch tree was removed. Full run evidence and the outcome are in `artifacts/verification/native-project-adoption-live-core-20261026-r3/`.

The repeatable isolated helper is now in `.agents/skills/verify-vaelen-app/scripts/ProjectAdoptionUIAcceptance/` and is exposed by `.agents/skills/verify-vaelen-app/scripts/project-adoption-ui-core`. Its Swift product/target is registered in `Package.swift`. A single independent, read-only Sol review was completed before the live run.

## Next work session: continue toward the full Herd replacement goal

This acceptance closes the adoption UI/Core gate only. The goal remains open. Suggested next feature-sized unit:

1. Add explicit MySQL and Mailpit project bindings to the V2 manifest and Core validation/reconciliation, preserving existing MySQL/Mailpit ownership and lifecycle behavior.
2. Add IPC and `val project up/down` coverage for those bindings, including shared-owner and failure recovery cases.
3. Add native Settings display/review coverage so project bindings show exact aliases and instance identity without secrets.
4. Verify a disposable full project workflow through the installed Vaelen app, including a working trusted HTTPS site and `.env` preservation.
5. Close packaging, update/backup/recovery, and removal gaps listed in `.audit/project-service-environments.todo.md` before calling the Herd replacement goal complete.

Start by reading `.audit/project-service-environments.todo.md`, `.audit/project-service-environments.tsv`, and `docs/current-development.md`; preserve the existing dirty workspace and keep the next change scoped. The user requested one reviewer by default, with a larger panel only for a genuinely complex integration or major bottleneck.

## Session environment

No Rex tabs were opened for this work. The existing app acceptance ran through CUA against the exact isolated app bundle. The broader product work is not complete; resume with the MySQL/Mailpit binding gap and re-evaluate the goal checklist before implementation.
