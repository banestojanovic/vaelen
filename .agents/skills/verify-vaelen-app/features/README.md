# Vaelen app verification map

These are native macOS Settings journeys. A fixture-backed journey covers visible rendering and sidebar navigation, not live Core state. Record executions and boundaries in the run evidence.

| Journey | User-visible result | Boundary |
| --- | --- | --- |
| [Services inventory](services.md) | Installed and Available tabs reflect presented service inventory | Fixture inventory does not exercise installation or live Core reads |
| [PHP runtimes](php.md) | PHP versions, defaults, and runtime settings are visible | Fixture data; package update/install/remove are guarded |
| [Projects](projects.md) | Project settings page opens; the popover offers a direct link action when Core confirms no projects | Fixture project inventory is not persisted or Core-backed; the popover empty state requires live Core |
| [Network & Security](network-security.md) | Network and security page opens with visible state and grouped controls | Fixture data does not exercise DNS, routing, trust, or privileged operations |

The initial PHP Settings run built and launched the isolated app, and the doctor confirmed the fixture PID, executable path, and arguments. CUA refused app access with `Computer Use was not approved to use Vaelen`, so sidebar navigation and the rendered PHP state remain unverified. See `artifacts/verification/vaelen-app-proof-retry-20261021/` for retained launch and cleanup evidence.
