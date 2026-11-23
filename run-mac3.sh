#!/usr/bin/env bash
# =====================================================================
#  run-mac3.sh — AUTOMATED ONE-CLICK RUNNER FOR MAC 3
#  Role: Backend Server A (:3001) + Backup DNS Server (:53)
# =====================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$REPO_ROOT/scripts/common.sh"

echo "============================================================"
echo " Starting MAC 3: Backend A (:3001) + Backup DNS (:53)"
echo " Machine IP: ${MAC3_IP}"
echo "============================================================"

# 1. Sanity check IP
if ifconfig 2>/dev/null | grep -q "inet ${MAC3_IP}\b"; then
    ok "IP check passed: this machine is ${MAC3_IP}"
else
    warn "IP check: this machine does not currently have ${MAC3_IP}."
fi

have python3 || { fail "python3 not found"; exit 1; }

# 2. Start Backup DNS resolver in background (Extension A)
step "Starting Phase 2 Backup DNS resolver on ${MAC3_IP}:${DNS_PORT}"
CONF_BACKUP="$REPO_ROOT/deploy/backup-dns/dnsmasq-backup.conf"
[ -f "$CONF_BACKUP" ] || "$REPO_ROOT/scripts/configure.sh"

"$REPO_ROOT/scripts/start-backup-dns.sh" || {
    warn "Could not start backup DNS as daemon. Checking if already running..."
}

sleep 1
if dig "@127.0.0.1" -p "${DNS_PORT}" "app.${DOMAIN}" +short 2>/dev/null | grep -q "${MAC2_IP}"; then
    ok "Backup DNS active and answering queries"
elif dig "@${MAC3_IP}" -p "${DNS_PORT}" "app.${DOMAIN}" +short 2>/dev/null | grep -q "${MAC2_IP}"; then
    ok "Backup DNS active on ${MAC3_IP}:${DNS_PORT}"
else
    warn "Backup DNS check did not return edge IP immediately — continuing..."
fi

# 3. Inform about Phase 2 Extensions on Mac 3
cat <<EOF

------------------------------------------------------------
 Phase 2 Features on Mac 3:
   1. Backup DNS (Ext A)   : RUNNING in background on port 53
   2. Service Isolation    : sudo ./scripts/firewall-apply.sh
      (Rollback anytime)   : sudo ./scripts/firewall-rollback.sh
   3. Standby Edge (Ext E) : ./scripts/mac2-edge.sh
------------------------------------------------------------

Starting Backend A on port ${BACKEND_A_PORT}...
Requests will log below in real-time.
(Press Ctrl+C to stop Backend A — this demonstrates Extension D HA Failover!)
============================================================

EOF

exec python3 "$REPO_ROOT/backends/backend.py" --name A --port "$BACKEND_A_PORT"
