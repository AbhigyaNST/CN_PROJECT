#!/usr/bin/env bash
# =====================================================================
#  verify.sh — the automated PHASE 1 GATE check (section 5 of the brief:
#  "Phase 1 is complete when a client resolves app.teamX.test, connects
#  over HTTPS, and receives responses from both backends through the
#  load balancer.")
#
#  Run from any machine on the LAN — ideally a CLIENT Mac whose DNS
#  points at Mac 1 and which trusts the team CA.
#
#    ./scripts/verify.sh                 # real 4-machine network
#    ./scripts/verify.sh --local         # single-machine practice sim
#    ./scripts/verify.sh --dns 10.0.0.5 --resolve 10.0.0.6
#    ./scripts/verify.sh --system-trust  # require OS keychain trust
# =====================================================================
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

LOCAL=0; RESOLVE_IP=""
while [ $# -gt 0 ]; do
    case "$1" in
        --local)        LOCAL=1; shift ;;
        --dns)          DNS_SERVER="$2"; shift 2 ;;
        --resolve)      RESOLVE_IP="$2"; shift 2 ;;
        --system-trust) CURL_TLS_OPTS=""; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

EXPECTED_EDGE_IP="$MAC2_IP"
if [ "$LOCAL" = "1" ]; then
    DNS_SERVER="127.0.0.1"
    EXPECTED_EDGE_IP="127.0.0.1"
    CURL_RESOLVE="--resolve app.${DOMAIN}:${HTTPS_PORT}:127.0.0.1 \
--resolve app.${DOMAIN}:${HTTPS_ALT_PORT}:127.0.0.1 \
--resolve api.${DOMAIN}:${HTTPS_PORT}:127.0.0.1 \
--resolve api.${DOMAIN}:${HTTPS_ALT_PORT}:127.0.0.1 \
--resolve ${APP_HOST}:${HTTP_PORT}:127.0.0.1"
elif [ -n "$RESOLVE_IP" ]; then
    EXPECTED_EDGE_IP="$RESOLVE_IP"
    CURL_RESOLVE="--resolve app.${DOMAIN}:${HTTPS_PORT}:${RESOLVE_IP} \
--resolve app.${DOMAIN}:${HTTPS_ALT_PORT}:${RESOLVE_IP} \
--resolve api.${DOMAIN}:${HTTPS_PORT}:${RESOLVE_IP} \
--resolve api.${DOMAIN}:${HTTPS_ALT_PORT}:${RESOLVE_IP} \
--resolve ${APP_HOST}:${HTTP_PORT}:${RESOLVE_IP}"
fi
CURL_RESOLVE="$(printf '%s' "$CURL_RESOLVE" | tr -s ' \n' ' ')"
[ -n "$CURL_RESOLVE" ] && CURL_RESOLVE="$(echo "$CURL_RESOLVE" | sed 's/^ //; s/ --resolve/ --resolve/g')"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

tcp_check() {  # tcp_check <ip> <port>
    python3 -c "import socket,sys; s=socket.socket(); s.settimeout(2); sys.exit(0 if s.connect_ex(('$1', $2))==0 else 1)" 2>/dev/null
}

echo "============================================================"
echo " PHASE 1 VERIFICATION — ${DOMAIN}"
echo "   DNS server under test : ${DNS_SERVER}:${DNS_PORT}"
echo "   Expected edge IP      : ${EXPECTED_EDGE_IP}"
echo "   curl trust mode       : ${CURL_TLS_OPTS:-SYSTEM KEYCHAIN (no flags)}"
echo "============================================================"

