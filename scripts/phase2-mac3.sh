#!/usr/bin/env bash
# =====================================================================
#  PHASE 2 — MAC 3 ROLE SCRIPT
#  Mac 3: Backend A (3001) + Backup DNS + Standby Edge (Ext E)
#
#  Phase 1 task:  Backend A is already running (mac3-backend-a.sh)
#  Phase 2 NEW tasks:
#    Extension A: backup DNS resolver on Mac 3
#    Extension C: pf firewall isolation (run as sudo)
#    Extension E: standby nginx edge (mac2-edge.sh on Mac 3)
#
#  Usage:
#    ./scripts/phase2-mac3.sh            # full setup + status
#    ./scripts/phase2-mac3.sh backup-dns # start backup DNS only
#    ./scripts/phase2-mac3.sh firewall   # apply pf isolation only
#    ./scripts/phase2-mac3.sh rollback   # remove pf rules
#    ./scripts/phase2-mac3.sh standby-edge  # start standby nginx edge (Ext E)
#    ./scripts/phase2-mac3.sh status     # check everything
# =====================================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/common.sh"

ACTION="${1:-status}"

check_this_mac() {
    if ! ifconfig 2>/dev/null | grep -q "inet ${MAC3_IP}\b"; then
        warn "This machine does not appear to have IP ${MAC3_IP}"
        warn "Are you on the correct Mac? (Expected Mac 3 = ${MAC3_IP})"
    else
        ok "IP check: this machine is ${MAC3_IP} (Mac 3)"
    fi
}

case "$ACTION" in

status)
    step "Mac 3 — Phase 2 Status Check"
    check_this_mac
    echo ""
    echo "── Backend A ──"
    if python3 -c "import socket; s=socket.socket(); s.settimeout(2); sys.exit(0 if s.connect_ex(('127.0.0.1',${BACKEND_A_PORT}))==0 else 1)" 2>/dev/null; then
        ok "Backend A listening on :${BACKEND_A_PORT}"
    else
        import_check=$(curl -s --max-time 2 "http://127.0.0.1:${BACKEND_A_PORT}/health" 2>/dev/null || echo "")
        if [ "$import_check" = "ok" ]; then
            ok "Backend A listening on :${BACKEND_A_PORT}"
        else
            warn "Backend A NOT running on :${BACKEND_A_PORT}"
            warn "→ Start it in a separate tab: ./scripts/mac3-backend-a.sh"
        fi
    fi
    echo ""
    echo "── Backup DNS (Extension A) ──"
    BIP="$(dig "@${MAC3_IP}" -p "${DNS_PORT}" "app.${DOMAIN}" +short 2>/dev/null | tail -1 || true)"
    if [ -n "$BIP" ]; then
        ok "Backup DNS answering at ${MAC3_IP}: app.${DOMAIN} → ${BIP}"
    else
        warn "Backup DNS NOT running"
        warn "→ Run: ./scripts/phase2-mac3.sh backup-dns"
    fi
    echo ""
    echo "── pf Firewall (Extension C) ──"
    if sudo pfctl -sr 2>/dev/null | grep -q "${BACKEND_A_PORT}"; then
        ok "pf isolation rules are ACTIVE (backend ports ${BACKEND_A_PORT}/${BACKEND_B_PORT} restricted)"
    else
        info "pf isolation NOT active (normal Phase 1 state)"
        info "→ Apply for Extension C: sudo ./scripts/phase2-mac3.sh firewall"
    fi
    echo ""
    echo "── Standby Edge (Extension E) ──"
    STANDBY_CHECK=$(curl -s --max-time 2 --cacert "$REPO_ROOT/deploy/mac2/certs/ca.crt" \
        --resolve "app.${DOMAIN}:${HTTPS_PORT}:127.0.0.1" \
        "https://app.${DOMAIN}/edge-status" 2>/dev/null | head -1 || echo "")
    if [ -n "$STANDBY_CHECK" ]; then
        ok "Standby nginx edge is running on this machine"
    else
        info "Standby nginx edge NOT running"
        info "→ Start for Extension E: ./scripts/phase2-mac3.sh standby-edge"
    fi
    echo ""
    echo "── Phase 2 Actions ──"
    echo "  ./scripts/phase2-mac3.sh backup-dns     # start backup DNS resolver"
    echo "  sudo ./scripts/phase2-mac3.sh firewall  # apply pf isolation (Ext C)"
    echo "  sudo ./scripts/phase2-mac3.sh rollback  # remove pf isolation"
    echo "  ./scripts/phase2-mac3.sh standby-edge   # start standby nginx (Ext E)"
    ;;

backup-dns)
    step "Extension A: Starting backup DNS resolver on Mac 3"
    check_this_mac
    echo ""
    echo "Config: deploy/backup-dns/dnsmasq-backup.conf"
    echo "Listening on: ${MAC3_IP}:${DNS_PORT}"
    echo ""
    "$REPO_ROOT/scripts/start-backup-dns.sh" --fg
    ;;

backup-dns-daemon)
    step "Extension A: Starting backup DNS resolver (background daemon)"
    check_this_mac
    "$REPO_ROOT/scripts/start-backup-dns.sh"
    echo ""
    ok "Backup DNS running in background"
    echo "Test from any Mac:"
    echo "  dig @${MAC3_IP} app.${DOMAIN} +short"
    ;;

firewall)
    step "Extension C: Applying pf backend isolation on Mac 3"
    check_this_mac
    echo ""
    echo "This restricts ports ${BACKEND_A_PORT} and ${BACKEND_B_PORT} to accept"
    echo "connections ONLY from the edge (${MAC2_IP})."
    echo ""
    sudo "$REPO_ROOT/scripts/firewall-apply.sh"
    echo ""
    echo "PROVE IT (run from Mac 1 or Mac 4 — should TIME OUT):"
    echo "  curl --max-time 3 http://${MAC3_IP}:${BACKEND_A_PORT}/health"
    echo ""
    echo "PROVE IT works from Mac 2 (edge) — should return 'ok':"
    echo "  curl --max-time 3 http://${MAC3_IP}:${BACKEND_A_PORT}/health"
    echo ""
    echo "END-TO-END still works:"
    echo "  curl ${EDGE_BASE}/api/status"
    echo ""
    echo "ROLLBACK: sudo ./scripts/phase2-mac3.sh rollback"
    ;;

rollback)
    step "Extension C: Rolling back pf isolation on Mac 3"
    check_this_mac
    sudo "$REPO_ROOT/scripts/firewall-rollback.sh"
    ok "pf isolation removed — backend ports open to LAN again"
    ;;

standby-edge)
    step "Extension E: Starting standby nginx edge on Mac 3"
    check_this_mac
    echo ""
    echo "This runs nginx on Mac 3 with the SAME config as Mac 2."
    echo "nginx will warn this machine does not have MAC2_IP — EXPECTED."
    echo "The certificate SAN wildcard (*.${DOMAIN}) covers this machine too."
    echo "Upstreams (Mac3:${BACKEND_A_PORT}, Mac4:${BACKEND_B_PORT}) are reachable from here."
    echo ""
    "$REPO_ROOT/scripts/mac2-edge.sh"
    ;;

*)
    echo "Unknown action: ${ACTION}"
    echo "Usage: $0 [status|backup-dns|backup-dns-daemon|firewall|rollback|standby-edge]"
    exit 1
    ;;
esac
