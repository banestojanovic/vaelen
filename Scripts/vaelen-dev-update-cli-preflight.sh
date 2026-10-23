#!/usr/bin/env bash
# Validate the CLI required by the updater's post-install acceptance check.
# Arguments allow isolated tests; production passes the stable managed paths.
vaelen_update_cli_preflight() {
  local cli="$1" owner="$2" link="$3" recorded actual status_output status_code
  if [[ ! -e "$cli" && ! -L "$cli" ]]; then
    echo "managed CLI is missing at $cli" >&2
    return 1
  fi
  if [[ -L "$cli" || ! -f "$cli" ]]; then
    echo "managed CLI is not a regular file at $cli" >&2
    return 1
  fi
  if [[ ! -x "$cli" ]]; then
    echo "managed CLI is not executable at $cli" >&2
    return 1
  fi
  if [[ ! -e "$owner" && ! -L "$owner" ]]; then
    echo "managed CLI ownership record is missing at $owner" >&2
    return 1
  fi
  if [[ -L "$owner" || ! -f "$owner" ]]; then
    echo "managed CLI ownership record is not a regular file at $owner" >&2
    return 1
  fi
  recorded="$(tr -d '[:space:]' < "$owner")"
  actual="$(shasum -a 256 "$cli" | awk '{print $1}')"
  if [[ ! "$recorded" =~ ^[0-9a-f]{64}$ ]]; then
    echo "managed CLI ownership record is malformed at $owner" >&2
    return 1
  fi
  if [[ "$actual" != "$recorded" ]]; then
    echo "managed CLI checksum does not match its ownership record at $owner" >&2
    return 1
  fi
  if [[ ! -L "$link" ]]; then
    echo "managed CLI command link is missing or is not a symlink at $link" >&2
    return 1
  fi
  if [[ "$(readlink "$link")" != "$cli" ]]; then
    echo "managed CLI command link points somewhere else: $link -> $(readlink "$link")" >&2
    return 1
  fi
  if status_output="$("$cli" status 2>&1)"; then
    return 0
  else
    status_code=$?
  fi
  case "$status_code" in
    3)
      printf 'Vaelen Core is unavailable (val status exited 3). The updater has not requested app shutdown. %s\n' "$status_output" >&2
      return 3
      ;;
    4)
      printf 'Vaelen Core and CLI protocol compatibility failed (val status exited 4). The updater has not requested app shutdown. %s\n' "$status_output" >&2
      ;;
    *)
      printf 'Managed CLI status failed (val status exited %s). The updater has not requested app shutdown. %s\n' "$status_code" "$status_output" >&2
      ;;
  esac
  return 1
}
