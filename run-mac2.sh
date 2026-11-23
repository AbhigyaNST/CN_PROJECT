#!/usr/bin/env bash
# =====================================================================
#  run-mac2.sh — AUTOMATED ONE-CLICK RUNNER FOR MAC 2
#  Role: Edge Reverse Proxy + Load Balancer + TLS Termination
# =====================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$REPO_ROOT/scripts/common.sh"

echo "============================================================"
echo " Starting MAC 2: Edge Reverse Proxy & Load Balancer"
echo " Machine IP: ${MAC2_IP}"
echo "============================================================"

# 1. Sanity check IP
if ifconfig 2>/dev/null | grep -q "inet ${MAC2_IP}\b"; then
    ok "IP check passed: this machine is ${MAC2_IP}"
else
    warn "IP check: this machine does not currently have ${MAC2_IP}."
fi

# 2. Verify certificates exist
if [ ! -f "$CERT_DIR/edge-fullchain.crt" ] || [ ! -f "$CERT_DIR/edge.key" ]; then
    fail "No certificates found in $CERT_DIR"
    info "Run this first: ./certs/make-ca-and-cert.sh"
    exit 1
fi
ok "Certificates verified in $CERT_DIR"

# 3. Check / install nginx
BREW_PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
if ! have nginx && [ ! -x "$BREW_PREFIX/bin/nginx" ]; then
    info "Installing nginx via Homebrew..."
    brew install nginx
fi
NGINX_BIN="$(command -v nginx 2>/dev/null || echo "$BREW_PREFIX/bin/nginx")"
ok "nginx binary: $NGINX_BIN"

# 4. Finalize configuration
mkdir -p "$RUN_DIR"
CONF_SRC="$REPO_ROOT/deploy/mac2/nginx.conf"
CONF_FINAL="$RUN_DIR/nginx.conf"
[ -f "$CONF_SRC" ] || "$REPO_ROOT/scripts/configure.sh"

# Locate mime.types
MIME_FILE=""
for candidate in "$BREW_PREFIX/etc/nginx/mime.types" /etc/nginx/mime.types /usr/local/etc/nginx/mime.types; do
    if [ -f "$candidate" ]; then MIME_FILE="$candidate"; break; fi
done

sed -e "s|{{CERT_DIR}}|$CERT_DIR|g" \
    -e "s|{{RUN_DIR}}|$RUN_DIR|g" \
    -e "s|include mime\.types;|include ${MIME_FILE};|g" \
    "$CONF_SRC" > "$CONF_FINAL"

# Test configuration
sudo "$NGINX_BIN" -t -c "$CONF_FINAL"

# 5. Start or reload nginx
if [ -f "$RUN_DIR/nginx.pid" ] && kill -0 "$(cat "$RUN_DIR/nginx.pid")" 2>/dev/null; then
    info "nginx already running — reloading configuration..."
    sudo "$NGINX_BIN" -c "$CONF_FINAL" -s reload
else
    info "Starting nginx on ports ${HTTPS_PORT} and ${HTTP_PORT}..."
    sudo "$NGINX_BIN" -c "$CONF_FINAL"
fi
sleep 1

# 6. Self-test over HTTPS
step "Self-test: Edge HTTPS status"
if curl -sS --max-time 5 --cacert "$CA_CERT" --resolve "app.${DOMAIN}:${HTTPS_PORT}:127.0.0.1" \
        "https://app.${DOMAIN}${HTTPS_PORT_SUFFIX}/edge-status" >/dev/null 2>&1; then
    ok "Edge self-test passed: HTTPS + TLS valid (no -k needed)"
else
    warn "Self-test warning — check ${RUN_DIR}/nginx-error.log"
fi

echo ""
echo "============================================================"
echo " MAC 2 EDGE IS LIVE!"
echo " Entrypoint: https://app.${DOMAIN}${HTTPS_PORT_SUFFIX}"
echo " Upstreams : Backend A (${MAC3_IP}:${BACKEND_A_PORT}) + Backend B (${MAC4_IP}:${BACKEND_B_PORT})"
echo " Streaming live access logs below (press Ctrl+C to stop log view)..."
echo "============================================================"
echo ""

exec tail -f "$RUN_DIR/nginx-access.log"
