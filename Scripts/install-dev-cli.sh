#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
bin_dir="$HOME/.local/bin"
link="$bin_dir/val"
target="$repo_root/.build/debug/val"
path_file="$HOME/.zshrc"
path_start='# >>> Vaelen development CLI >>>'
path_export='export PATH="$HOME/.local/bin:$PATH"'
path_end='# <<< Vaelen development CLI <<<'

if existing=$(command -v val 2>/dev/null); then
  case "$existing" in
    "$link") ;;
    *)
      printf 'A different val executable is already on PATH: %s\n' "$existing" >&2
      exit 1
      ;;
  esac
fi

printf 'Building Vaelen CLI...\n'
swift build --product val
test -x "$target"
mkdir -p "$bin_dir"

if [[ -L "$link" ]]; then
  current=$(readlink "$link")
  if [[ "$current" != "$target" ]]; then
    printf 'Refusing to replace another val symlink: %s -> %s\n' "$link" "$current" >&2
    exit 1
  fi
elif [[ -e "$link" ]]; then
  printf 'Refusing to replace an existing non-Vaelen executable: %s\n' "$link" >&2
  exit 1
else
  ln -s "$target" "$link"
fi

shell_name=${SHELL##*/}
if [[ "$shell_name" != "zsh" ]]; then
  shell_name=$(ps -p "$PPID" -o comm= | tr -d ' ')
fi

path_configured=false
path_owned=false
if [[ "$shell_name" == "zsh" ]]; then
  if [[ -f "$path_file" ]] && grep -Fqx "$path_start" "$path_file" && grep -Fqx "$path_export" "$path_file" && grep -Fqx "$path_end" "$path_file"; then
    path_configured=true
    path_owned=true
  elif [[ -f "$path_file" ]] && grep -Eq '(^|[[:space:]])export[[:space:]]+PATH=.*(\$HOME|\$\{HOME\}|~|/)[^:[:space:]\"]*/\.local/bin' "$path_file"; then
    path_configured=true
  else
    [[ -f "$path_file" ]] || : > "$path_file"
    if [[ -s "$path_file" ]] && [[ "$(tail -c 1 "$path_file")" != $'\n' ]]; then
      printf '\n' >> "$path_file"
    fi
    printf '%s\n%s\n%s\n' "$path_start" "$path_export" "$path_end" >> "$path_file"
    path_configured=true
    path_owned=true
  fi
fi

printf 'Vaelen CLI installed.\n'
printf 'Development link: %s -> %s\n' "$link" "$target"
if [[ "$path_configured" == true ]]; then
  if [[ "$path_owned" == true ]]; then
    printf 'PATH block: configured in %s\n' "$path_file"
  else
    printf 'PATH: ~/.local/bin was already configured in %s\n' "$path_file"
  fi
else
  printf 'Shell: %s; persistent PATH setup was not changed.\n' "${shell_name:-unknown}"
  printf 'Add it to the current shell with:\n'
  printf '  export PATH="%s:$PATH"\n' "$bin_dir"
fi
printf 'Restart your terminal or run:\n  source %s\n' "$path_file"
