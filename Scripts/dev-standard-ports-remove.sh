#!/bin/sh
# DEVELOPMENT-ONLY removal for Vaelen Standard Local Ports.
#
# Replicates exactly what the production privileged helper does on removal.
# Requires explicit interactive sudo by the developer (no NOPASSWD).
#
# Usage: ./Scripts/dev-standard-ports-remove.sh [PF_TOKEN]
#   PF_TOKEN is printed by dev-standard-ports-install.sh when it enabled PF.
#   Without a token, PF is left enabled (bias to preserving shared infra).
set -eu

ANCHOR="dev.vaelen.standard-ports"
ANCHOR_FILE="/etc/pf.anchors/${ANCHOR}"

echo "==> Vaelen dev removal: standard local ports"
sudo rm -f "${ANCHOR_FILE}"

TMP="$(mktemp)"
grep -v "dev.vaelen.standard-ports" /etc/pf.conf > "$TMP" || true
grep -v "Vaelen standard local ports (managed by Vaelen" "$TMP" > "${TMP}.2" || true
if ! cmp -s /etc/pf.conf "${TMP}.2"; then
  cat "${TMP}.2" | sudo tee /etc/pf.conf > /dev/null
  echo "removed Vaelen reference lines from /etc/pf.conf"
  echo "reloading active ruleset so the removal takes effect in-kernel"
  sudo pfctl -f /etc/pf.conf
else
  echo "no Vaelen reference lines present"
fi
rm -f "$TMP" "${TMP}.2"
sudo pfctl -a "${ANCHOR}" -F all || true

if [ -n "${1:-}" ]; then
  echo "==> releasing PF enable token $1"
  sudo pfctl -X "$1" || echo "warning: could not release token; leaving PF enabled"
else
  echo "no PF token given; leaving PF enable-state untouched"
fi
