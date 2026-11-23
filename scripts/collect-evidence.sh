#!/usr/bin/env bash
# =====================================================================
#  collect-evidence.sh — fills the evidence/ folder automatically with
#  text-based proof for Task G and the demo sequence. Run it from a
#  CLIENT Mac once everything passes verify.sh.
#
#    ./scripts/collect-evidence.sh            # real network
#    ./scripts/collect-evidence.sh --local    # practice simulation
#    sudo ./scripts/collect-evidence.sh --capture   # + a real pcap
#                                                   #   (tcpdump)
#  Screenshots (browser, Wireshark GUI) and .pcap exports you capture
#  yourself go in the same folders — see docs/EVIDENCE_CHECKLIST.md.
# =====================================================================
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

LOCAL=0; CAPTURE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --local)   LOCAL=1; shift ;;
        --capture) CAPTURE=1; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

EV="$REPO_ROOT/evidence"
mkdir -p "$EV"/{dns,tcp,tls,http,load-balancing,caching,failures,phase2}
TS="$(date +%Y%m%d-%H%M%S)"

if [ "$LOCAL" = "1" ]; then
    DNS_SERVER="127.0.0.1"; EDGE_IP="127.0.0.1"
    CURL_RESOLVE="--resolve app.${DOMAIN}:${HTTPS_PORT}:127.0.0.1 --resolve app.${DOMAIN}:${HTTPS_ALT_PORT}:127.0.0.1 --resolve api.${DOMAIN}:${HTTPS_PORT}:127.0.0.1"
else
    EDGE_IP="$MAC2_IP"
fi

save() {  # save <category/filename> <description> ; reads stdin
    local f="$EV/$1"
    {
        echo "# $2"
        echo "# collected: $(date) from $(hostname) ($(ifconfig 2>/dev/null | awk '/inet /{print $2}' | grep -v 127.0.0.1 | head -1))"
        echo "# ----------------------------------------------------------"
        cat
    } > "$f"
    echo "  saved $f"
}

step "DNS evidence (Task B / G)"
{ echo "\$ dig @${DNS_SERVER} app.${DOMAIN}"; dig "@${DNS_SERVER}" -p "${DNS_PORT}" "app.${DOMAIN}" A; } 2>&1 \
    | save "dns/01-dig-app-${TS}.txt" "dig app.${DOMAIN} against primary DNS (answer must be the EDGE ip ${EDGE_IP}, TTL ${DNS_TTL})"
{ echo "\$ dig @${DNS_SERVER} api.${DOMAIN}"; dig "@${DNS_SERVER}" -p "${DNS_PORT}" "api.${DOMAIN}" A; \
  echo; echo "\$ nslookup app.${DOMAIN} ${DNS_SERVER}"; nslookup "app.${DOMAIN}" "${DNS_SERVER}"; } 2>&1 \
    | save "dns/02-dig-api-and-nslookup-${TS}.txt" "api record + nslookup cross-check"
[ -f "$RUN_DIR/dnsmasq-queries.log" ] && tail -40 "$RUN_DIR/dnsmasq-queries.log" \
    | save "dns/03-dnsmasq-query-log-${TS}.txt" "dnsmasq server-side query log (queries + forwarded + answers)"

step "TCP / port evidence (Task A / G)"
{ for p in "$DNS_PORT/udp-check-skipped" ; do :; done
  echo "Edge ports reachable from this client:"
  for p in "$HTTPS_PORT" "$HTTPS_ALT_PORT" "$HTTP_PORT"; do
      python3 -c "import socket; s=socket.socket(); s.settimeout(2); r=s.connect_ex(('${EDGE_IP}', ${p})); print('  tcp ${EDGE_IP}:${p} ->', 'OPEN' if r==0 else 'CLOSED/FILTERED (code %d)'%r)"
  done
  echo
  echo "Backend ports (only relevant from the edge; Phase 2 isolation may block):"
  for pair in "${MAC3_IP}:${BACKEND_A_PORT}" "${MAC4_IP}:${BACKEND_B_PORT}"; do
      ip="${pair%%:*}"; port="${pair##*:}"
      python3 -c "import socket; s=socket.socket(); s.settimeout(2); r=s.connect_ex(('${ip}', ${port})); print('  tcp ${ip}:${port} ->', 'OPEN' if r==0 else 'CLOSED/FILTERED (code %d)'%r)"
  done; } 2>&1 | save "tcp/04-port-scan-${TS}.txt" "well-known service ports vs backend ports, probed from the client"

step "TLS evidence (Task E / G)"
{ echo "\$ openssl s_client -connect ${EDGE_IP}:${HTTPS_PORT} -servername app.${DOMAIN} -CAfile ca.crt"
  echo Q | openssl s_client -connect "${EDGE_IP}:${HTTPS_PORT}" -servername "app.${DOMAIN}" -CAfile "$CA_CERT" -showcerts; } 2>&1 \
    | save "tls/05-openssl-s-client-${TS}.txt" "full TLS handshake summary + certificate chain as the client sees it"
{ echo "\$ curl -v ${EDGE_BASE}/api/status   (TLS negotiation lines)"
  curl -v --max-time 8 $CURL_TLS_OPTS $CURL_RESOLVE "${EDGE_BASE}/api/status" -o /dev/null; } 2>&1 \
    | save "tls/06-curl-v-tls-${TS}.txt" "curl -v showing CApath/subject/issuer/ALPN and encrypted transfer"

