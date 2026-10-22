# Vaelen PHP and Node shell integration

Vaelen's opt-in zsh integration defines `php`, `node`, and `npm` functions in
one owned block. Each command uses the copied Vaelen CLI helper in
`~/Library/Application Support/Vaelen/bin/vaelen-php-resolver`.

The `php` function resolves the managed PHP executable for the current
project, then forwards the original arguments to it. A linked project's PHP
override takes precedence over the global default. Vaelen reports an error if
Core or the selected managed runtime is unavailable. It does not select a
different PHP runtime in that case.

The `node` and `npm` functions call `val node exec -- node` or
`val node exec -- npm`. A linked project's exact Node pin prepends its managed
runtime to `PATH` for that command. Other projects use the invocation `PATH`.
Unavailable project pins fail without falling back to another Node runtime.
The helper does not connect to Core or migrate project state.

The PHP shell integration supports arm64 / Apple Silicon only. It has no Intel,
Rosetta, or universal-binary fallback.

Build and install the helper, then add the block idempotently with:

```sh
Scripts/install-php-shell-integration.sh
```

Start a new zsh session or source `~/.zshrc`. Pass `php resolve --path` to the
helper to inspect the selected PHP executable. `val shell status`,
`val shell install`, and `val shell uninstall` report and manage the same
owned block. Shell configuration changes only when you run
`val shell install`.
