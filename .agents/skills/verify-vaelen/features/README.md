# Vaelen verification map

These four journeys are the initial map. A recipe is coverage only after a recorded execution. Read the entry for the changed behavior before selecting a focused check.

| Journey | Automated production entry point | Isolated or simulated boundaries | Manual GUI review | Not yet verified by this skill |
| --- | --- | --- | --- | --- |
| [List linked projects](links.md) | Real `val links` child, Unix socket, Core dispatcher, SQLite | Six seeded projects; disabled router, DNS, TLS trust, privileged ports | Linked-project GUI remains manual | Installed app, real routing, full PHP-FPM, CLI link creation |
| [Choose project PHP](project-php.md) | Real Core client serialization and dispatcher | In-memory transport, synthetic PHP package metadata | Project PHP GUI remains manual | CLI selection mutation and GUI interaction |
| [Update PHP](php-update.md) | Dispatcher and socket lifecycle tests exist | Cached real PHP pair, private roots, router doubles | Update GUI remains manual | Not executed by the initial proof; cache required |
| [Browse Settings inventory](settings-inventory.md) | Core presentation model functions | Pure classification, counts, and selection fixtures | Core-backed Settings interaction and rendering require manual review | No GUI interaction proof |
| [Run Composer](composer.md) | Real `val composer` child, private Core PHP resolver, PATH script lookup | Synthetic arm64 Mach-O PHP stand-ins and Composer script stubs | No GUI interaction | No real PHP interpreter or Composer behavior |

The initial proof executes only the links success, controlled mismatch, and owned-child timeout checks. Supplemental runs must record exact commands, status, selected and passed counts, and skips. A skipped prerequisite or zero matching tests is not success. `docs/cli/herd-parity.md` lists intended counterparts, not evidence that they were exercised.
