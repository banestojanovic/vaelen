# Native pstack configuration evidence

Runtime: OpenCode2 `2.0.32`, normal interactive TUI, project `/Users/banes/Code/apps/vaelen`.

## Observed

- Effective config contains `vaelen-primary` Luna, `vaelen-judgment` Sol, Luna worker and reviewer, all with `medium` variants. Global config contributes only `$schema`; no global agent or permission overrides were present.
- Live catalog contains `openai/gpt-6-luna` and `openai/gpt-6.1-sol`; it does not contain the exact `Muse Spark 1.3 Free` model.
- Parent session `ses_ead0736edffeF8yHseIJRV6lpD` identifies `vaelen-primary` / `gpt-6-luna`, but the exported session variant is `default`, not `medium`.
- That TUI task launched two `vaelen-worker` background sessions. Child `ses_ead07058bffeij7pD5zkV8jXS5` returned `VaelenCoreTests` as the test target. Child `ses_ead06f1a9ffefVBbiN5MlMGhBZ` did not return its requested edit/result; `.opencode/evidence/worker-proof.txt` was not created. Therefore concurrent completion and collection are not proven.
- The parent invoked `swift test --filter VaelenCoreTests.ProjectSiteURLTests`. The output contains 14 `ProjectSiteURLTests` passing and zero failures. This command was allowed without an OpenCode permission prompt.
- The parent export contains an errored subagent call after the two background launches; the parent did not provide a final report before the TUI was interrupted. Completion reporting and notification are not proven.

## Capability limits

- OpenCode2 2.0.32 has no configured automatic provider-error fallback. Its model-selection fallback applies when a model is unavailable during session setup, not after a provider request fails. No controlled provider failure was induced.
- The exact free Muse model is absent, so no fallback model was configured or substituted.
- The project TUI notification hook is present, but event delivery was not exercised in this run.

## Verdict

Configuration and the focused Swift test are verified. Full requested acceptance is **not** established: primary-session Medium use, successful two-worker completion/collection, controlled failure behavior, and completion notification/reporting remain unproved. Do not treat this record as a claim of full acceptance.