# ---------------------------------------------------------------- DNS ----
step "TASK B — DNS resolution (via ${DNS_SERVER})"
for name in "app.${DOMAIN}" "api.${DOMAIN}"; do
    LINE="$(dig "@${DNS_SERVER}" -p "${DNS_PORT}" "$name" A +noall +answer 2>/dev/null | tail -1 || true)"
    IP="$(echo "$LINE" | awk '{print $NF}')"
    TTL="$(echo "$LINE" | awk '{print $2}')"
    if [ "$IP" = "$EXPECTED_EDGE_IP" ]; then
        ok "${name} -> ${IP}  (TTL ${TTL}s)"
        [ "$TTL" = "$DNS_TTL" ] || warn "TTL is ${TTL}, configured ${DNS_TTL}"
    else
        fail "${name} -> '${IP:-<no answer>}' (expected ${EXPECTED_EDGE_IP})"
    fi
done
for name in "backend-a.${DOMAIN}" "backend-b.${DOMAIN}"; do
    IP="$(dig "@${DNS_SERVER}" -p "${DNS_PORT}" "$name" A +short 2>/dev/null | tail -1 || true)"
    [ -n "$IP" ] && info "${name} -> ${IP} (infrastructure record)" || warn "${name} has no answer"
done

# ---------------------------------------------------------------- TCP ----
step "TASK A/D — TCP reachability of the edge ports"
for port in "$HTTPS_PORT" "$HTTPS_ALT_PORT"; do
    if tcp_check "$EXPECTED_EDGE_IP" "$port"; then ok "TCP ${EXPECTED_EDGE_IP}:${port} open"; else fail "TCP ${EXPECTED_EDGE_IP}:${port} closed (nginx running? firewall?)"; fi
done
if tcp_check "$EXPECTED_EDGE_IP" "$HTTP_PORT"; then ok "TCP ${EXPECTED_EDGE_IP}:${HTTP_PORT} open (HTTP redirector)"; else warn "port ${HTTP_PORT} closed (redirect demo will fail; 443/${HTTPS_ALT_PORT} unaffected)"; fi

# ---------------------------------------------------------------- TLS ----
step "TASK E — TLS handshake + certificate validation"
TLS_OUT="$(echo Q | openssl s_client -connect "${EXPECTED_EDGE_IP}:${HTTPS_PORT}" -servername "app.${DOMAIN}" -CAfile "$CA_CERT" 2>/dev/null || true)"
if printf '%s' "$TLS_OUT" | grep -q "Verify return code: 0 (ok)"; then
    ok "Certificate chain verifies against the team CA (code 0)"
else
    fail "Certificate verification failed:"
    printf '%s' "$TLS_OUT" | grep -E "Verify return code|verify error" | sed 's/^/      /'
fi
printf '%s' "$TLS_OUT" | grep -E "subject=|issuer=| s:| i:" | head -4 | sed 's/^/      /'
PROTO="$(printf '%s' "$TLS_OUT" | grep -E "Protocol *:|New, TLS" | head -1)"
[ -n "$PROTO" ] && info "Negotiated: $PROTO"

# --------------------------------------------------------------- HTTP ----
step "TASK D — HTTP(S) through the edge"
CODE="$(curl_edge -s -o "$TMP/root.json" -w '%{http_code}' "${EDGE_BASE}/" || echo 000)"
if [ "$CODE" = "200" ]; then ok "GET ${EDGE_BASE}/ -> 200"; else fail "GET ${EDGE_BASE}/ -> ${CODE}"; fi

HDRS="$(curl_edge -s -o "$TMP/status.json" -D - "${EDGE_BASE}/api/status" | tr -d '\r' || true)"
XB="$(printf '%s' "$HDRS" | awk -F': ' 'tolower($1)=="x-backend"{print $2}' | head -1)"
CODE="$(printf '%s' "$HDRS" | head -1 | awk '{print $2}')"
if [ "$CODE" = "200" ] && printf '%s' "$HDRS" | grep -qi '^x-backend:'; then
    ok "GET /api/status -> 200 with X-Backend: ${XB}"
    grep -q "\"backend\"" "$TMP/status.json" && ok "JSON body contains the backend identifier"
else
    fail "GET /api/status -> code ${CODE}, X-Backend '${XB:-missing}'"
fi

