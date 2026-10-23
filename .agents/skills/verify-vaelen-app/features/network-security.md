# Network & Security

## Sub-features

- Inspect local routing, proxy, DNS, TLS, and security status.
- Browse the page's user-visible controls.
- Inspect labeled proxy inputs and contextual **More** menus for removal actions.
- Validate both Local Proxies fields inline after entering both values, reject case-insensitive duplicate hostnames against the confirmed list, and keep **Add Proxy** disabled until the values are valid and Core has confirmed the proxy list.
- Read each active proxy's route and upstream badges separately. Confirm that missing routes and unreachable upstreams need attention, unavailable or unknown readings stay neutral, and prepared or deleting ownership shows a pending badge.
- When an active upstream is unreachable, confirm the row points to the upstream URL above and explains that Vaelen routes traffic but does not start the local server. Keep the Open, Copy URL, and More actions available.

## How to get to it (user POV)

Open Vaelen Settings and choose **Network & Security** under Development.

## Driving it with CUA

Launch the `partial` Debug fixture, choose **Network & Security**, and capture the page with its fixture marker. Enter an invalid hostname and an invalid upstream URL in **Local Proxies**. Confirm each field shows its own inline error and **Add Proxy** remains disabled while the fixture has no confirmed proxy list. Observe the rendered state and available controls. Do not submit the form or change trust, routes, proxies, DNS, or ports.

For the live proxy health row, install the signed app update and inspect the existing configured proxy with native CUA. Confirm the route and upstream badges separately, and check the unreachable guidance against the configured URL. Treat those badges as live Core evidence only in the installed app journey.

## Gotchas

Rendered fixture state is not live route or upstream evidence. This recipe does not exercise Keychain, privileged helpers, route reconciliation, DNS listeners, or proxy persistence. Proxy field feedback reuses Core's `LocalProxyConfiguration` validation contract; duplicate checking needs a confirmed Core proxy list, which this fixture does not provide. The fixture check verifies presentation and disabled state only. The installed app journey reads the current `LocalProxyWire` values from Core. Refresh is a single page-level action; capability cards expose their controls without repeating refresh buttons. Use [verify-dns-lifecycle](../../verify-dns-lifecycle/SKILL.md) for DNS ownership lifecycle checks.
