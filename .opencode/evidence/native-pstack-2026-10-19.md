# Native pstack configuration evidence

Runtime: OpenCode2 `2.0.32`, normal interactive TUI, project `/Users/banes/Code/apps/vaelen`.

## Observed

- Effective config contains `vaelen-primary` Luna, `vaelen-judgment` Sol, Luna worker and reviewer, all with `medium` variants. Global config contributes only `$schema`; no global agent or permission overrides were present.
- Live catalog contains `openai/gpt-6-luna` and `openai/gpt-6.1-sol`; it does not contain the exact `Muse Spark 1.3 Free` model.
- Parent session `ses_ead0736edffeF8yHseIJRV6lpD` identifies `vaelen-primary` / `gpt-6-luna`, but the exported session variant is `default`, not `medium`.
- That separate TUI test launched two `vaelen-worker` background sessions. Their exported intervals overlap: `ses_ead07058bffeij7pD5zkV8jXS5` ran 07:03:31–07:03:42 UTC and `ses_ead06f1a9ffefVBbiN5MlMGhBZ` ran 07:03:36–07:10:52 UTC. Both exports show `gpt-6-luna`, variant `medium`, and completed/idle status. The first returned `VaelenCoreTests` as the target; the second created `.opencode/evidence/worker-proof.txt` with `worker completed` and verified the content. Both results are now collected from their session exports.
- The parent invoked `swift test --filter VaelenCoreTests.ProjectSiteURLTests`. The output contains 14 `ProjectSiteURLTests` passing and zero failures. This command was allowed without an OpenCode permission prompt.
- The parent export contains an errored subagent call after the two background launches; its last message said it would wait, but the parent TUI was interrupted before it collected and reported both results. This external reconciliation verifies the child records, but normal-TUI parent collection, final reporting, and notification remain unproven.

## Capability limits

- OpenCode2 2.0.32 has no configured automatic provider-error fallback. Its model-selection fallback applies when a model is unavailable during session setup, not after a provider request fails. No controlled provider failure was induced.
- The exact free Muse model is absent, so no fallback model was configured or substituted.
- The project TUI notification hook is present, but event delivery was not exercised in this run.

## Verdict

Configuration and the focused Swift test are verified. Two Luna Medium workers did overlap, complete, and return results; the parent TUI did not collect them before interruption. Full requested acceptance is **not** established: primary-session Medium use, controlled failure behavior, and normal-TUI completion notification/reporting remain unproved. Do not treat this record as a claim of full acceptance.
