#!/usr/bin/env bash
# =====================================================================
#  run-mac4.sh — AUTOMATED ONE-CLICK RUNNER FOR MAC 4
#  Role: Backend Server B (:3002) + Test Client (DNS & CA Configured)
# =====================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$REPO_ROOT/scripts/common.sh"

echo "============================================================"
echo " Starting MAC 4: Backend B (:3002) + Primary Test Client"
echo " Machine IP: ${MAC4_IP}"
echo "============================================================"

# 1. Sanity check IP
if ifconfig 2>/dev/null | grep -q "inet ${MAC4_IP}\b"; then
    ok "IP check passed: this machine is ${MAC4_IP}"
else
    warn "IP check: this machine does not currently have ${MAC4_IP}."
fi

have python3 || { fail "python3 not found"; exit 1; }

# 2. Configure Client DNS to Primary (Mac 1) + Backup (Mac 3)
step "Configuring Mac 4 System DNS (Dual Resolvers: ${MAC1_IP} + ${DNS_BACKUP_IP})"
WIFI_DEV="$(networksetup -listallnetworkservices | grep -E -i "wi-fi|airport" | head -1 || echo "Wi-Fi")"
sudo networksetup -setdnsservers "$WIFI_DEV" "${MAC1_IP}" "${DNS_BACKUP_IP}" 2>/dev/null || true
sudo dscacheutil -flushcache 2>/dev/null || true
sudo killall -HUP mDNSResponder 2>/dev/null || true
ok "DNS resolvers set on ${WIFI_DEV}"

# 3. Trust the Root CA certificate in System Keychain (so curl works without -k)
step "Trusting team CA certificate in System Keychain"
if [ -f "$CA_CERT" ]; then
    sudo security add-trusted-cert -d -r trustRoot \
        -k /Library/Keychains/System.keychain \
        "$CA_CERT" 2>/dev/null || true
    ok "Team CA certificate trusted"
else
    warn "CA certificate not found at $CA_CERT"
fi

# 4. Phase 2 actions reminder
cat <<EOF

------------------------------------------------------------
 Client testing ready on Mac 4:
   - Run verification anytime : ./scripts/verify.sh
   - Collect all evidence     : ./scripts/collect-evidence-phase2.sh
   - Demonstrate Phase 2 menu : ./scripts/demo-phase2.sh
   - Apply pf Isolation (Ext C): sudo ./scripts/firewall-apply.sh
------------------------------------------------------------

Starting Backend B on port ${BACKEND_B_PORT}...
Requests will log below in real-time.
(Press Ctrl+C to stop Backend B)
============================================================

EOF

exec python3 "$REPO_ROOT/backends/backend.py" --name B --port "$BACKEND_B_PORT"
