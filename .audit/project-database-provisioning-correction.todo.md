# Provisioning review corrections

- [x] Ground retry, status identity, PostgreSQL logging, and fixture flows.
- [x] Sketch two retry API shapes and compare their Core, CLI, and Settings impact.
- [x] Agree on the smallest safe shape and record the decision.
- [x] Implement the review findings, regression coverage, and truthful documentation.
- [x] Scrap or revise any shape that failed tests or expanded beyond the review findings.

Focused test filter passed after the retry transition and collision-reservation tests. Both live acceptance scripts passed. Final MySQL evidence is `/private/tmp/vaelen-project-database-evidence.wrBmbq`. Final PostgreSQL evidence is `/private/tmp/vaelen-project-database-postgresql-evidence.WARFNm` and covers enabled logging, a failing password-bearing statement, active preload refusal, role attributes, wrong-password rejection, and stale status targets. MySQL, PostgreSQL, and corrected retry Settings fixtures were visually inspected through CUA and cleaned. Fixture mode proves rendering only.
