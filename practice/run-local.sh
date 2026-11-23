#!/usr/bin/env bash
# =====================================================================
#  practice/run-local.sh — run the ENTIRE platform on THIS ONE machine:
#  primary DNS + backup DNS + nginx edge + Backend A + Backend B.
#
#  Perfect for rehearsing the demo and viva answers before touching the
#  4-Mac setup, and for recovering on demo day if a laptop dies.
#
#      ./practice/run-local.sh          # start everything
#      ./practice/stop-local.sh         # stop everything
#
#  Needs sudo (dnsmasq :53 and nginx :443/:80 are privileged ports).
#  macOS: a loopback alias 127.0.0.2 is created for the backup DNS.
#
#  Test it:
#      ./scripts/verify.sh --local
#      dig @127.0.0.1 app.<team>.test
#      curl --resolve app.<team>.test:443:127.0.0.1 --cacert deploy/mac2/certs/ca.crt https://app.<team>.test/api/status
#
#  FULL IMMERSION (optional, macOS) — make this Mac a real client of the
#  simulated network, then browse https://app.<team>.test with padlock:
#      sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain deploy/mac2/certs/ca.crt
#      sudo networksetup -setdnsservers Wi-Fi 127.0.0.1 127.0.0.2
#      sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
#      open https://app.<team>.test
#  restore afterwards:
#      sudo networksetup -setdnsservers Wi-Fi Empty
# =====================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
source scripts/common.sh

LCONF_SRC="$REPO_ROOT/deploy/local/nginx.conf"
LCONF="$RUN_DIR_LOCAL/nginx.conf"
LDNS="$REPO_ROOT/deploy/local/dnsmasq.conf"
LDNS_BK="$REPO_ROOT/deploy/local/dnsmasq-backup.conf"

step "0/6 — regenerate configs + certificates"
./scripts/configure.sh > /dev/null
[ -f "$CERT_DIR/edge-fullchain.crt" ] && [ -f "$CERT_DIR/edge.key" ] || ./certs/make-ca-and-cert.sh > /dev/null
ok "deploy/local/* + certificates ready"

step "1/6 — locate binaries"
NGINX_BIN="$(command -v nginx || true)"
[ -n "$NGINX_BIN" ] || for c in /opt/homebrew/bin/nginx /usr/local/bin/nginx /usr/sbin/nginx; do [ -x "$c" ] && NGINX_BIN="$c" && break; done
DNSMASQ_BIN="$(command -v dnsmasq || true)"
[ -n "$DNSMASQ_BIN" ] || for c in /opt/homebrew/sbin/dnsmasq /usr/local/sbin/dnsmasq /usr/sbin/dnsmasq; do [ -x "$c" ] && DNSMASQ_BIN="$c" && break; done
PYTHON_BIN="$(command -v python3 || true)"
[ -n "$NGINX_BIN" ] && [ -n "$DNSMASQ_BIN" ] && [ -n "$PYTHON_BIN" ] || {
    fail "missing binaries (nginx=$NGINX_BIN dnsmasq=$DNSMASQ_BIN python3=$PYTHON_BIN)"
    echo "  macOS: brew install nginx dnsmasq" >&2; exit 1; }
ok "nginx=$NGINX_BIN dnsmasq=$DNSMASQ_BIN python3=$PYTHON_BIN"

step "2/6 — loopback alias for the backup DNS (macOS)"
if [ "$(uname)" = "Darwin" ]; then
    ifconfig lo0 | grep -q "127\.0\.0\.2" || sudo ifconfig lo0 alias 127.0.0.2 up
    ok "127.0.0.2 available on lo0"
else
    ok "Linux: 127.0.0.2 works out of the box"
fi

step "3/6 — finalize local nginx config"
MIME_TYPES=""
for cand in /opt/homebrew/etc/nginx/mime.types /usr/local/etc/nginx/mime.types /etc/nginx/mime.types; do
    [ -f "$cand" ] && MIME_TYPES="$cand" && break
done
[ -n "$MIME_TYPES" ] || { fail "nginx mime.types not found — is nginx installed?"; exit 1; }
mkdir -p "$RUN_DIR_LOCAL/nginx-tmp/client_body" "$RUN_DIR_LOCAL/nginx-tmp/proxy" \
         "$RUN_DIR_LOCAL/nginx-tmp/fastcgi" "$RUN_DIR_LOCAL/nginx-tmp/uwsgi" "$RUN_DIR_LOCAL/nginx-tmp/scgi"
chmod -R 777 "$RUN_DIR_LOCAL/nginx-tmp"
sed -e "s|{{CERT_DIR}}|$CERT_DIR|g" -e "s|{{MIME_TYPES}}|$MIME_TYPES|g" "$LCONF_SRC" > "$LCONF"
ok "$LCONF written (mime.types: $MIME_TYPES)"

