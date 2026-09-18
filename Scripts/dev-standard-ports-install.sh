#!/bin/sh
# DEVELOPMENT-ONLY bootstrap for Vaelen Standard Local Ports.
#
# Replicates exactly what the production privileged helper does, so real PF
# forwarding architecture can be acceptance-tested without a signed
# SMAppService helper (ad-hoc builds cannot install one).
#
# - Never part of public runtime UX; vaelend/val never execute this.
# - Requires explicit interactive sudo by the developer (no NOPASSWD).
# - Fixed Vaelen-specific operations only; inspect before running.
# - Prints the PF enable token: save it for dev-standard-ports-remove.sh.
#
# Usage: ./Scripts/dev-standard-ports-install.sh
set -eu

ANCHOR="dev.vaelen.standard-ports"
ANCHOR_FILE="/etc/pf.anchors/${ANCHOR}"
BACKEND_HTTP=8787
BACKEND_HTTPS=8743

echo "==> Vaelen dev bootstrap: standard local ports (edge: this modifies PF state)"
echo "    anchor: ${ANCHOR_FILE}"
echo "    127.0.0.1:80  -> 127.0.0.1:${BACKEND_HTTP}"
echo "    127.0.0.1:443 -> 127.0.0.1:${BACKEND_HTTPS}"

{ echo "rdr pass on lo0 inet proto tcp from any to 127.0.0.1 port 80 -> 127.0.0.1 port ${BACKEND_HTTP}";
  echo "rdr pass on lo0 inet proto tcp from any to 127.0.0.1 port 443 -> 127.0.0.1 port ${BACKEND_HTTPS}"; } | sudo tee "${ANCHOR_FILE}" > /dev/null

# PF requires translation anchors before filter anchors: insert the Vaelen
# block immediately before the first `anchor` filter line (self-heals the
# earlier EOF-append placement by stripping existing Vaelen lines first).
BLOCK="$(mktemp)"; STRIPPED="$(mktemp)"; NEWCONF="$(mktemp)"
{
  echo '# Vaelen standard local ports (managed by Vaelen; do not edit)'
  echo "rdr-anchor \"${ANCHOR}\""
  echo "load anchor \"${ANCHOR}\" from \"${ANCHOR_FILE}\""
} > "$BLOCK"
grep -v 'dev.vaelen.standard-ports' /etc/pf.conf | grep -v 'Vaelen standard local ports (managed by Vaelen' > "$STRIPPED" || true
awk -v blockfile="$BLOCK" '
  BEGIN { n = 0; while ((getline l < blockfile) > 0) lines[++n] = l }
  /^anchor[ \t"]/ && !done { for (i = 1; i <= n; i++) print lines[i]; done = 1 }
  { print }
  END { if (!done) for (i = 1; i <= n; i++) print lines[i] }
' "$STRIPPED" > "$NEWCONF"
if ! cmp -s /etc/pf.conf "$NEWCONF"; then
  cat "$NEWCONF" | sudo tee /etc/pf.conf > /dev/null
  echo "installed Vaelen reference lines into /etc/pf.conf"
else
  echo "Vaelen reference lines already correctly placed"
fi
rm -f "$BLOCK" "$STRIPPED" "$NEWCONF"

# The kernel only evaluates anchors referenced by its ACTIVE main ruleset.
# Editing pf.conf on disk is not enough: reload it so the Vaelen
# rdr-anchor reference becomes live, then load the anchor itself.
sudo pfctl -f /etc/pf.conf
sudo pfctl -a "${ANCHOR}" -f "${ANCHOR_FILE}"

if sudo pfctl -s info | grep -q "Status: Enabled"; then
  echo "PF already enabled; no new token."
else
  echo "==> enabling PF (reference counted; removal releases it)"
  sudo pfctl -E
fi

echo "==> verify: curl -sS -o /dev/null -w '%{http_code}' -H 'Host: syncproof.test' http://127.0.0.1:80/login"
