# View managed logs in the app

Run the isolated state-model checks:

```bash
swift test --filter VaelenIPCTests.ManagedLogViewerModelTests
```

The controlled fake Core replies cover catalog identifiers and labels
(including PHP-FPM), selection, exact displayed-text copy source, successful
and truncated plus empty reads, missing/unreadable/unsafe/disconnected
failures, stale selection responses, overlapping catalog refreshes, and a
selected PHP log disappearing from the catalog. Core file handling remains
covered by existing `CoreLogCatalogTests` and the isolated `val logs` IPC test;
this model suite does not duplicate file fixtures.

The UI uses one `service-logs` window scene. It is resizable and repeated
`View Logs` actions reopen/focus it. GUI behavior, clipboard integration, and
light/dark styling require manual review; neither model tests nor a successful
build prove them. After a signed app build, manually open Settings → Services →
View Logs, switch among service and PHP logs, refresh, copy and paste the
displayed text, and check both macOS appearances.
