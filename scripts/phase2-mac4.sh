#!/usr/bin/env bash
# =====================================================================
#  PHASE 2 — MAC 4 ROLE SCRIPT
#  Mac 4: Backend B (3002) + test client
#
#  Phase 1 task:  Backend B already running (mac4-backend-b.sh)
#  Phase 2 NEW tasks:
#    Extension C: apply pf firewall isolation (run as sudo)
#    Extension D: kill Backend B to test LB failover (Ctrl+C)
#    Client demos: run Extension A/B/D/E observations from here
#
#  Usage:
#    ./scripts/phase2-mac4.sh            # status + instructions
#    sudo ./scripts/phase2-mac4.sh firewall   # apply pf isolation
#    sudo ./scripts/phase2-mac4.sh rollback   # remove pf isolation
#    ./scripts/phase2-mac4.sh client-setup    # configure DNS + trust CA
#    ./scripts/phase2-mac4.sh verify          # run verify.sh from this machine
# =====================================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/common.sh"

ACTION="${1:-status}"

check_this_mac() {
    if ! ifconfig 2>/dev/null | grep -q "inet ${MAC4_IP}\b"; then
        warn "This machine does not appear to have IP ${MAC4_IP}"
        warn "Are you on the correct Mac? (Expected Mac 4 = ${MAC4_IP})"
    else
        ok "IP check: this machine is ${MAC4_IP} (Mac 4)"
    fi
}

case "$ACTION" in

status)
    step "Mac 4 — Phase 2 Status Check"
    check_this_mac
    echo ""
    echo "── Backend B ──"
    BACKEND_B_HEALTH=$(curl -s --max-time 2 "http://127.0.0.1:${BACKEND_B_PORT}/health" 2>/dev/null || echo "")
    if [ "$BACKEND_B_HEALTH" = "ok" ]; then
        ok "Backend B listening on :${BACKEND_B_PORT}"
    else
        warn "Backend B NOT running on :${BACKEND_B_PORT}"
        warn "→ Start in a separate tab: ./scripts/mac4-backend-b.sh"
    fi
    echo ""
    echo "── DNS resolver (client config) ──"
    PRIMARY="$(scutil --dns 2>/dev/null | awk '/nameserver\[0\]/{print $3; exit}' || true)"
    SECONDARY="$(scutil --dns 2>/dev/null | awk '/nameserver\[1\]/{print $3; exit}' || true)"
    if [ "$PRIMARY" = "$MAC1_IP" ]; then
        ok "Primary DNS: ${PRIMARY} (correct)"
    else
        warn "Primary DNS: ${PRIMARY:-<not set>} (expected ${MAC1_IP})"
    fi
    if [ "$SECONDARY" = "$DNS_BACKUP_IP" ]; then
        ok "Backup DNS: ${SECONDARY} (correct — Extension A ready)"
    else
        info "Backup DNS: ${SECONDARY:-<not set>} (expected ${DNS_BACKUP_IP})"
        info "→ Set both: sudo networksetup -setdnsservers Wi-Fi ${MAC1_IP} ${DNS_BACKUP_IP}"
    fi
    echo ""
    echo "── CA Trust ──"
    if security find-certificate -a -Z /Library/Keychains/System.keychain 2>/dev/null \
        | grep -q "team1 Local Root CA\|${TEAM}"; then
        ok "Team CA trusted in system keychain"
    else
        warn "Team CA may NOT be trusted"
        warn "→ Trust it: sudo security add-trusted-cert -d -r trustRoot \\"
        warn "    -k /Library/Keychains/System.keychain \\"
        warn "    ${REPO_ROOT}/deploy/mac2/certs/ca.crt"
    fi
    echo ""
    echo "── pf Firewall (Extension C) ──"
    if sudo pfctl -sr 2>/dev/null | grep -q "${BACKEND_B_PORT}"; then
        ok "pf isolation ACTIVE on this machine"
    else
        info "pf isolation NOT active (Phase 1 state — apply for Ext C demo)"
    fi
    echo ""
    echo "── Phase 2 Actions ──"
    echo "  ./scripts/phase2-mac4.sh client-setup  # set DNS + trust CA"
    echo "  ./scripts/phase2-mac4.sh verify         # run full verify.sh"
    echo "  sudo ./scripts/phase2-mac4.sh firewall  # pf isolation (Ext C)"
    echo "  sudo ./scripts/phase2-mac4.sh rollback  # remove pf isolation"
    echo "  Ctrl+C the backend terminal             # kill Backend B (Ext D)"
    ;;

client-setup)
    step "Mac 4: Configure as Phase 2 test client"
    check_this_mac
    echo ""
    echo "── Step 1: Set DNS resolvers (primary + backup) ──"
    sudo networksetup -setdnsservers Wi-Fi "${MAC1_IP}" "${DNS_BACKUP_IP}"
    sudo dscacheutil -flushcache
    sudo killall -HUP mDNSResponder 2>/dev/null || true
    sleep 1
    echo ""
    echo "Current resolver config:"
    scutil --dns 2>/dev/null | head -20 | sed 's/^/  /'
    echo ""
    echo "── Step 2: Trust the team CA ──"
    echo "  Run:"
    echo "  sudo security add-trusted-cert -d -r trustRoot \\"
    echo "    -k /Library/Keychains/System.keychain \\"
    echo "    ${REPO_ROOT}/deploy/mac2/certs/ca.crt"
    echo ""
    echo "  (The repo must be cloned here or the cert file copied over)"
    echo ""
    echo "── Step 3: Verify (no -k flag!) ──"
    echo "  dig app.${DOMAIN}"
    echo "  curl ${EDGE_BASE}/api/status"
    ;;

firewall)
    step "Extension C: Applying pf isolation on Mac 4 (Backend B)"
    check_this_mac
    sudo "$REPO_ROOT/scripts/firewall-apply.sh"
    echo ""
    echo "PROVE IT (from Mac 1 or another client — should TIME OUT):"
    echo "  curl --max-time 3 http://${MAC4_IP}:${BACKEND_B_PORT}/health"
    echo ""
    echo "END-TO-END still works through the edge:"
    echo "  curl ${EDGE_BASE}/api/status"
    echo ""
    echo "ROLLBACK: sudo ./scripts/phase2-mac4.sh rollback"
    ;;

rollback)
    step "Extension C: Rolling back pf isolation on Mac 4"
    check_this_mac
    sudo "$REPO_ROOT/scripts/firewall-rollback.sh"
    ok "pf isolation removed — Backend B ports open to LAN again"
    ;;

verify)
    step "Running Phase 1+2 verification from Mac 4 (client)"
    check_this_mac
    "$REPO_ROOT/scripts/verify.sh"
    ;;

*)
    echo "Unknown action: ${ACTION}"
    echo "Usage: $0 [status|client-setup|firewall|rollback|verify]"
    exit 1
    ;;
esac
