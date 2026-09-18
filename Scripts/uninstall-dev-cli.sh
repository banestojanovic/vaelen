#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
link="$HOME/.local/bin/val"
target="$repo_root/.build/debug/val"
path_file="$HOME/.zshrc"
path_start='# >>> Vaelen development CLI >>>'
path_export='export PATH="$HOME/.local/bin:$PATH"'
path_end='# <<< Vaelen development CLI <<<'

if [[ ! -e "$link" && ! -L "$link" ]]; then
  printf 'No development CLI link found at %s\n' "$link"
  exit 0
fi

if [[ ! -L "$link" ]]; then
  printf 'Refusing to remove non-symlink path: %s\n' "$link" >&2
  exit 1
fi

current=$(readlink "$link")
if [[ "$current" != "$target" ]]; then
  printf 'Refusing to remove a symlink not owned by this Vaelen checkout: %s -> %s\n' "$link" "$current" >&2
  exit 1
fi

rm "$link"
printf 'Removed development CLI link: %s\n' "$link"

if [[ -f "$path_file" ]] && grep -Fqx "$path_start" "$path_file" && grep -Fqx "$path_export" "$path_file" && grep -Fqx "$path_end" "$path_file"; then
  perl -0pi -e 's{\n?\Q# >>> Vaelen development CLI >>>\E\n\Qexport PATH="\E\$HOME\Q/.local/bin:\E\$PATH\Q"\E\n\Q# <<< Vaelen development CLI <<<\E\n}{}' "$path_file"
  printf 'Removed Vaelen PATH block from %s\n' "$path_file"
fi
