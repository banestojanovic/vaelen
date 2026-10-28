# Journaled connection setup rationale

## Problem

Developers need an explicit, redacted review before Vaelen writes six database assignments into an existing Laravel `.env`. The file belongs to the developer and can change outside Core. Existing provisioning provides a ready receipt and a Keychain secret, while adoption demonstrates single-use review tokens. Neither existing component owns edits or recovery of an existing secret-bearing file.

## Usage

CLI and Settings call `review(intent, context, now)`, display a redacted presentation, then call `apply(confirmation, freshContext, now)` after approval. `status(context)` reports reconciled recovery. Restore and discard use the same review-and-approve contract. [The design](design.md#usage) gives three caller examples and the proposed CLI flow.

## Shape

One Core owner hides the lossless byte planner and a journaled transaction. The transaction captures the actual `.env` inode, checks it, then publishes into an empty destination exclusively. A durable before-image and the captured inode remain protected until an explicit restore or discard. Recovery derives state from artifact identities and bytes. The journal's phase alone never authorizes a write.

Model the Domain changed the design from boolean recovery flags to `ObservedTransaction` cases. Boundary Discipline kept wire DTOs and unsafe parser errors outside the domain interface. Type System Discipline made password presentation a closed `managedSecret` case and kept secret-bearing types non-Codable. Make Operations Idempotent changed restart behavior to reconcile evidence without automatically reapplying credentials. Separate Before Serializing Shared State gave each transaction its own directory, while the canonical Laravel `.env` remains the one unavoidable shared file.

The three public operations hide substantial filesystem and dotenv policy. The cost is internal protocol complexity and a short interval when `.env` is absent. No CLI or UI caller manages those stages.

## Synthesis decision

Pending parent synthesis. This candidate recommends its whole transaction shape only when preserving the actual racing path occupant justifies the absent-path interval. Its evidence-based reconciliation, closed secret presentation, and bounded concurrency statement can also be adapted to an atomic-replacement base.

## Tradeoffs accepted

- We accept a temporary absent `.env` in exchange for exclusive publication that never overwrites a newly occupied destination.
- We accept a strict writable subset of dotenv syntax and filesystem metadata in exchange for refusing uncertain edits before they happen.
- We accept one retained transaction per project in exchange for avoiding restore chains and accidental deletion of the oldest useful recovery copy.
- We accept protected recovery artifacts within the project in exchange for same-filesystem capture and publication.
- We accept a stated limit on uncooperative open-descriptor writers in exchange for a guarantee the filesystem APIs can actually support. Their captured bytes remain protected.

## Alternatives considered

An ordinary synchronized before-image plus atomic replacement keeps `.env` continuously present and is simpler internally. It loses this comparison because a final hash followed by overwrite-rename can displace a racing external version without retaining it. Its public interface can be equally deep, so the decision depends on the value of that stronger preservation behavior.

Atomic exchange retains the displaced file and keeps `.env` present. It temporarily publishes the proposal before verifying that displaced evidence matched the approval. A second exchange to roll back can displace another external edit, so it does not meet this candidate's never-overwrite-an-occupied-destination policy.

In-place byte editing preserves inode identity but exposes partially written contents and makes crash recovery harder. A deep API would still hide that danger from callers rather than remove it.

A generated include file avoids modifying existing assignments, but exposes Laravel bootstrap changes to every developer. It expands this slice and does not satisfy conventional `.env` setup by itself.

## Open questions and risks

Can the product accept the absent-file interval during apply and repair, given that a Laravel request could read `.env` at that moment?

Can the product accept preservation and later conflict detection for writers holding old descriptors, rather than a strict instantaneous content compare-and-swap guarantee?

Does a project-local protected recovery directory fit the desired backup and version-control behavior, or should a later slice encrypt and move retained copies into Core's state root after commit?

Which Laravel phpdotenv versions must the accepted single-line subset support before implementation begins?

## Next implementation step

Build the pure lossless document planner with a pinned phpdotenv fixture oracle, then test the exclusive publication protocol with crash injection before wiring IPC or Settings.
