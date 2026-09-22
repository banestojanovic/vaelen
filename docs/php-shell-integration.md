# Vaelen PHP shell resolution

Vaelen's zsh integration defines one stable `php` function. For each command,
it asks a dedicated Vaelen CLI resolver for the managed PHP executable selected by
Core, then forwards the original arguments to that executable. The resolver
uses a linked project's PHP override when the current directory is inside a
linked project; otherwise it uses the current global default. It does not put
version-specific runtime paths into shell configuration.

Vaelen PHP shell resolution supports arm64 / Apple Silicon only; it has no
Intel, Rosetta, or universal-binary fallback.

Build/install the resolver and add the block idempotently with:

```sh
Scripts/install-php-shell-integration.sh
```

Start a new zsh session or source `~/.zshrc`. The resolver lives at
`~/Library/Application Support/Vaelen/bin/vaelen-php-resolver`; pass `php
resolve --path` to inspect the selected executable. The integration reports an
error rather than falling back to another PHP when Core or the selected
managed runtime is unavailable. `val shell status`, `val shell install`, and
`val shell uninstall` report and manage the same owned block.
