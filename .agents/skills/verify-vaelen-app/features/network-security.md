# Network & Security

## Sub-features

- Inspect local routing, proxy, DNS, TLS, and security status.
- Browse the page's user-visible controls.
- Inspect labeled proxy inputs and contextual **More** menus for removal actions.

## How to get to it (user POV)

Open Vaelen Settings and choose **Network & Security** under Development.

## Driving it with CUA

Launch the `partial` Debug fixture, choose **Network & Security**, and capture the page with its fixture marker. Observe the rendered state and available controls. Do not change trust, routes, proxies, DNS, or ports.

## Gotchas

Rendered fixture state is not a live resolver or router check. This recipe does not exercise Keychain, privileged helpers, route reconciliation, DNS listeners, or proxy persistence. Refresh is a single page-level action; capability cards expose their controls without repeating refresh buttons. Use [verify-dns-lifecycle](../../verify-dns-lifecycle/SKILL.md) for DNS ownership lifecycle checks.
