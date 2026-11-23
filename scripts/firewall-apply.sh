#!/usr/bin/env bash
# =====================================================================
#  Phase 2, Extension C — APPLY backend service isolation (macOS pf).
#  Run on BOTH backend machines (Mac 3 and Mac 4):
#
#      sudo ./scripts/firewall-apply.sh
#
#  After this, only the edge (Mac 2) can open TCP connections to the
#  backend ports; every other machine's attempts are dropped.
#  A timestamped backup of the current pf state is saved under run/
#  so firewall-rollback.sh can restore things exactly.
# =====================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/common.sh"

[ "$(uname)" = "Darwin" ] || { echo "pf rules are macOS-specific; this script must run on a Mac." >&2; exit 1; }

RULES="$REPO_ROOT/deploy/firewall/backend-isolation.pf.conf"
[ -f "$RULES" ] || { echo "Missing $RULES — run ./scripts/configure.sh first." >&2; exit 1; }

STAMP="$(date +%Y%m%d-%H%M%S)"
BK="$REPO_ROOT/run/pf-backup-$STAMP"
mkdir -p "$BK"

echo "[pf] saving current firewall state to $BK ..."
sudo pfctl -si > "$BK/status.txt" 2>&1 || true
sudo pfctl -sr > "$BK/rules.txt" 2>&1 || true
sudo pfctl -sn > "$BK/nat.txt"   2>&1 || true
sudo cp /etc/pf.conf "$BK/etc-pf.conf" 2>/dev/null || true
if grep -q "Status: Enabled" "$BK/status.txt"; then echo enabled > "$BK/was-enabled"; else echo disabled > "$BK/was-enabled"; fi

echo "[pf] validating ruleset (dry run) ..."
sudo pfctl -nf "$RULES"

echo "[pf] applying ruleset + enabling pf ..."
sudo pfctl -f "$RULES"
sudo pfctl -e 2>/dev/null || true

echo
echo "[pf] active filter rules now:"
sudo pfctl -sr | sed 's/^/    /'

cat <<EOF

============================================================
 Isolation ACTIVE. Prove it:

   From Mac 2 (the edge) — must WORK:
     curl --max-time 3 http://$(hostname -s | awk '{print "'"$MAC3_IP"'")}:${BACKEND_A_PORT}/health

   From Mac 1 or Mac 4 (clients) — must TIME OUT:
     curl --max-time 3 http://${MAC3_IP}:${BACKEND_A_PORT}/health
     curl --max-time 3 http://${MAC4_IP}:${BACKEND_B_PORT}/health
     (dropped packets => timeout, NOT 'connection refused' — that
      difference is itself evidence a firewall dropped them)

   ... yet the service still works end-to-end:
     curl ${EDGE_BASE}/api/status

 ROLLBACK (always do this after the demo):
   sudo $REPO_ROOT/scripts/firewall-rollback.sh
============================================================
EOF
