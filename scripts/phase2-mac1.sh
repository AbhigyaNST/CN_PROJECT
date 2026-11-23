#!/usr/bin/env bash
# =====================================================================
#  PHASE 2 — MAC 1 ROLE SCRIPT
#  Mac 1: Primary DNS server (dnsmasq) + test client
#
#  Phase 1 task:  already running (dnsmasq via brew services)
#  Phase 2 tasks:
#    - Ensure dnsmasq is running and serving both records
#    - Extension A demo: stop + restart dnsmasq (primary failover test)
#    - Extension B demo: change the DNS record + restart
#    - Extension E demo: flip app record to Mac 3 for the edge cutover
#
#  Usage:
#    ./scripts/phase2-mac1.sh            # status check + instructions
#    ./scripts/phase2-mac1.sh stop-dns   # stop primary (Extension A demo)
#    ./scripts/phase2-mac1.sh start-dns  # restart primary
#    ./scripts/phase2-mac1.sh flip-to-standby   # flip app record to Mac 3 (Ext E)
#    ./scripts/phase2-mac1.sh flip-to-primary   # restore app record to Mac 2
# =====================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/common.sh"

ACTION="${1:-status}"

DNSMASQ_CONF="$REPO_ROOT/deploy/mac1/dnsmasq.conf"
DNSMASQ_BACKUP="$REPO_ROOT/deploy/mac1/dnsmasq.conf.ext-e-backup"

check_this_mac() {
    if ! ifconfig 2>/dev/null | grep -q "inet ${MAC1_IP}\b"; then
        warn "This machine does not appear to have IP ${MAC1_IP}"
        warn "Are you on the correct Mac? (Expected Mac 1 = ${MAC1_IP})"
        warn "Continuing anyway..."
    else
        ok "IP check: this machine is ${MAC1_IP} (Mac 1)"
    fi
}

case "$ACTION" in

status)
    step "Mac 1 — Phase 2 Status Check"
    check_this_mac
    echo ""
    echo "── DNS Service ──"
    if brew services list 2>/dev/null | grep -E "dnsmasq.*started" > /dev/null 2>&1; then
        ok "dnsmasq is running (brew services)"
    else
        warn "dnsmasq does not appear to be started via brew services"
        echo "  Start it: sudo brew services start dnsmasq"
    fi
    echo ""
    echo "── DNS Records ──"
    for name in "app.${DOMAIN}" "api.${DOMAIN}" "ns1.${DOMAIN}" "ns2.${DOMAIN}"; do
        IP="$(dig "@${MAC1_IP}" -p "${DNS_PORT}" "$name" +short 2>/dev/null | tail -1 || true)"
        if [ -n "$IP" ]; then
            ok "${name} → ${IP}"
        else
            fail "${name} → <no answer> (dnsmasq running? record missing?)"
        fi
    done
    echo ""
    echo "── Backup DNS on Mac 3 (Extension A) ──"
    BIP="$(dig "@${DNS_BACKUP_IP}" -p "${DNS_PORT}" "app.${DOMAIN}" +short 2>/dev/null | tail -1 || true)"
    if [ -n "$BIP" ]; then
        ok "Backup DNS at ${DNS_BACKUP_IP} answers: ${BIP}"
    else
        warn "Backup DNS at ${DNS_BACKUP_IP} not responding"
        warn "→ On Mac 3, run: ./scripts/start-backup-dns.sh"
    fi
    echo ""
    echo "── Phase 2 Actions Available ──"
    echo "  ./scripts/phase2-mac1.sh stop-dns        # kill primary (Extension A)"
    echo "  ./scripts/phase2-mac1.sh start-dns       # restore primary"
    echo "  ./scripts/phase2-mac1.sh flip-to-standby # point app → Mac 3 (Extension E)"
    echo "  ./scripts/phase2-mac1.sh flip-to-primary # restore app → Mac 2"
    ;;

