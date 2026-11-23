#!/usr/bin/env bash
# =====================================================================
#  Run on MAC 3 — starts Backend A (Task C), port from config.env.
#  Phase 2: this machine ALSO hosts the backup DNS resolver
#  (scripts/start-backup-dns.sh) and the pf isolation rules
#  (scripts/firewall-apply.sh).
# =====================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config.env
source "$REPO_ROOT/config.env"

echo "==> Mac 3: Backend A on port ${BACKEND_A_PORT}"
if ifconfig 2>/dev/null | grep -q "inet ${MAC3_IP}\b"; then
    echo "    IP check OK: this machine is ${MAC3_IP}"
else
    echo "    WARNING: this machine does NOT have IP ${MAC3_IP} — check config.env!"
fi
command -v python3 >/dev/null || { echo "python3 not found (macOS: install Xcode Command Line Tools)"; exit 1; }

cat <<EOF

    Phase 2 extras for this machine (run in SEPARATE Terminal tabs):
      backup DNS resolver : ./scripts/start-backup-dns.sh
      service isolation   : sudo ./scripts/firewall-apply.sh
      standby edge (Ext.E): see docs/SETUP_GUIDE_PHASE2.md

    Requests arrive here ONLY through the nginx edge (Mac 2) — watch the
    log lines: each shows the edge's IP and an ephemeral source port.
EOF
echo
exec "$REPO_ROOT/backends/start-backend-a.sh"
