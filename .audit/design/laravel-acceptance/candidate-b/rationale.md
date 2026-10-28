# Why commit the Laravel fixture

The maintainer gets one rerunnable recipe with fixed framework input. The existing private-Core journey remains the only path that provisions a database or manages credentials. The shell prepares a dependency template before secrets exist, and XCTest copies that template into its own cleanup domain.

The structural choice is a committed official application snapshot and Composer lock. Runtime `create-project` would resolve a skeleton and dependencies during each acceptance run. This design pays a larger test fixture diff to remove that source of movement. Composer still downloads locked dependencies, and network errors remain explicit setup failures.

The expected values come from the provisioning request and in-memory reveal. Keeping the old Swift dotenv parser assertions preserves existing coverage, but neither parser results nor a synthetic `.env` feed Laravel's expected config. Laravel boots against the exact file left by the actual apply command.

The cached phase temporarily removes `.env` and launches a fresh PHP process. That gives a direct disproof of accidental fallback to dotenv. Restoring the byte-for-byte file before recovery preserves the existing transaction tests. Deleting cached config before restore also prevents a credential-bearing framework artifact from surviving later fixture steps.

Prove It Works changed the design to require Laravel's console bootstrap, Laravel config lookup, and a database query in both phases. Test Behavior, Not Implementation changed the expected data source to the original request and revealed password. The acceptance cannot pass merely because two copies of Vaelen's parser agree. Both principle leaf skills were read in this session.

This is a design artifact only. Product files were not edited, and the proposed acceptance was not executed by this candidate. Local source inspection confirmed the existing fake artisan, the final actual apply point, the parser-backed PDO flow, and the recovery ordering. The successful Laravel probe's official bootstrap and database config were inspected. Its composer.json contains a `^13.17` framework requirement. Its acquisition reference still needs explicit provenance capture before this proposal can become an implementation.
