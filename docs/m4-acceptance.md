# M4 Freeze Acceptance

## Objective

The accepted M4 path is:

```text
syncproof.test
  -> Vaelen .test DNS
  -> Vaelen local CA and leaf TLS
  -> PF loopback forwarding on 80/443
  -> user-owned Caddy
  -> user-owned PHP-FPM
  -> Laravel
```

`http://syncproof.test/login` returns a 308 redirect to HTTPS. The supported
HTTPS path is `https://syncproof.test/login` on the browser-facing standard
port 443.

## Real-Machine Evidence

- Chrome and Safari loaded the bare HTTPS URL as Laravel without warnings.
- HTTP returned `308`; HTTPS returned `200`.
- Native `SecTrustEvaluateWithError` hostname validation passed.
- The accepted CA fingerprint remained `4c74cd035220160e58b3f8cde20b327bb14defe2bf5f763b63209ec99ce909dc`; the CA key is retained in Keychain and was not rotated. New CA-key generation explicitly sets the SecKey as non-extractable.
- `vaelendns` was observed on `127.0.0.1:53535` only.
- Caddy was observed as the user account on `127.0.0.1:8787` and
  `127.0.0.1:8743` only.
- PHP-FPM used a Unix socket and remained user-owned.
- Standard Ports reported `healthy`; repeated install was idempotent.
- Removal restored the PF configuration pre-image, removed the Vaelen anchor,
  and preserved unrelated runtime state; reinstall returned to `healthy`.

## PF Finding

On macOS, while the Vaelen rdr anchor is active, direct TCP connections to
the internal target ports `8787` and `8743` can wedge in `SYN_RCVD` because of
PF reverse-association behavior. This does not affect the supported paths:

```text
127.0.0.1:80  -> 127.0.0.1:8787
127.0.0.1:443 -> 127.0.0.1:8743
```

Standard-port health observes 80/443 while forwarding is active. Caddy health
uses its Unix admin socket. Backend ports are implementation details and are
not a supported direct-client interface.

The four direct-backend Caddy integration tests skip only before starting
when the 2-second PF wedge probe is present; a failure after the test starts
remains a failure. They verify static routing/removal, PHP-FPM FastCGI, the
Laravel front controller, and HTTP-to-HTTPS redirect/TLS. The same supported
browser path was accepted on the real machine; CI hosts without the PF wedge
execute the tests normally. Other skips are only missing development
prerequisites or explicitly development-only distribution tests.

## Privilege And Distribution Boundary

The standard-port helper exposes only parameterless fixed-policy operations,
validates the caller's Apple code signature and requires the expected
`dev.vaelen.app` identifier and the same nonempty signing team as the daemon.
It validates the existing fixed anchor before mutation and uses atomic
replacement. The app embeds the daemon and a `BundleProgram` LaunchDaemon plist
for `SMAppService.daemon`. Local Apple Development signing exercises package
structure and code-signing trust; LaunchDaemon registration/approval remains
subject to macOS approval and Apple's notarization requirement for apps
containing LaunchDaemons. This does not claim public distribution acceptance.

The development DNS bridge remains explicitly environment-gated and uses
non-interactive fixed `sudo` commands. Public PHP distribution remains blocked
until its CI provenance and signing path are proven.

## Freeze Scope

M4 includes only Native Local DNS, Native Local TLS, and Standard Local Ports.
No ADR changes or M5 work are required by this acceptance record.
