# Rationale for candidate A

The linked project must be the real Laravel application before the reviewed apply happens. Copying only generated values to another app proves a different workflow. The existing XCTest already owns the database, account, private Core, review token, linked project, credential, and recovery. Extending that single journey adds the missing consumer without duplicating provisioning or weakening the existing refusal and cleanup cases.

A tracked official application snapshot and committed Composer lock fix the inputs while avoiding a committed vendor tree. The shell installs dependencies once under the runtime that executes them. An isolated Composer home and cache bound network and filesystem effects to a disposable root. This trades a modest fixture footprint and lock maintenance for a repeatable acceptance. Running unpinned `composer create-project` on each acceptance would make a network success insufficient evidence of stable coverage.

The expected JSON is independent of both parsers. Swift already knows the requested account and fixture port and holds the explicit reveal result. Laravel must agree with those inputs. The old generated-value parser and PDO tests continue to provide their original checks, but they cannot determine whether phpdotenv interprets the file correctly.

A fresh process for each phase prevents PHP's in-memory environment repository from carrying values across boots. Hiding the actual applied `.env` during the cached probe makes cache use distinguishable from a second uncached parse. Restoring the same file before Core recovery keeps the existing restore/discard and exact-byte assertions meaningful. No synthetic dotenv replaces val output in either successful runtime phase.

Using Laravel's database manager for `SELECT 1` catches a correct config assertion paired with a broken or overridden connection. Existing PDO migration and neighboring-database checks remain because they exercise authorization and persistence beyond config loading.

Prove It Works changed the design from byte parsing alone to real console-kernel boot and a cached run without `.env`. Test Behavior, Not Implementation changed the oracle to the six user-visible config values and a database query rather than internal bootstrap call counts. Model the Domain changed secret expectations into one private document with explicit phase inputs. Laziness Protocol kept the existing one-test journey and its cleanup owner instead of adding another database acceptance framework.

The design does not require product behavior changes. A genuine escaping mismatch exposed by Laravel becomes a separately reproduced scoped bug fix. The fixture must not conceal it through config edits, synthetic dotenv rewrites, inherited DB environment variables, or a custom loader.
