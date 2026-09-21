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

The repository's current test suite does not implement the documented
2-second PF wedge probe or the four direct-backend integration tests. Those
claims are therefore not treated as current test evidence. The supported
browser path was accepted on the real machine; direct-backend behavior remains
an environment-specific finding until a probe and integration tests are added.
Other skips are only missing development prerequisites or explicitly
development-only distribution tests.

## Privilege And Distribution Boundary

The production standard-port helper exposes only parameterless fixed-policy
operations and now validates the caller against the signed `dev.vaelen.app`
code requirement. It validates the existing fixed anchor before mutation and
uses atomic replacement. The current development package does not contain the
signed SMAppService bundle metadata, Developer ID signatures, or notarization;
runtime production registration therefore remains a distribution acceptance
item, not a claim of completed public distribution.

The development DNS bridge remains explicitly environment-gated and uses
non-interactive fixed `sudo` commands. Public PHP distribution remains blocked
until its CI provenance and signing path are proven.

## Freeze Scope

M4 includes only Native Local DNS, Native Local TLS, and Standard Local Ports.
No ADR changes or M5 work are required by this acceptance record.