step "HTTP + headers evidence (Task C / D)"
{ echo "\$ curl -sD - ${EDGE_BASE}/api/status"
  curl -sD - --max-time 8 $CURL_TLS_OPTS $CURL_RESOLVE "${EDGE_BASE}/api/status"; \
  echo; echo "\$ curl -sD - ${EDGE_BASE}/"
  curl -sD - --max-time 8 $CURL_TLS_OPTS $CURL_RESOLVE "${EDGE_BASE}/"; \
  echo; echo "\$ curl -sI http://app.${DOMAIN}${HTTP_PORT_SUFFIX}/   (redirect)"
  curl -sI --max-time 8 $CURL_RESOLVE "http://${APP_HOST}${HTTP_PORT_SUFFIX}/"; } 2>&1 \
    | save "http/07-responses-and-headers-${TS}.txt" "status JSON with X-Backend, welcome JSON, and HTTP->HTTPS 301"

step "Load-balancing evidence (Task D / G)"
{ echo "\$ for i in \$(seq 12); do curl -sD - -o /dev/null .../api/status | grep -i x-backend; done"
  for i in $(seq 12); do
      curl -sD - -o /dev/null --max-time 8 $CURL_TLS_OPTS $CURL_RESOLVE "${EDGE_BASE}/api/status" 2>/dev/null | tr -d '\r' | grep -i '^x-backend:' | sed "s/^/request #${i}: /"
  done; } 2>&1 | save "load-balancing/08-xbackend-alternation-${TS}.txt" "12 consecutive requests showing which backend served each"

step "Caching evidence (Task F)"
ETAG="$(curl -sI --max-time 8 $CURL_TLS_OPTS $CURL_RESOLVE "${EDGE_BASE}/api/cached" 2>/dev/null | tr -d '\r' | awk -F': ' 'tolower($1)=="etag"{print $2}')"
{ echo "\$ curl -sI ${EDGE_BASE}/api/cached"
  curl -sI --max-time 8 $CURL_TLS_OPTS $CURL_RESOLVE "${EDGE_BASE}/api/cached"
  echo; echo "\$ curl -sI -H 'If-None-Match: ${ETAG}' ${EDGE_BASE}/api/cached"
  curl -sI --max-time 8 -H "If-None-Match: ${ETAG}" $CURL_TLS_OPTS $CURL_RESOLVE "${EDGE_BASE}/api/cached"
  echo; echo "(second response = 304 Not Modified: headers only, zero body bytes re-sent)"; } 2>&1 \
    | save "caching/09-cache-control-and-304-${TS}.txt" "Cache-Control/ETag headers + conditional request returning 304"

step "Edge logs (load-balancer side evidence)"
for lg in nginx-access.log nginx-error.log; do
    SRC="$RUN_DIR/nginx-access.log"; [ "$lg" = "nginx-error.log" ] && SRC="$RUN_DIR/nginx-error.log"
    if [ "$LOCAL" = "1" ]; then SRC="$RUN_DIR_LOCAL/$lg"; fi
    [ -f "$SRC" ] && tail -60 "$SRC" | save "http/10-${lg%.log}-${TS}.log" "nginx ${lg} — note client socket pairs and upstream= fields (which backend served)"
done

if [ "$CAPTURE" = "1" ]; then
    step "Packet capture (tcpdump -> open the .pcap in Wireshark)"
    if [ "$LOCAL" = "1" ]; then
        # simulation traffic is loopback: macOS has no "any" device -> lo0
        IFACE="$( [ "$(uname)" = Darwin ] && echo lo0 || echo any )"
    else
        IFACE="$(route get default 2>/dev/null | awk '/interface:/{print $2}' || echo any)"
        [ "$(uname)" != Darwin ] && IFACE="$(ip route show default 2>/dev/null | awk '{print $5; exit}' || echo any)"
    fi
    PCAP="$EV/tcp/11-full-flow-${TS}.pcap"
    echo "  capturing on interface ${IFACE} -> ${PCAP} while generating traffic ..."
    sudo tcpdump -i "$IFACE" -w "$PCAP" "host ${EDGE_IP} or port ${DNS_PORT}" 2>/dev/null &
    TCPDUMP_PID=$!
    sleep 1
    dig "@${DNS_SERVER}" -p "${DNS_PORT}" "app.${DOMAIN}" >/dev/null 2>&1 || true
    curl -s --max-time 8 $CURL_TLS_OPTS $CURL_RESOLVE "${EDGE_BASE}/api/status" -o /dev/null || true
    curl -s --max-time 8 $CURL_TLS_OPTS $CURL_RESOLVE "${EDGE_BASE}/api/cached" -o /dev/null || true
    sleep 1
    sudo kill "$TCPDUMP_PID" 2>/dev/null || true
    sleep 1
    [ -f "$PCAP" ] && echo "  saved $PCAP  (open in Wireshark; filters in docs/EVIDENCE_CHECKLIST.md)"
fi

cat > "$EV/INDEX.md" <<EOF
# Evidence Index — generated ${TS}

| Folder | Contents | Brief reference |
|---|---|---|
| dns/ | dig + nslookup outputs, dnsmasq query log | Task B, G |
| tcp/ | port probes, (packet captures) | Task A, G |
| tls/ | openssl s_client + curl -v handshake records | Task E, G |
| http/ | response headers, redirect, nginx logs | Task C, D, G |
| load-balancing/ | X-Backend alternation over 12 requests | Task D, G |
| caching/ | Cache-Control/ETag + 304 exchange | Task F |
| failures/ | (add screenshots/outputs from scripts/failures.sh) | 6.3 |
| phase2/ | (add outputs from scripts/demo-phase2.sh) | Extensions A–E |

Add Wireshark screenshots + .pcap exports manually per docs/EVIDENCE_CHECKLIST.md.
EOF
echo "  saved $EV/INDEX.md"

ok "Evidence collection complete — see evidence/INDEX.md"
