# Provisioning correction design

## Decision

Use candidate A's dedicated operation-ID retry request. The immutable receipt remains the only source of database name, user name, project binding, service record, cluster identity, and credential reference. Candidate B's operation-ID-only retry shape is retained, but the retry policy stays explicit in Core instead of replaying the Create method implicitly.

The read-only design judge scored candidate A 11/12 and candidate B 7/12. Candidate A made retry eligibility, exact-target checks, and PostgreSQL logging requirements explicit. Candidate B's smaller sketch left effect evidence and lock scope underspecified. See the [rubric](rubric.md), [candidate A](candidate-a/README.md), and [candidate B](candidate-b/README.md).

## Scope trims and grafts

- Keep receipt eligibility checks local to the provisioner. Do not add a general receipt-operation framework unless the implementation proves that the helper removes duplicate policy.
- Keep one focused module method for checking the saved service record and live cluster identity under the module lock. Status, retry, and reveal may call it, but the dispatcher remains the project and claim policy owner.
- Check database and user collisions before creating or loading a credential. If a retry finds a collision, transition the existing receipt to `refused` and release its reservations. Transition to `prepared` only after the original Keychain item is available.
- Allow repeated pre-DDL failures to remain `failedBeforeDDL` without changing the receipt ID or request. Reject retry when any pending, confirmed, or uncertain engine effect exists.
- Set and read back PostgreSQL statement, duration, error, and sampling controls in the same session before password SQL. Refuse unsupported preload or audit hooks. Verify the bundled 18.6 runtime. Do not claim that unknown third-party code is safe.
- Seed ready metadata in MySQL and PostgreSQL Settings fixtures so Reveal and Copy render. Add a separate failed-before-DDL fixture for the Retry control. Fixture mode disables every operation handler.
- Add the missing real MySQL user-collision case and verify that neither the existing account nor the requested new database changes.
- Add PostgreSQL role-attribute, wrong-password, and aggressive-log configuration checks where the fixture can prove them without exposing credentials.
- Update the selected design and handoff to describe the delivered command names and fields. Remove narration comments from the retired candidate sketch or replace it with prose.

## Verification gate

Add failing Core tests for successful retry, repeated Keychain failure, and collision after a pre-DDL failure. Add target replacement status tests for changed service records and changed cluster identities. Add PostgreSQL tests that prove logging controls are applied and checked before secret SQL and that unsupported hooks refuse the operation. Run both actual engine acceptance scripts and inspect both Settings fixtures through CUA.

Do not retry `pendingEffect` or `needsAttention`. Do not delete or roll back engine objects. Keep `.env` unchanged. Do not commit until the live, Settings, and review gates pass and the user confirms.
