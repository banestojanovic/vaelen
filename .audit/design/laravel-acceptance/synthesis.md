# Laravel connection acceptance design synthesis

The candidates converge on one live path: prepare an official pinned Laravel app outside the database fixture, seed the same app into the linked project, run the existing private-Core MySQL journey through actual `val project db connection apply`, then boot the framework against that exact `.env` before and after config caching.

## Cross-judge scores

| Criterion | Candidate A | Candidate B | Pick |
| --- | ---: | ---: | --- |
| Actual `val` apply bytes | 5 | 5 | consensus |
| Official uncached and cached Laravel boot | 5 | 5 | consensus |
| Reproducible Composer setup | 4 | 5 | B base |
| Password protection | 5 | 4 | A safeguards grafted |
| Existing Core journey and cleanup | 5 | 5 | consensus |
| Total | 24/25 | 24/25 | B base, A grafts |

## Pick and grafts

Use candidate B's committed official Laravel fixture and lock, exact skeleton provenance, isolated Composer home/cache, sanitized Composer environment, platform check, required Laravel template, one existing XCTest owner, and unavailable-network failure semantics. The lock pins framework `13.39.0` and phpdotenv `5.8.0`. The source was verified against the official `laravel/laravel` tag `v13.11.0`, tag object `06d016a364a37430eec9cbc52209adce3d7667ce`, and source archive SHA-256 `afd5c6f2d147287b6ccc04b505cc673e12bb583ceb4d68c763c5c2646431639d`.

Add candidate A's explicit `0600` and `0700` permission assertions, bounded Composer process-group termination and reap before fixture removal, safe diagnostics that never serialize compared values or raw framework errors, and a controlled secret-output failure check. Compare `.env` restoration with a boolean assertion and fixed message so XCTest cannot dump the password on mismatch.

Both phases use a fresh PHP 8.4.27 process, the real Laravel console bootstrap, the same six independent config expectations, and a real Laravel `SELECT 1` query. The cached phase uses Laravel's official `artisan config:cache`, temporarily renames the actual `.env`, confirms config is cached and the unrelated dotenv marker is absent, then restores the same file before Core recovery. No config values or raw output enter retained evidence.

## Rejected alternatives and limits

Runtime `create-project` plus unconstrained dependency resolution was rejected because it would make each test run resolve moving inputs. A hand-built Laravel config/bootstrap was rejected because it would replace the official skeleton behavior the acceptance needs to exercise. The fixture and lock add tracked test source; vendor files and runtime secrets remain temporary. This verifies one locked Laravel MySQL path, not PostgreSQL, PHP-FPM, HTTP serving, user-specific config overrides, or automatic Laravel cache management.

The cross-judge selected B and identified A's secret and teardown protections as required grafts. No implementation or live acceptance pass is claimed by this design note.
