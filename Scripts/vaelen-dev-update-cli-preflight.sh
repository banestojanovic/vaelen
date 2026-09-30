#!/usr/bin/env bash
# Validate the CLI required by the updater's post-install acceptance check.
# Arguments allow isolated tests; production passes the stable managed paths.
vaelen_update_cli_preflight() {
  local cli="$1" owner="$2" link="$3" recorded actual
  if [[ ! -f "$cli" || -L "$cli" || ! -x "$cli" || ! -f "$owner" || -L "$owner" ]]; then
    echo "required managed CLI is missing or invalid; current app left running. Repair it with ./Scripts/install-cli.sh, then retry" >&2
    return 1
  fi
  recorded="$(tr -d '[:space:]' < "$owner")"
  actual="$(shasum -a 256 "$cli" | awk '{print $1}')"
  if [[ ! "$recorded" =~ ^[0-9a-f]{64}$ || "$actual" != "$recorded" || ! -L "$link" || "$(readlink "$link")" != "$cli" ]]; then
    echo "managed CLI ownership/checksum or ~/.local/bin/val link is invalid; current app left running. Review and repair with ./Scripts/install-cli.sh, then retry" >&2
    return 1
  fi
  if ! "$cli" status >/dev/null 2>&1; then
    echo "managed CLI is incompatible or cannot contact Vaelen; current app left running. Rebuild/install it with ./Scripts/install-cli.sh, then retry" >&2
    return 1
  fi
}
