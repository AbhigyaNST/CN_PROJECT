#!/usr/bin/env bash
# =====================================================================
#  Run on MAC 4 — starts Backend B (Task C) and reminds you this
#  machine is ALSO a test client (set its DNS to Mac 1 + trust the CA).
# =====================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/common.sh"

step "Mac 4: Backend B on port ${BACKEND_B_PORT} + test client"
if ifconfig 2>/dev/null | grep -q "inet ${MAC4_IP}\b"; then
    ok "IP check OK: this machine is ${MAC4_IP}"
else
    warn "This machine does NOT have IP ${MAC4_IP} — check config.env!"
fi
have python3 || { echo "python3 not found (macOS: install Xcode Command Line Tools)"; exit 1; }

cat <<EOF

  ${c_bold}CLIENT SETUP for this machine (once, before the demo):${c_off}

    1. Use our DNS (Phase 1: primary only / Phase 2: primary + backup):
         sudo networksetup -setdnsservers Wi-Fi ${MAC1_IP} ${DNS_BACKUP_IP}
         sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder

    2. Trust the team CA (so browsers + curl accept the edge cert):
         sudo security add-trusted-cert -d -r trustRoot \\
              -k /Library/Keychains/System.keychain \\
              ${CA_CERT}

    3. Verify (NO -k flag):
         dig app.${DOMAIN}
         curl ${EDGE_BASE}/api/status

  The backend runs in the foreground below — open a SECOND Terminal tab
  for client work. Ctrl+C stops Backend B (that's failure demo #3!).

EOF
pause
exec "$REPO_ROOT/backends/start-backend-b.sh"
