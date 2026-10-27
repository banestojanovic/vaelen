# Design selection rubric

Score each candidate from 1 to 5 on these criteria.

1. Collision and partial-DDL safety. A preexisting object is untouched. A crash or lost subprocess response cannot cause overwrite, adoption by name, unsafe replay, or compensating data deletion.
2. Secret containment. Keychain owns persisted credentials. SQL and passwords avoid argv, logs, errors, status, ordinary JSON, and project files. Explicit reveal or copy is a separate user action.
3. Caller and ownership clarity. Core validates the exact project binding, record, and claim. CLI and Settings call one operation without coordinating engine steps.
4. Verifiability and scope. The state transitions have focused tests and can be proved against actual MySQL and PostgreSQL packages without modifying unrelated service or project state.

Report a score and one evidence-backed reason for each criterion, then choose a base. Name any required adjustment and any design that should be rejected.