stop-dns)
    step "Extension A: Stopping primary DNS (Mac 1 dnsmasq)"
    check_this_mac
    echo ""
    echo "Before stopping — verify backup is ready:"
    BIP="$(dig "@${DNS_BACKUP_IP}" -p "${DNS_PORT}" "app.${DOMAIN}" +short 2>/dev/null | tail -1 || true)"
    if [ -z "$BIP" ]; then
        warn "Backup DNS at ${DNS_BACKUP_IP} is NOT responding!"
        warn "Start it first on Mac 3: ./scripts/start-backup-dns.sh"
        echo "  Continue anyway? [y/N]"
        read -r ans
        [ "$ans" = "y" ] || exit 1
    else
        ok "Backup DNS ready: ${DNS_BACKUP_IP} → ${BIP}"
    fi
    echo ""
    sudo brew services stop dnsmasq
    ok "Primary DNS stopped. Clients will fall back to ${DNS_BACKUP_IP}."
    echo ""
    echo "Now on a client Mac:"
    echo "  dig app.${DOMAIN} +short   # should resolve via backup"
    echo "  curl ${EDGE_BASE}/api/status   # must still return 200"
    echo ""
    echo "When done: ./scripts/phase2-mac1.sh start-dns"
    ;;

start-dns)
    step "Starting primary DNS (Mac 1 dnsmasq)"
    check_this_mac
    sudo brew services start dnsmasq
    sleep 1
    IP="$(dig "@${MAC1_IP}" -p "${DNS_PORT}" "app.${DOMAIN}" +short 2>/dev/null | tail -1 || true)"
    if [ -n "$IP" ]; then
        ok "Primary DNS restored — app.${DOMAIN} → ${IP}"
    else
        warn "dnsmasq started but not answering yet — give it a moment"
    fi
    ;;

flip-to-standby)
    step "Extension E: Flipping app.${DOMAIN} → Mac 3 (standby edge)"
    check_this_mac
    echo ""
    echo "This changes the DNS record so traffic goes to the STANDBY edge on Mac 3."
    echo "Make sure ./scripts/mac2-edge.sh is running on Mac 3 first!"
    echo ""
    # Backup current conf
    cp "$DNSMASQ_CONF" "$DNSMASQ_BACKUP"
    ok "Backed up: ${DNSMASQ_BACKUP}"
    # Flip the record
    sed -i '' "s|address=/app\.${DOMAIN}/${MAC2_IP}|address=/app.${DOMAIN}/${MAC3_IP}|g" "$DNSMASQ_CONF"
    echo ""
    echo "New app record:"
    grep "address=/app" "$DNSMASQ_CONF"
    echo ""
    sudo brew services restart dnsmasq
    sleep 1
    NEW_IP="$(dig "@${MAC1_IP}" -p "${DNS_PORT}" "app.${DOMAIN}" +short 2>/dev/null | tail -1 || true)"
    ok "DNS now serves: app.${DOMAIN} → ${NEW_IP}"
    echo ""
    echo "On clients, observe the TTL effect:"
    echo "  curl -sD - -o /dev/null ${EDGE_BASE}/edge-status | grep -i x-edge-ip"
    echo "  # Cached clients: X-Edge-IP: ${MAC2_IP}  (old edge, up to TTL=${DNS_TTL}s)"
    echo "  # After flush:    X-Edge-IP: ${MAC3_IP}  (standby serving)"
    echo ""
    echo "Force immediate: sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder"
    ;;

flip-to-primary)
    step "Extension E: Restoring app.${DOMAIN} → Mac 2 (primary edge)"
    check_this_mac
    if [ -f "$DNSMASQ_BACKUP" ]; then
        cp "$DNSMASQ_BACKUP" "$DNSMASQ_CONF"
        ok "Restored from backup"
    else
        # Manual restore
        sed -i '' "s|address=/app\.${DOMAIN}/${MAC3_IP}|address=/app.${DOMAIN}/${MAC2_IP}|g" "$DNSMASQ_CONF"
        ok "Manually restored record to ${MAC2_IP}"
    fi
    sudo brew services restart dnsmasq
    sleep 1
    IP="$(dig "@${MAC1_IP}" -p "${DNS_PORT}" "app.${DOMAIN}" +short 2>/dev/null | tail -1 || true)"
    ok "DNS restored: app.${DOMAIN} → ${IP}"
    ;;

*)
    echo "Unknown action: ${ACTION}"
    echo "Usage: $0 [status|stop-dns|start-dns|flip-to-standby|flip-to-primary]"
    exit 1
    ;;
esac
