# PHP patch release preparation (2026-10-01)

## Upstream version selection

PHP's official release index reports PHP **8.4.26** released 2026-09-24,
**8.3.33** released 2026-07-30, and PHP 8.5.10 released 2026-08-27. Official
supported-version data lists PHP 8.4 active through 2026-12-31, PHP 8.3 in
security support through 2027-12-31, and PHP 8.5 active through 2027-12-31.
This candidate updates Vaelen's two already-supported minor lines and does not
introduce the new PHP 8.5 line.

Primary references:

- <https://www.php.net/releases/index.php>
- <https://www.php.net/supported-versions.php>
- <https://www.php.net/index.php#2026-09-24-5>

## Workflow ordering and catalog safety

The tagged workflow uses the repository-wide Actions concurrency group
`vaelen-php-release-catalog` with `queue: max` (up to GitHub's 100 queued-run
limit). A tag run publishes only the version-specific release first. The
promotion script then downloads the published manifest and both assets without
authentication and matches the manifest byte-for-byte to the trusted workflow
output, checking each checksum before touching the feed. It reads the current
catalog only after that verification, validates every retained manifest and
re-downloads every retained package for checksum validation, merges the new
version, validates the full candidate, and only then updates the stable catalog
asset. Missing prior assets, malformed metadata, or checksum errors stop the
job without changing the stable catalog. A final anonymous hosted read-back
checks catalog equality and all package checksums.

Stubbed promotion validation is implemented in
`Tests/Scripts/php-catalog-promotion-tests.sh`. It performed two serial release
promotions (8.4.26 followed by 8.3.33) and verified both remained in the feed.
It then injected corruption into the newly published package and into a
previously catalogued package in separate attempts; both promotions failed and
the stable catalog bytes and version inventory remained unchanged. The test
uses isolated temporary release storage plus stub `gh`/`curl`; it makes no
network requests or hosted changes.

## Hosting boundary

An unauthenticated GitHub API request returned repository
`banestojanovic/vaelen` with `visibility: public` and `private: false`. No
visibility setting was changed. Anonymous requests to the proposed catalog and
8.4.26 package URLs currently return HTTP 404 because those assets/releases are
not published. This confirms no authentication challenge but cannot prove
asset retrieval until publication. Both hosted verification scripts use
unauthenticated HTTPS `curl` and will require successful downloads and exact
hashes before/after catalog promotion.

## Publication plan (not authorized yet)

Use these immutable versioned release tags and filenames:

| Version | Tag | CLI asset | FPM asset |
|---|---|---|---|
| 8.4.26 | `php-v8.4.26` | `php-8.4.26-cli-macos-arm64.tar.gz` | `php-8.4.26-fpm-macos-arm64.tar.gz` |
| 8.3.33 | `php-v8.3.33` | `php-8.3.33-cli-macos-arm64.tar.gz` | `php-8.3.33-fpm-macos-arm64.tar.gz` |

Each release also contains `vaelen-php-manifest.json`; each pair embeds its
static-php-cli license directory. The workflow publishes the mutable catalog
asset `php-catalog.json` at the stable HTTPS location:

`https://github.com/banestojanovic/vaelen/releases/download/php-catalog/php-catalog.json`

The catalog tag is `php-catalog`; its asset is replaced only after the workflow
has checked prior release asset bytes against their manifests and validated the
new CLI/FPM binaries and checksums. The release workflow refuses to overwrite
an existing version tag. Protect `php-v*` tags; the workflow refuses to reuse a
version tag so package URLs stay immutable. The `php-catalog` release is a
deliberate mutable alias; its single JSON asset must remain replaceable by the
trusted workflow so its URL stays stable.

## Artifacts and approval gate

Local Apple Silicon builds are complete under stable per-version directories in
`.build/php-8.4.26/` and `.build/php-8.3.33/`. Each pair passed the project's
binary/runtime validation, includes its static-php-cli license directory, and
matches the tabled SHA-256 values. Local artifact checksums are integrity evidence only;
they carry `bootstrap-local-machine` authenticity and are **not publishable**.
The published manifest checksums must be emitted by the trusted GitHub workflow
with `trusted-vaelen-release-manifest` authenticity. Catalog entries must not be
published until the trusted workflow has completed and the exact hosted bytes
have been downloaded and verified.

