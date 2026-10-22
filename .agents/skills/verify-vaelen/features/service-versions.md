# List managed service versions

A user runs `val service versions mysql` or `val service versions mailpit` to view the available and installed versions for that service. The commands alias the existing MySQL and Mailpit version operations, including their human formatters, native JSON payloads, Core errors, and MySQL-only optional `default` field.

Run the parser checks and then the private-Core CLI harness:

```bash
Scripts/test.sh --filter ServiceInventoryOutputTests
Scripts/tests/val-service-versions-test.sh
```

The parser checks accept each service with and without `--json`. Missing and unknown types, repeated `--json`, and extra arguments are rejected. Focused help documents both forms.

The harness starts a private Core backed by an empty temporary package layout, then invokes the actual `val service versions` child for both types in human and JSON mode. JSON is decoded as `MySQLVersionsPayload` or `MailpitVersionsPayload`, compared with direct payloads from the same private Core, and checked for the native top-level keys. MySQL carries optional `default` metadata; Mailpit has no `default` field. No packages are installed and no services are started.

This verifies parser behavior, the real CLI child, private Core reads, format routing, and the typed JSON contract. It does not verify installed-app integration, package installation, or live MySQL/Mailpit health.
