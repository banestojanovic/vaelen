# Vaelen Project Decisions

This file records active project-management decisions only. It does not
replace or amend ADRs.

## D-001 — M14 remains validation-only

M14 is limited to disposable platform/lifecycle validation. Production M14
implementation and ADR-0014 remain unauthorized and unfrozen.

## D-002 — Preserve the repaired-A boundary

Repaired-A is the known-good experiment generation. Preserve its evidence and
do not create B, alter signing identifiers, reset BTM/ServiceManagement state,
or use mutating `launchctl` as part of unresolved historical-cause analysis.

## D-003 — Evidence before causal claims

The missing B artifact invalidates the prior A/B causal conclusion. Future PM
reports must keep artifact provenance, runtime attribution, and causal claims
separate. A failed or invalid experiment is not evidence for its intended
causal hypothesis.

## D-004 — Next bounded boundary

The next candidate is one repaired-A launchd recovery observation using only
the controller's verified `terminate-agent` operation. It must remain
read-only until explicitly authorized, use one termination, and stop on any
identity, ownership, admission, recovery, authorization, or service-state
failure.

## D-005 — Delegation cleanup boundary

The disposable delegation probe is removed after successful PM -> Lead,
nested Lead -> Investigator, and Investigator -> Lead -> PM propagation
observations, including native read-only inspection through the chain. The PM
retains authority to delegate to `vaelen-lead` and the approved read-only
specialists; no mutation authority is added to `investigator`. The
`default_agent` remains `vaelen-pm`, `subagent_depth` remains `2`, and
`vaelen-lead` remains a `subagent`. The malformed/inconsistent Lead YAML
indentation was repaired before Lead became launchable as a subagent; this is
supported by controlled before/after evidence, not direct parser observation.

The disposable probe and failed shell/Git acceptance attempts are recorded as
non-invalidating transport/permission failures. No lifecycle operation,
experiment-controller invocation, production change, frozen ADR change, or
Experiments/ change is authorized by this cleanup.