| Version | Local CLI SHA-256 | Local FPM SHA-256 | Trusted CI/hosted verification |
|---|---|---|---|
| 8.4.26 | `88275d074155f72281181f48e9fa2230216deb42afe4b68aa9b570e729f3f364` | `8937a3494673b5188bd6860f3c8ec47d7e3e0bdb37e1319933c010e927ab2758` | local build passed; trusted CI/hosted verification not run |
| 8.3.33 | `905259811ca019c8d0046d6c80ba58340f415392f2401ab6b1da40aa85a74b3e` | `3238ccc339b8237a60ea1eb068a6501f7fc17275549d83ffee07a1795b2dc993` | local build passed; trusted CI/hosted verification not run |

## Exact source and approval scope

The local candidate branch is
`candidate/php-settings-reconciliation-20261001`, currently based on
`a85b46b10f5b58cdf77223ce8cbb04d6210f7cbe`. That base is also the current local
`dev` ref; the remote `origin/dev` is a different commit. The candidate branch
does not exist on `origin`. There is **no reviewed source commit SHA yet**: all
candidate changes remain uncommitted as explicitly requested. It would be
misleading to name the base commit as the release source or invent a future
commit hash. The trusted workflow must run from one new, reviewed commit on the
candidate branch, and both version tags must point to that exact commit.

To prevent accidental inclusion of unrelated work, prepare that commit in a
clean temporary worktree from the base above and apply only this explicit
allowlist:

```text
.github/workflows/build-php.yml
App/Vaelen/Vaelen/{AppModel.swift,CoreProcessManager.swift,SettingsNavigation.swift,VaelenApp.swift}
Distribution/PHP/{README.md,RELEASE-PREPARATION.md,UPDATE-FEED-PREREQUISITE.md,php-8.3.33.json,php-8.4.26.json}
Scripts/{configure-local-php-distribution.sh,create-php-catalog.sh,create-php-manifest.sh,promote-php-catalog.sh,verify-hosted-php-catalog.sh,verify-php-catalog-assets.sh}
Sources/VaelenCore/{MySQLModule.swift,PHPModule.swift,ProjectEnvironment.swift,VaelenFilesystem.swift,Resources/php-catalog.json}
Sources/VaelenDaemonSupport/CoreRequestDispatcher.swift
Sources/VaelenIPC/Client/{PHPConfigurationEditor.swift,VaelenCoreClient.swift}
Sources/VaelenIPC/Protocol/ProtocolModels.swift
Sources/VaelenIPC/Runtime/CoreEndpointPaths.swift
Tests/Scripts/php-catalog-promotion-tests.sh
Tests/VaelenCoreTests/{MySQLRuntimeLifecycleTests.swift,PHPModuleTests.swift,ProjectSiteURLTests.swift}
Tests/VaelenIPCTests/{PHPConfigurationEditorTests.swift,PHPDefaultSwitchTests.swift,PHPSettingsWorkflowTests.swift}
```

Do **not** include the current local-only edits to
`.opencode/agents/vaelen-pm.md`, `Scripts/vaelen-dev`, or
`Scripts/vaelen-dev-update`, nor `.build/` outputs, logs, or other untracked
files. Review the resulting clean-worktree diff and its tests before assigning
the actual commit SHA. Push only
`candidate/php-settings-reconciliation-20261001` from that clean worktree; do
not push `dev` or modify repository visibility.

Approval requested for this exact publication sequence, once the clean reviewed
commit SHA is available:

1. Create and push the allowlisted source commit on
   `candidate/php-settings-reconciliation-20261001` (base
   `a85b46b10f5b58cdf77223ce8cbb04d6210f7cbe`; exact new SHA to be recorded
   before tagging).
2. Create/push `php-v8.4.26` and `php-v8.3.33`, both targeting that same source
   commit. The trusted workflow creates immutable versioned releases containing
   each CLI/FPM pair and trusted manifest, verifies the hosted assets, then
   serially merges/promotes the stable `php-catalog` release asset.
3. Permit publishing/updating the stable HTTPS catalog at
   `https://github.com/banestojanovic/vaelen/releases/download/php-catalog/php-catalog.json`.

The proposed release tags do not currently exist on `origin`; their package
URLs and the stable catalog URL return anonymous HTTP 404 today. No commit,
branch push, tag, release, catalog upload, or visibility change has been made.
The locally built artifacts above remain bootstrap-local only and must not be
uploaded or represented as trusted workflow outputs. Even after approval and
publication, product update discovery remains pending until the production
catalog check and isolated package update are verified.
