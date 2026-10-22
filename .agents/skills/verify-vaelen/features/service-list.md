# List managed services

A user runs `val service list --json` and expects a complete inventory from Core status observations, a partial inventory when one service observation fails, or an unavailable row for each managed service and a distinct failure exit code when Core cannot be reached.

## How to get to it (user POV)

Run `val service list --json` from a shell. The JSON reports whether the inventory is complete and includes service rows. `Scripts/tests/val-service-list-test.sh` exercises the actual CLI child against missing Core, a private Core with both modules, and a private Core with MySQL observation unavailable and Mailpit available. It requires valid JSON on stdout, an incomplete diagnostic on stderr, and a nonzero status for partial inventory.

## Driving it with Swift XCTest

Run the actual built CLI against a unique private support root with no Core server:

```bash
Scripts/tests/val-service-list-test.sh
```

The integration tests cover missing Core, complete inventory, and partial inventory. The missing-Core case requires exit code 3, valid JSON with `complete` set to false, and exactly MySQL and Mailpit rows with unavailable state. The complete private-Core case requires exit 0, both default rows present, neither unavailable, and expected endpoint values. The partial private-Core case sets `mysql: nil` and provides MailpitModule. It requires nonzero exit, valid JSON with `complete` false, exactly two rows, a MySQL observation error, and a not-installed Mailpit row with endpoint values. Neither private-Core case installs packages or starts services. Each case confines the support-root override to the CLI child and removes its private root after confirmed child and server shutdown.

## Coverage limits

The private-Core cases verify a successful Core handshake and module status observations for an empty package layout, including an unavailable module observation. They do not verify live package or service health, installed-app integration, or service operations. No MySQL or Mailpit process is started.
