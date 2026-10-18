# Run Composer

`val composer [arguments...]` resolves PHP through Core for the current working directory, finds a Composer PHP script on PATH, and replaces the `val` process with PHP running that script.

## How to get to it

Run `val composer --version` from a linked project, an inherited linked project, or a directory outside linked projects. Core selects a project override inside an overridden project and the server default otherwise.

## Supported Composer discovery

Search each PATH directory for `composer` and then `composer.phar`. Empty entries select the invocation directory; relative entries resolve from it. An unset PATH has no entries. There is no separate project-local lookup. The first existing candidate must resolve to a readable regular file, including through a symlink. Executable permission is not required because Vaelen invokes PHP directly.

The first 4096 bytes must contain a PHP opening tag after optional whitespace and an optional first-line shebang containing `php`. The shebang is inspected but never executed. Shell launchers, binaries, broken links, and incompatible first candidates fail without trying later candidates. PHAR payload bytes after the PHP header may be binary. Vaelen resolves only the PHP executable and preserves the invocation environment; it does not generate or select managed INI files.

## Driving it with Swift XCTest

Run the focused proof from an isolated worktree:

```bash
.agents/skills/verify-vaelen/scripts/prove-composer.sh
```

The proof builds only `val`, compiles and lists tests without executing the full suite, then runs eight exact tests. The CLI journey starts the production `DaemonServer` in the test process with a private Unix socket and SQLite registry. It creates two synthetic PHP package records backed by distinct arm64 Mach-O fixture binaries. The fixture binaries report different versions to Core's existing package validator and print their label, working directory, arguments, stdin, and stderr when `val composer` launches them.

The journey verifies project override selection, inherited selection inside another linked project, and default selection outside linked projects. It also checks PATH ordering, Composer lookup failure, an incompatible first candidate, unavailable selected PHP without default fallback, unavailable Core, exact argument and stream forwarding, nonzero status, and unchanged support files. Unit tests cover relative and empty PATH components, symlinks, a PHP shebang, a PHAR header with following binary bytes, malformed openers, and parser forwarding.

This proof does not execute PHP or Composer. The synthetic binaries pass the architecture and `-v` checks Core requires, but they are C stand-ins. The Composer files are PHP header fixtures and are passed to those stand-ins as arguments. No package installation, plugin, real Composer cache, or user data changes. The proof does not test behavior inside a real Composer release, PHP extension loading, or Composer-created project files.