CODE="$(curl_edge -s -o /dev/null -w '%{http_code}' "${EDGE_BASE}/edge-status" || echo 000)"
[ "$CODE" = "200" ] && ok "GET /edge-status -> 200 (edge alive independent of backends)" || fail "GET /edge-status -> ${CODE}"

CODE="$(curl_edge -s -o /dev/null -D "$TMP/redir" -w '%{http_code}' "http://${APP_HOST}${HTTP_PORT_SUFFIX}/" || echo 000)"
LOC="$(grep -i '^location:' "$TMP/redir" 2>/dev/null | head -1 || true)"
if [ "$CODE" = "301" ] && printf '%s' "$LOC" | grep -q "https://"; then
    ok "http:// -> 301 redirect to HTTPS (${LOC})"
else
    warn "HTTP redirect check: code ${CODE} ${LOC}"
fi

# ------------------------------------------------- LOAD BALANCING --------
step "TASK D — round-robin load balancing (12 requests)"
: > "$TMP/lb.txt"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    curl_edge -s -o /dev/null -D - "${EDGE_BASE}/api/status" 2>/dev/null \
        | tr -d '\r' | awk -F': ' 'tolower($1)=="x-backend"{print $2}' >> "$TMP/lb.txt" || true
done
COUNT_A="$(grep -c '^A$' "$TMP/lb.txt" || true)"
COUNT_B="$(grep -c '^B$' "$TMP/lb.txt" || true)"
info "distribution: Backend A = ${COUNT_A}, Backend B = ${COUNT_B}   (sequence: $(paste -sd, "$TMP/lb.txt"))"
if [ "$COUNT_A" -ge 1 ] && [ "$COUNT_B" -ge 1 ]; then
    ok "Both backends served traffic through the same domain name"
else
    fail "Only one backend answered — is the other running? check nginx error log"
fi

# ------------------------------------------------------------ CACHING ----
step "TASK F — caching headers + conditional request (304)"
H="$(curl_edge -sI "${EDGE_BASE}/api/cached" | tr -d '\r' || true)"
CC="$(printf '%s' "$H" | awk -F': ' 'tolower($1)=="cache-control"{print $2}' | head -1)"
ETAG="$(printf '%s' "$H" | awk -F': ' 'tolower($1)=="etag"{print $2}' | head -1)"
LM="$(printf '%s' "$H" | awk -F': ' 'tolower($1)=="last-modified"{print $2}' | head -1)"
printf '%s' "$CC" | grep -q "max-age=60" && ok "Cache-Control: ${CC}" || fail "Cache-Control missing/wrong: '${CC:-none}'"
[ -n "$ETAG" ] && ok "ETag: ${ETAG}" || fail "ETag missing"
[ -n "$LM" ] && info "Last-Modified: ${LM}"
if [ -n "$ETAG" ]; then
    CODE="$(curl_edge -s -o /dev/null -w '%{http_code}' -H "If-None-Match: ${ETAG}" "${EDGE_BASE}/api/cached" || echo 000)"
    [ "$CODE" = "304" ] && ok "Conditional request with If-None-Match -> 304 Not Modified" \
                        || fail "Conditional request returned ${CODE} (expected 304)"
fi

# --------------------------------------------- PHASE 2 (informational) ---
BACKUP_TARGET="$DNS_BACKUP_IP"
[ "$LOCAL" = "1" ] && BACKUP_TARGET="127.0.0.2"
step "PHASE 2 preview — backup DNS resolver at ${BACKUP_TARGET}"
BIP="$(dig "@${BACKUP_TARGET}" -p "${DNS_PORT}" "app.${DOMAIN}" A +short 2>/dev/null | tail -1 || true)"
if [ "$BIP" = "$EXPECTED_EDGE_IP" ]; then ok "backup resolver answers identically (Extension A ready)"
else warn "backup resolver not answering yet (fine for Phase 1 — start it for Phase 2)"; fi

summary
