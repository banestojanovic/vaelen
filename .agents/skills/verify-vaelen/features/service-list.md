# List managed services

A user runs `val service list --json` and expects a complete inventory response when Core cannot be reached, including an unavailable row for each managed service and a distinct failure exit code.

## How to get to it (user POV)

Run `val service list --json` from a shell. The JSON reports whether the inventory is complete and includes service rows.

## Driving it with Swift XCTest

Run the actual built CLI against a unique private support root with no Core server:

```bash
Scripts/tests/val-service-list-test.sh
```

The integration test requires exit code 3, valid JSON with `complete` set to false, and exactly MySQL and Mailpit rows with unavailable state. It uses the real `val` executable and confines the support-root override to the child process. The test owns and bounds the CLI child, then removes its private root after confirmed exit.

## Coverage limits

This recipe verifies the missing-Core path through the real CLI process. It does not verify a Core handshake, live service state, installed-app integration, or service operations.
