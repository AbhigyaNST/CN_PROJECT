#!/usr/bin/env bash
# =====================================================================
#  Run on MAC 2 — deploys + starts THE EDGE: nginx reverse proxy,
#  round-robin load balancer, TLS termination.  (Tasks D + E)
#
#  What it does:
#    1. checks certificates exist (certs/make-ca-and-cert.sh)
#    2. finalizes deploy/mac2/nginx.conf for THIS machine
#       (repo cert path + mime.types location) -> $RUN_DIR/nginx.conf
#    3. validates with nginx -t, then starts/reloads nginx
#    4. self-tests the edge over HTTPS
# =====================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

CONF_SRC="$REPO_ROOT/deploy/mac2/nginx.conf"
CONF_FINAL="$RUN_DIR/nginx.conf"
[ -f "$CONF_SRC" ] || { echo "Missing $CONF_SRC — run ./scripts/configure.sh first." >&2; exit 1; }

step "Mac 2 setup: nginx edge for ${DOMAIN}"

# --- sanity: is this machine really Mac 2 (the edge)? ---------------------
if ifconfig 2>/dev/null | grep -q "inet ${MAC2_IP}\b"; then
    ok "This machine has the configured MAC2_IP (${MAC2_IP})"
else
    warn "This machine does NOT have IP ${MAC2_IP}."
    warn "DNS points app.${DOMAIN} at ${MAC2_IP} — fix config.env or machines!"
fi

# --- certificates ---------------------------------------------------------
if [ ! -f "$CERT_DIR/edge-fullchain.crt" ] || [ ! -f "$CERT_DIR/edge.key" ]; then
    echo "No certificates found in $CERT_DIR" >&2
    echo "Run this first (on any machine, then copy deploy/mac2/certs/ over):" >&2
    echo "    ./certs/make-ca-and-cert.sh" >&2
    exit 1
fi
ok "Certificates present: edge-fullchain.crt + edge.key"

# --- install nginx if needed ----------------------------------------------
BREW_PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
if ! have nginx && [ ! -x "$BREW_PREFIX/bin/nginx" ] && [ ! -x /usr/sbin/nginx ]; then
    if have brew; then
        info "Installing nginx via Homebrew ..."
        brew install nginx
    else
        echo "nginx not found. Install it (macOS: brew install nginx)." >&2; exit 1
    fi
fi
if have nginx; then NGINX_BIN="$(command -v nginx)"
elif [ -x "$BREW_PREFIX/bin/nginx" ]; then NGINX_BIN="$BREW_PREFIX/bin/nginx"
else NGINX_BIN=/usr/sbin/nginx; fi
ok "nginx binary: $NGINX_BIN ($("$NGINX_BIN" -v 2>&1))"

# --- mime.types -----------------------------------------------------------
MIME_TYPES=""
for cand in "$BREW_PREFIX/etc/nginx/mime.types" /usr/local/etc/nginx/mime.types /etc/nginx/mime.types; do
    [ -f "$cand" ] && MIME_TYPES="$cand" && break
done
[ -n "$MIME_TYPES" ] || { echo "Could not find nginx mime.types — is nginx installed?" >&2; exit 1; }
ok "mime.types: $MIME_TYPES"

# --- finalize the runnable config ------------------------------------------
mkdir -p "$RUN_DIR/nginx-tmp/client_body" "$RUN_DIR/nginx-tmp/proxy" \
         "$RUN_DIR/nginx-tmp/fastcgi" "$RUN_DIR/nginx-tmp/uwsgi" "$RUN_DIR/nginx-tmp/scgi"
chmod -R 777 "$RUN_DIR/nginx-tmp"   # worker processes may run as 'nobody'

sed -e "s|{{CERT_DIR}}|$CERT_DIR|g" \
    -e "s|{{MIME_TYPES}}|$MIME_TYPES|g" \
    "$CONF_SRC" > "$CONF_FINAL"
ok "Runnable config written: $CONF_FINAL"

# --- validate ----------------------------------------------------------------
echo
sudo "$NGINX_BIN" -t -c "$CONF_FINAL"

# --- start or reload -----------------------------------------------------------
if [ -f "$RUN_DIR/nginx.pid" ] && kill -0 "$(cat "$RUN_DIR/nginx.pid")" 2>/dev/null; then
    info "nginx already running — reloading"
    sudo "$NGINX_BIN" -c "$CONF_FINAL" -s reload
else
    info "Starting nginx (needs sudo: ports ${HTTPS_PORT}/${HTTP_PORT} are privileged)"
    sudo "$NGINX_BIN" -c "$CONF_FINAL"
fi
sleep 1

# --- self-test ------------------------------------------------------------------
step "Self-test through the edge"
if curl -sS --max-time 5 --cacert "$CA_CERT" --resolve "app.${DOMAIN}:${HTTPS_PORT}:127.0.0.1" \
        "https://app.${DOMAIN}${HTTPS_PORT_SUFFIX}/edge-status" ; then
    echo; ok "Edge answers over HTTPS with a VALIDATED certificate (no -k anywhere)"
else
    fail "Edge self-test failed — check $RUN_DIR/nginx-error.log"
fi

cat <<EOF

============================================================
 EDGE IS LIVE on this machine:
   https://app.${DOMAIN}${HTTPS_PORT_SUFFIX}   (also listens on :${HTTPS_ALT_PORT})
   http://app.${DOMAIN}${HTTP_PORT_SUFFIX}     -> 301 redirect to HTTPS

 Load balancing:  round-robin over
   Backend A  ${MAC3_IP}:${BACKEND_A_PORT}
   Backend B  ${MAC4_IP}:${BACKEND_B_PORT}
   (passive health checks: max_fails=2 fail_timeout=10s,
    failed requests retried on the next backend)

 Logs (evidence!):
   access: $RUN_DIR/nginx-access.log   <- shows which backend served what
   errors: $RUN_DIR/nginx-error.log

 Stop:   sudo $NGINX_BIN -c $CONF_FINAL -s stop
 Reload: sudo $NGINX_BIN -c $CONF_FINAL -s reload

 Remember to trust the CA on every CLIENT Mac (certs/README.md),
 and never demo with curl -k.
============================================================
EOF
