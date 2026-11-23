#!/usr/bin/env bash
# =====================================================================
#  Phase 2, Extension C — ROLLBACK backend isolation.
#  Restores the stock macOS pf ruleset and returns pf to the
#  enabled/disabled state it was in BEFORE firewall-apply.sh ran.
#
#      sudo ./scripts/firewall-rollback.sh
# =====================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/common.sh"

[ "$(uname)" = "Darwin" ] || { echo "pf is macOS-specific." >&2; exit 1; }

echo "[pf] restoring stock /etc/pf.conf ..."
sudo pfctl -f /etc/pf.conf

LATEST_BK="$(ls -1d "$REPO_ROOT"/run/pf-backup-* 2>/dev/null | tail -1 || true)"
if [ -n "$LATEST_BK" ] && [ -f "$LATEST_BK/was-enabled" ]; then
    if [ "$(cat "$LATEST_BK/was-enabled")" = "disabled" ]; then
        echo "[pf] pf was DISABLED before the demo — disabling again"
        sudo pfctl -d 2>/dev/null || true
    else
        echo "[pf] pf was enabled before the demo — leaving enabled"
        sudo pfctl -e 2>/dev/null || true
    fi
else
    warn "No backup found under run/ — pf left ENABLED with stock rules."
fi

echo
echo "[pf] current status:"
sudo pfctl -si | grep -E "Status|Debug" | sed 's/^/    /'
echo "[pf] current filter rules:"
sudo pfctl -sr | sed 's/^/    /' || echo "    (none loaded)"
echo
ok "Rollback complete — backend ports are open to the LAN again."
