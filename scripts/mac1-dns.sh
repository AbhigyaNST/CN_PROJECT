#!/usr/bin/env bash
# =====================================================================
#  Run on MAC 1 — deploys + starts the PRIMARY private DNS server
#  (Task B).  Uses Homebrew dnsmasq on macOS; falls back to whatever
#  dnsmasq is on PATH elsewhere.
# =====================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

CONF_SRC="$REPO_ROOT/deploy/mac1/dnsmasq.conf"
[ -f "$CONF_SRC" ] || { echo "Missing $CONF_SRC — run ./scripts/configure.sh first." >&2; exit 1; }

step "Mac 1 setup: private DNS server for ${DOMAIN}"

# --- sanity: is this machine really Mac 1? ------------------------------
if ifconfig 2>/dev/null | grep -q "inet ${MAC1_IP}\b"; then
    ok "This machine has the configured MAC1_IP (${MAC1_IP})"
else
    warn "This machine does NOT have IP ${MAC1_IP}."
    warn "Either fix config.env + re-run configure.sh, or you're on the wrong Mac."
fi

# --- install dnsmasq if needed ------------------------------------------
BREW_PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
if have brew && [ ! -x "$BREW_PREFIX/sbin/dnsmasq" ] && ! have dnsmasq; then
    info "Installing dnsmasq via Homebrew ..."
    brew install dnsmasq
fi
if have dnsmasq; then DNSMASQ_BIN="$(command -v dnsmasq)"
elif [ -x "$BREW_PREFIX/sbin/dnsmasq" ]; then DNSMASQ_BIN="$BREW_PREFIX/sbin/dnsmasq"
else echo "dnsmasq not found — install it first (brew install dnsmasq)." >&2; exit 1; fi
ok "dnsmasq binary: $DNSMASQ_BIN"

# --- deploy the config ---------------------------------------------------
if have brew; then
    DEST="$BREW_PREFIX/etc/dnsmasq.conf"
    if [ -f "$DEST" ]; then
        cp "$DEST" "$RUN_DIR/dnsmasq.conf.pre-project.bak" || true
        info "Existing $DEST backed up to $RUN_DIR/dnsmasq.conf.pre-project.bak"
    fi
    cp "$CONF_SRC" "$DEST"
    ok "Config deployed to $DEST"
    START_MODE="brew"
else
    DEST="$CONF_SRC"   # Linux/other: run straight from the repo
    START_MODE="direct"
fi

mkdir -p "$RUN_DIR"

# --- start ---------------------------------------------------------------
echo
info "Port 53 is a privileged port — sudo is required (this is normal and"
info "worth mentioning in the viva: well-known ports 0–1023 need root)."
if [ "$START_MODE" = "brew" ]; then
    sudo brew services restart dnsmasq
    sleep 1
    if ! sudo brew services list | grep -q "dnsmasq.*started"; then
        warn "brew services didn't report 'started'. Try foreground instead:"
        warn "  sudo $DNSMASQ_BIN --conf-file=$DEST -d"
    fi
else
    [ -f "$RUN_DIR/dnsmasq.pid" ] && sudo kill "$(cat "$RUN_DIR/dnsmasq.pid")" 2>/dev/null || true
    sudo "$DNSMASQ_BIN" --conf-file="$DEST"
    sleep 1
fi

# --- self-test from this machine ------------------------------------------
step "Self-test (dig against ourselves)"
ANSWER="$(dig +short "@127.0.0.1" -p "${DNS_PORT}" "app.${DOMAIN}" A | tail -1)"
if [ "$ANSWER" = "$MAC2_IP" ]; then
    ok "app.${DOMAIN} -> ${ANSWER} (correct: the edge, Mac 2)"
else
    fail "app.${DOMAIN} resolved to '${ANSWER:-<nothing>}' (expected ${MAC2_IP})"
    info "Check: sudo lsof -nP -iUDP:${DNS_PORT}  (is dnsmasq listening?)"
fi
dig "@${MAC1_IP}" -p "${DNS_PORT}" "app.${DOMAIN}" A | sed 's/^/    /'

cat <<EOF

============================================================
 Mac 1 DNS server is running.  Query log: $RUN_DIR/dnsmasq-queries.log

 NEXT — point the CLIENT Macs at this server (run on Mac 4, and
 optionally Mac 2/3 for convenience):

   # list network service names first (usually "Wi-Fi"):
   networksetup -listallnetworkservices

   # Phase 1 (primary only):
   sudo networksetup -setdnsservers Wi-Fi ${MAC1_IP}
   # Phase 2 (primary + backup — Extension A):
   sudo networksetup -setdnsservers Wi-Fi ${MAC1_IP} ${DNS_BACKUP_IP}

   # after changing DNS, flush the client cache:
   sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder

   # verify from the client:
   dig app.${DOMAIN}

 To restore normal DNS later:
   sudo networksetup -setdnsservers Wi-Fi Empty
============================================================
EOF
