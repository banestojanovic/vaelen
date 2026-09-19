# ADR-0013: Core-Authoritative Local TLS Trust Operations

* **Status:** Accepted
* **Date:** 2026-09-19
* **Decision owners:** Vaelen maintainers

## Context

Vaelen.app previously performed local CA trust mutation directly through
`LocalCATrustService`. That made the GUI a second mutation authority beside
Vaelen Core and allowed the client to derive the certificate identity from a
filesystem path. CLI and GUI must instead use the same authoritative Core
capability.

M13 is limited to the exact Vaelen-managed CA in the macOS per-user trust
domain. System/admin trust, privileged-helper packaging, route lifecycle,
DNS, ports, services, and generic trust/workflow infrastructure are not part
of this decision.

## Decision

Vaelen Core is the sole authority for local CA trust operations:

```text
Vaelen.app ─┐
            ├── typed IPC ── vaelend Core ── TLS capability ── macOS .user trust
val ────────┘
```

The semantic operations are parameterless:

* `tls.trustLocalCA`
* `tls.removeLocalCATrust`

Clients do not provide a path, certificate bytes, fingerprint, key tag,
Keychain identifier, or private-key material. Existing `tls.install` and
`tls.remove` retain their TLS material lifecycle meaning; semantic untrust
does not delete CA or key material.

## Exact Managed Identity

Core derives identity from its managed TLS state and verifies:

1. canonical DER certificate data;
2. SHA-256 fingerprint of that DER data;
3. the managed Keychain private key;
4. the certificate public key;
5. the public key derived from the managed private key.

Certificate and private-key public keys must match. Path, subject, common
name, and application tag are metadata and corroboration only; none is an
authority by itself. Private-key material is never exported or persisted.

## Trust Domain and Canonicalization

M13 operates only in `SecTrustSettingsDomain.user`. It does not install or
remove system/admin trust and does not introduce a privileged helper.

Trust settings are interpreted semantically, not by hashing arbitrary CF or
plist serialization. The supported empty trust-settings array is represented
as:

```text
trust:empty-array
```

No settings are represented as `trust:nil`. Unsupported, malformed, or
ambiguous settings block mutation and removal. The observed empty-array
fingerprint used by the implementation is:

```text
92f3a5af702e055ab7849f2a058a64a30435a89c299bddd7a9367200f28b774f
```

## Durable Ownership and Provenance

The singleton `tls_capability` record uses schema 6 and stores the exact CA
identity, managed path and key tag, matched public-key fingerprint, ownership
state, trust domain, trust provenance, and semantic trust-settings fingerprint.

Ownership states are explicit and fail closed. Trust provenance is limited to:

* `none`
* `confirmedByVaelen`

`confirmedByVaelen` is persisted only after Core has verified the exact owned
CA, observed it untrusted, invoked the `.user` trust operation, received API
success, re-observed the exact supported trusted settings, and durably saved
the evidence.

An already-trusted CA with provenance `none` is not adopted and does not gain
Vaelen removal authority. Repeating an idempotent trust call cannot manufacture
provenance.

## Migration

Schema 5 migrates transactionally to schema 6. Legacy `active` is not
interpreted as desired trust, current trust, ownership, or provenance.
Legacy records begin with user trust domain, unverified ownership, provenance
`none`, and no trust-settings or public-key fingerprint. Migration performs no
trust mutation and malformed migration state rolls back.

## Removal and Failure Semantics

Semantic trust removal requires all of:

* exact owned certificate/key identity;
* provenance `confirmedByVaelen`;
* currently observed user trust;
* exact match with the recorded semantic trust-settings fingerprint.

Core re-observes after removal and clears provenance only after verified
absence. API success alone is not completion. Certificate, private-key, leaf,
and unrelated Keychain material are preserved.

If trust succeeds but Core fails before provenance persistence, restart reports
trusted state with provenance `none`; destructive removal remains blocked.

If removal succeeds but Core fails before clearing provenance, restart observes
untrusted state and may clear stale provenance without invoking removal again.

No pending or transition state is introduced, and no automatic trust or
untrust reconciliation occurs.

## Clients and Compatibility

IPC compatibility is schema 5. Trust results and failures are typed. CLI
commands are `val tls trust` and `val tls untrust`; both use Core IPC only.
Vaelen.app uses `VaelenCoreClient` for trust and untrust and has no direct
Security.framework trust-mutation path or fallback.

The M13 development identity is:

```text
product version: 0.0.14-dev
build identity: m13-core-authoritative-tls-trust-schema-5
SQLite schema: 6
IPC schema: 5
```

## Privilege Boundary and Evidence

An isolated disposable Standard macOS account (UID 502) and the M13 product
path both completed `.user` trust and untrust while the Vaelen daemon ran as
that ordinary user. macOS authorization UI was observed during the exercise.
The exact number and timing of authorization prompts was not measured
reliably and is not treated as acceptance evidence.

macOS authorization/consent UI is distinct from Vaelen executing as an
elevated identity. This empirical result applies only to M13 `.user` trust;
it does not generalize to system/admin trust or remove the broader Proposed
ADR-0006 constraint that genuinely privileged operations require a narrow
privilege boundary.

## Verification

Deterministic tests cover migration, identity binding, trust and removal
failure matrices, persistence and restart windows, actor serialization, IPC
client/dispatcher paths, and CLI/GUI authority surfaces. M13 product-path
acceptance independently verified install, trust, restart, repeated trust,
untrust, material preservation, and final restart state in the disposable
UID-502 account.

## Non-Goals

M13 does not include:

* system/admin trust;
* privileged-helper packaging or signing;
* arbitrary certificate trust;
* automatic re-trust or reconciliation;
* CA replacement workflow;
* generic trust, ownership, or transition frameworks;
* route, PHP, service, DNS, PF, port, packaging, or M14 work.
