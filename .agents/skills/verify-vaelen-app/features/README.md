# Vaelen app verification map

These are native macOS Settings journeys. A fixture-backed journey covers visible rendering and sidebar navigation, not live Core state. Record executions and boundaries in the run evidence.

| Journey | User-visible result | Boundary |
| --- | --- | --- |
| [Services inventory](services.md) | Installed and Available tabs reflect presented service inventory | Fixture inventory does not exercise installation or live Core reads |
| [PHP release and package notices](php-update.md) | Official security notices remain visible independently of package update actions | Fixture advisories and packages do not prove live php.net checks or package operations |
| [PHP runtimes](php.md) | PHP versions, defaults, and runtime settings are visible | Fixture data; package update/install/remove are guarded |
| [Projects](projects.md) | Project settings page separates workspace folders from searchable linked projects, shows PHP inheritance/override, searchable pinned Node versions, and project database configuration separately from Vaelen MySQL service state; offers a direct popover link action when Core confirms no projects | Fixture project inventory, runtime states, and Node package state are synthetic; live package operations and persistence require Core |
| [Network & Security](network-security.md) | Network and security page opens with visible state and grouped controls; Local Proxies fields show inline validation and gate Add on valid input plus a confirmed list | Fixture data does not exercise DNS, routing, trust, proxy mutations, or privileged operations |

The installed signed app is accessible through native Computer Use after the app is registered as a regular application (`LSUIElement=NO`). A signed update was verified against the live schema-v8 installation, and the Projects selection journey was checked in the installed app. Projects Node/database states and Network & Security proxy validation were inspected in isolated Debug fixtures; other fixture-only Settings journeys still need their page-specific UI checks.