step "4/6 — stop any previous local run / check ports"
"$REPO_ROOT/practice/stop-local.sh" --quiet || true
# belt & braces: kill stray local-mode instances from earlier crashed runs
sudo pkill -f "dnsmasq --conf-file=$LDNS" 2>/dev/null || true
sudo pkill -f "dnsmasq --conf-file=$LDNS_BK" 2>/dev/null || true
sleep 1
for p in "$DNS_PORT" "$HTTPS_PORT" "$HTTP_PORT" "$BACKEND_A_PORT" "$BACKEND_B_PORT"; do
    # sudo: root-owned listeners (dnsmasq/nginx) are invisible to plain lsof
    if sudo lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1 || sudo lsof -nP -iUDP:"$p" >/dev/null 2>&1; then
        fail "port $p already in use — stop the conflicting service first (sudo lsof -nP -i :$p)"
        exit 1
    fi
done
ok "all required ports free"

step "5/6 — start the five services"
nohup "$PYTHON_BIN" backends/backend.py --name A --port "$BACKEND_A_PORT" > "$RUN_DIR_LOCAL/backend-a.log" 2>&1 &
echo $! > "$RUN_DIR_LOCAL/backend-a.pid"
nohup "$PYTHON_BIN" backends/backend.py --name B --port "$BACKEND_B_PORT" > "$RUN_DIR_LOCAL/backend-b.log" 2>&1 &
echo $! > "$RUN_DIR_LOCAL/backend-b.pid"
for i in 1 2 3 4 5 6 7 8 9 10; do
    python3 -c "import socket,sys; s=socket.socket(); s.settimeout(1); sys.exit(s.connect_ex(('127.0.0.1',$BACKEND_A_PORT)))" 2>/dev/null \
    && python3 -c "import socket,sys; s=socket.socket(); s.settimeout(1); sys.exit(s.connect_ex(('127.0.0.1',$BACKEND_B_PORT)))" 2>/dev/null && break
    sleep 0.5
done
ok "Backend A :${BACKEND_A_PORT} + Backend B :${BACKEND_B_PORT} (logs: $RUN_DIR_LOCAL/backend-*.log)"

sudo "$DNSMASQ_BIN" --conf-file="$LDNS" --no-resolv
sleep 1
sudo "$DNSMASQ_BIN" --conf-file="$LDNS_BK" --no-resolv
sleep 1
ok "dnsmasq primary @127.0.0.1:${DNS_PORT} + backup @127.0.0.2:${DNS_PORT} (log: $RUN_DIR_LOCAL/dnsmasq-queries.log)"

sudo "$NGINX_BIN" -t -c "$LCONF" 2>&1 | sed 's/^/    /'
sudo "$NGINX_BIN" -c "$LCONF"
sleep 1
ok "nginx edge listening on :${HTTPS_PORT}/:${HTTPS_ALT_PORT} (logs: $RUN_DIR_LOCAL/nginx-*.log)"

step "6/6 — smoke test"
echo "  \$ dig @127.0.0.1 app.${DOMAIN} +short"
dig @127.0.0.1 -p "$DNS_PORT" "app.${DOMAIN}" +short | sed 's/^/    /'
echo "  \$ dig @127.0.0.2 app.${DOMAIN} +short   (backup)"
dig @127.0.0.2 -p "$DNS_PORT" "app.${DOMAIN}" +short | sed 's/^/    /'
echo "  \$ 4x curl https://app.${DOMAIN}/api/status (via --resolve, CA-pinned):"
for i in 1 2 3 4; do
    curl -s --max-time 5 --cacert "$CA_CERT" --resolve "app.${DOMAIN}:${HTTPS_PORT}:127.0.0.1" \
        "https://app.${DOMAIN}${HTTPS_PORT_SUFFIX}/api/status" \
        | python3 -c "import json,sys; d=json.load(sys.stdin); print('    #%d backend=%s status=%s' % ($i, d['backend'], d['status']))"
done

cat <<EOF

============================================================
 LOCAL SIMULATION RUNNING — the whole platform on one machine.

   dig @127.0.0.1 app.${DOMAIN}          (primary DNS)
   dig @127.0.0.2 app.${DOMAIN}          (backup DNS)
   ./scripts/verify.sh --local           (full Phase-1 gate check)
   ./scripts/failures.sh --local a       (all 5 failure demos, automated)
   ./scripts/demo-phase2.sh --local a    (Extension A failover, automated)
   ./scripts/collect-evidence.sh --local

   Stop everything:  ./practice/stop-local.sh
   Full-immersion browser mode: see the comments at the top of this file.
============================================================
EOF
