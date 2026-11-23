#!/usr/bin/env bash
# =====================================================================
#  run-mac1.sh — AUTOMATED ONE-CLICK RUNNER FOR MAC 1
#  Role: Primary Private DNS Server (dnsmasq) + Client
# =====================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$REPO_ROOT/scripts/common.sh"

echo "============================================================"
echo " Starting MAC 1: Primary Private DNS Server (${TEAM}.test)"
echo " Machine IP: ${MAC1_IP}"
echo "============================================================"

# 1. Sanity check IP
if ifconfig 2>/dev/null | grep -q "inet ${MAC1_IP}\b"; then
    ok "IP check passed: this machine is ${MAC1_IP}"
else
    warn "IP check: this machine does not currently have ${MAC1_IP}."
    warn "Continuing, but make sure other machines can reach this IP."
fi

# 2. Check / install dnsmasq
BREW_PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
if have brew && [ ! -x "$BREW_PREFIX/sbin/dnsmasq" ] && ! have dnsmasq; then
    info "Installing dnsmasq via Homebrew..."
    brew install dnsmasq
fi
if have dnsmasq; then DNSMASQ_BIN="$(command -v dnsmasq)"
elif [ -x "$BREW_PREFIX/sbin/dnsmasq" ]; then DNSMASQ_BIN="$BREW_PREFIX/sbin/dnsmasq"
else fail "dnsmasq not found. Install with: brew install dnsmasq"; exit 1; fi

# 3. Deploy configuration
CONF_SRC="$REPO_ROOT/deploy/mac1/dnsmasq.conf"
[ -f "$CONF_SRC" ] || { "$REPO_ROOT/scripts/configure.sh"; }
DEST="$BREW_PREFIX/etc/dnsmasq.conf"
sudo cp "$CONF_SRC" "$DEST"
ok "dnsmasq config deployed to $DEST"
mkdir -p "$RUN_DIR"

# 4. Start dnsmasq cleanly (handles stale launchd bootstrap states)
info "Starting dnsmasq service (requires sudo for port 53)..."
sudo launchctl bootout system /Library/LaunchDaemons/sh.brew.dnsmasq.plist 2>/dev/null || true
sudo brew services stop dnsmasq 2>/dev/null || true
sudo brew services start dnsmasq 2>/dev/null || {
    warn "brew services failed to start. Starting dnsmasq process directly..."
    sudo "$DNSMASQ_BIN" --conf-file="$DEST"
}
sleep 1

# 5. Configure this Mac's client DNS (Dual resolvers: Primary + Backup)
WIFI_DEV="$(networksetup -listallnetworkservices | grep -E -i "wi-fi|airport" | head -1 || echo "Wi-Fi")"
info "Configuring ${WIFI_DEV} DNS to Primary (${MAC1_IP}) + Backup (${DNS_BACKUP_IP})..."
sudo networksetup -setdnsservers "$WIFI_DEV" "${MAC1_IP}" "${DNS_BACKUP_IP}" 2>/dev/null || true
sudo dscacheutil -flushcache 2>/dev/null || true
sudo killall -HUP mDNSResponder 2>/dev/null || true

# 6. Self-test DNS
step "Self-test: resolving app.${DOMAIN}"
sleep 1
ANSWER="$(dig "@127.0.0.1" -p "${DNS_PORT}" "app.${DOMAIN}" +short 2>/dev/null | tail -1 || true)"
if [ "$ANSWER" = "$MAC2_IP" ]; then
    ok "DNS resolution active: app.${DOMAIN} -> ${ANSWER} (Edge: Mac 2)"
else
    warn "Self-test returned '${ANSWER:-no answer}'. Querying directly via binary..."
fi

echo ""
echo "============================================================"
echo " MAC 1 IS FULLY OPERATIONAL!"
echo " Primary DNS: listening on ${MAC1_IP}:${DNS_PORT}"
echo " Query log  : ${RUN_DIR}/dnsmasq-queries.log"
echo "============================================================"
echo ""
echo "Quick Phase 2 controls available:"
echo "  To test Extension A (Kill Primary DNS):"
echo "    sudo brew services stop dnsmasq"
echo "  To restore Primary DNS:"
echo "    sudo brew services start dnsmasq"
echo "  To flip edge to Mac 3 (Extension E Standby Cutover):"
echo "    ./scripts/phase2-mac1.sh flip-to-standby"
echo "============================================================"
