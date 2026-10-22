# Vaelen app verification map

These are native macOS Settings journeys. A fixture-backed journey covers visible rendering and sidebar navigation, not live Core state. Record executions and boundaries in the run evidence.

| Journey | User-visible result | Boundary |
| --- | --- | --- |
| [Services inventory](services.md) | Installed and Available tabs reflect presented service inventory | Fixture inventory does not exercise installation or live Core reads |
| [PHP release and package notices](php-update.md) | Official security notices remain visible independently of package update actions | Fixture advisories and packages do not prove live php.net checks or package operations |
| [PHP runtimes](php.md) | PHP versions, defaults, and runtime settings are visible | Fixture data; package update/install/remove are guarded |
| [Projects](projects.md) | Project settings page separates workspace folders from searchable linked projects, shows PHP inheritance/override and Node pin/invocation PATH state, and offers a direct popover link action when Core confirms no projects | Fixture project inventory, runtime states, and Node package state are synthetic; live package operations and persistence require Core |
| [Network & Security](network-security.md) | Network and security page opens with visible state and grouped controls | Fixture data does not exercise DNS, routing, trust, or privileged operations |

The isolated fixture build did not complete, and CUA refused app access with `Computer Use was not approved to use Vaelen`. Sidebar navigation and the rendered PHP state remain unverified.
