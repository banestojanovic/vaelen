# List managed services

A user runs `val service list --json` and expects a complete inventory from Core status observations, or an unavailable row for each managed service and a distinct failure exit code when Core cannot be reached.

## How to get to it (user POV)

Run `val service list --json` from a shell. The JSON reports whether the inventory is complete and includes service rows.

## Driving it with Swift XCTest

Run the actual built CLI against a unique private support root with no Core server:

```bash
Scripts/tests/val-service-list-test.sh
```

The integration tests cover both Core paths. The missing-Core case requires exit code 3, valid JSON with `complete` set to false, and exactly MySQL and Mailpit rows with unavailable state. The private-Core case starts an in-process `DaemonServer` using MySQLModule and MailpitModule on an empty temporary layout. It requires the actual `val` child to exit 0 with `complete` set to true, both default rows present, neither marked unavailable, and the expected endpoint values. It does not install packages or start either service. Both cases confine the support-root override to the CLI child and remove their private root after confirmed child and server shutdown.

## Coverage limits

The private-Core case verifies a successful Core handshake and module status observations for an empty package layout. It does not verify live package or service health, installed-app integration, or service operations. No MySQL or Mailpit process is started.
