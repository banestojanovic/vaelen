# Vaelen app verification map

These are native macOS Settings journeys. A fixture-backed journey covers visible rendering and sidebar navigation, not live Core state. Record executions and boundaries in the run evidence.

| Journey | User-visible result | Boundary |
| --- | --- | --- |
| [Services inventory](services.md) | Installed and Available tabs reflect presented service inventory | Fixture inventory does not exercise installation or live Core reads |
| [PHP release and package notices](php-update.md) | Official security notices remain visible independently of package update actions | Fixture advisories and packages do not prove live php.net checks or package operations |
| [PHP runtimes](php.md) | PHP versions, defaults, and runtime settings are visible | Fixture data; package update/install/remove are guarded |
| [Projects](projects.md) | Project settings separates workspace folders from searchable linked projects, shows PHP and Node selection and database facts, supports Core-token-backed adoption review for undeclared projects, and reviews project start/release plans with refreshed results | Adoption and lifecycle controls are disabled in fixtures; only live Core acceptance verifies token freshness, writes, claims, plan execution, ownership rules, and post-action refresh; fixture inventory and project facts are synthetic |
| [Project database provisioning](project-database-provisioning.md) | Ready MySQL and PostgreSQL receipts render explicit Reveal and Copy actions; failed-before-DDL receipts render Retry | Fixtures disable create, retry, status, reveal, and copy in the buttons and model handlers; they prove rendering only |
| [Network & Security](network-security.md) | Network and security page opens with visible state and grouped controls; Local Proxies fields show inline validation and gate Add on valid input plus a confirmed list; active proxies show separate route and upstream health badges with guidance for an unreachable upstream | Fixture data does not provide live route or upstream evidence or exercise DNS, routing, trust, proxy mutations, or privileged operations; inspect the installed app for current Core health |

The installed signed app is accessible through native Computer Use after the app is registered as a regular application (`LSUIElement=NO`). A signed update was verified against the live schema-v8 installation. The Projects selection journey and the current Core-backed proxy health row were checked in the installed app. Projects Node/database states and Network & Security proxy validation were inspected in isolated Debug fixtures; those fixture checks do not establish live Core proxy health. Other fixture-only Settings journeys still need their page-specific UI checks.
