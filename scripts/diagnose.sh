#!/usr/bin/env bash
# =====================================================================
#  diagnose.sh — SYSTEMATIC, LAYER-BY-LAYER diagnosis (Extension F).
#
#  When the faculty injects a fault (or anything breaks), run this from
#  a client Mac and read the verdicts top-to-bottom. The FIRST failing
#  layer tells you where the fault lives:
#
#      DNS  ->  IP reachability  ->  TCP port  ->  TLS  ->  HTTP edge
#           ->  backend health (behind the edge)
#
#    ./scripts/diagnose.sh                      # diagnose app.<team>.test
#    ./scripts/diagnose.sh api.team1.test 8443  # any name/port
# =====================================================================
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

LOCAL=0; POS=()
for a in "$@"; do
    if [ "$a" = "--local" ]; then LOCAL=1; else POS+=("$a"); fi
done
if [ "$LOCAL" = "1" ]; then
    DNS_SERVER="127.0.0.1"; MAC2_IP="127.0.0.1"; MAC3_IP="127.0.0.1"; MAC4_IP="127.0.0.1"
fi
TARGET_HOST="${POS[0]:-$APP_HOST}"
TARGET_PORT="${POS[1]:-$HTTPS_PORT}"
FAILED_LAYER=""
TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT

# dig +short prints ";; no servers could be reached" to STDOUT when the
# server is dead — extract only real IPv4 answers, never error text:
digip() { dig "$@" +short 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | tail -1; }

tcp_check() {
    python3 -c "import socket,sys; s=socket.socket(); s.settimeout(2); sys.exit(0 if s.connect_ex(('$1', $2))==0 else 1)" 2>/dev/null
}

verdict() {  # verdict <ok|fail> <layer> <message> [hint]
    if [ "$1" = ok ]; then ok "$2: $3"
    else
        fail "$2: $3"
        [ -n "${4:-}" ] && note "$4"
        [ -z "$FAILED_LAYER" ] && FAILED_LAYER="$2"
    fi
}

echo "============================================================"
echo " DIAGNOSING: https://${TARGET_HOST}:${TARGET_PORT}"
echo " (method: DNS -> IP -> TCP -> TLS -> HTTP -> backends)"
echo "============================================================"

# ---------------- 1. DNS (Application layer, UDP/53) ----------------
step "1/6 — DNS: can the name be resolved?"
SYS_IP="$(digip "$TARGET_HOST" A)"
SRV_IP="$(digip "@${DNS_SERVER}" -p "${DNS_PORT}" "$TARGET_HOST" A)"
if [ -n "$SRV_IP" ]; then
    verdict ok "DNS" "@${DNS_SERVER} answered: ${TARGET_HOST} -> ${SRV_IP}"
else
    verdict fail "DNS" "our server @${DNS_SERVER}:${DNS_PORT} gave NO answer for ${TARGET_HOST}" \
"Hints: is dnsmasq running on Mac 1 (sudo lsof -nP -iUDP:${DNS_PORT})?
        does the record exist (grep ${TARGET_HOST} deploy/mac1/dnsmasq.conf)?
        is this machine's DNS set to ${MAC1_IP} (scutil --dns | head)?"
fi
if [ -n "$SYS_IP" ] && [ "$SYS_IP" != "$SRV_IP" ]; then
    verdict fail "DNS" "system resolver returned ${SYS_IP} but our server says ${SRV_IP} — client is NOT using our DNS (or a stale cache)" \
"Fix: sudo networksetup -setdnsservers Wi-Fi ${MAC1_IP} ${DNS_BACKUP_IP}
      sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder"
elif [ -z "$SYS_IP" ] && [ -n "$SRV_IP" ]; then
    verdict fail "DNS" "server answers, but THIS machine's system resolver fails — client DNS settings wrong" \
"Fix: sudo networksetup -setdnsservers Wi-Fi ${MAC1_IP}; then flush cache."
fi
EDGE_IP="${SRV_IP:-${SYS_IP:-$MAC2_IP}}"

# ---------------- 2. IP reachability (Network layer) ----------------
step "2/6 — IP: is ${EDGE_IP} reachable at all?"
if ping -c 2 -t 4 "$EDGE_IP" >/dev/null 2>&1 || ping -c 2 "$EDGE_IP" >/dev/null 2>&1; then
    verdict ok "IP" "ping ${EDGE_IP} succeeds (ICMP across the LAN works)"
elif tcp_check "$EDGE_IP" "$TARGET_PORT"; then
    # ICMP is filtered/blocked (hardened hosts, sandboxes) but the host
    # clearly answers TCP — reachability proven at a higher layer instead.
    verdict ok "IP" "ping ${EDGE_IP} blocked, but TCP:${TARGET_PORT} answers — host IS reachable; ICMP is simply filtered (common on hardened hosts)"
else
    verdict fail "IP" "ping ${EDGE_IP} fails — wrong subnet/VLAN, machine off, Wi-Fi isolation, or ICMP blocked" \
"Note: DNS and IP are independent layers — a name can resolve fine to an
 unreachable host (that's exactly failure demo #2). Cross-check with a TCP
 probe before blaming the network layer."
fi

# ---------------- 3. TCP (Transport layer) ----------------
step "3/6 — TCP: is port ${TARGET_PORT} open on ${EDGE_IP}?"
if tcp_check "$EDGE_IP" "$TARGET_PORT"; then
    verdict ok "TCP" "three-way handshake to ${EDGE_IP}:${TARGET_PORT} completes"
else
    verdict fail "TCP" "cannot open TCP connection to ${EDGE_IP}:${TARGET_PORT}" \
"Hints: nginx running on Mac 2? listening on this port (sudo lsof -nP -iTCP:${TARGET_PORT} -sTCP:LISTEN)?
        DNS pointing at the WRONG machine? (demo #2)   Wrong port? (demo #5)"
fi

# ---------------- 4. TLS (Session/Presentation) ----------------
step "4/6 — TLS: does the handshake succeed and the certificate validate?"
TLS_OUT="$(echo Q | openssl s_client -connect "${EDGE_IP}:${TARGET_PORT}" -servername "$TARGET_HOST" -CAfile "$CA_CERT" 2>&1 || true)"
if printf '%s' "$TLS_OUT" | grep -q "Verify return code: 0 (ok)"; then
    verdict ok "TLS" "handshake complete, chain verifies against team CA"
    printf '%s' "$TLS_OUT" | grep -E "subject=|issuer=| s:| i:" | head -2 | sed 's/^/      /'
elif printf '%s' "$TLS_OUT" | grep -q "CONNECTED"; then
    verdict fail "TLS" "TCP connected but certificate validation FAILED" \
"$(printf '%s' "$TLS_OUT" | grep -E "Verify return code|verify error|alert" | head -3)
 Hints: CA not trusted on this Mac? cert expired? name mismatch (SNI)?
        nginx serving the wrong cert / stale config?"
else
    verdict fail "TLS" "no TLS handshake at all — is that port really HTTPS?" \
"Hint: connecting to a plain-HTTP port with https:// gives exactly this."
fi

# ---------------- 5. HTTP through the edge (Application layer) ----------------
step "5/6 — HTTP: what does the edge return?"
BASE="https://${TARGET_HOST}"
[ "$TARGET_PORT" != "443" ] && BASE="${BASE}:${TARGET_PORT}"
RESOLVE_FLAG="--resolve ${TARGET_HOST}:${TARGET_PORT}:${EDGE_IP}"
CODE="$(curl -sS -o "$TMPD/diag-body" -w '%{http_code}' --max-time 6 $CURL_TLS_OPTS $RESOLVE_FLAG "$BASE/api/status" 2>/dev/null || echo 000)"
rm -f "$TMPD/diag-body"
case "$CODE" in
    200) verdict ok "HTTP" "GET ${BASE}/api/status -> 200 — the full stack works" ;;
    301|302) verdict fail "HTTP" "-> ${CODE} redirect (you asked for HTTPS and got redirected? check nginx server_name/port mapping)" ;;
    502) verdict fail "HTTP" "-> 502 Bad Gateway: DNS+TCP+TLS+edge all FINE, but BOTH backends failed" \
"The edge ends here — the fault is behind it: backends down, wrong
 upstream IPs/ports in nginx.conf, or firewall blocking edge->backend." ;;
    504) verdict fail "HTTP" "-> 504 Gateway Timeout: a backend accepted the connection but never replied (hung process? /slow?)" ;;
    000) verdict fail "HTTP" "curl could not complete the request at all (see layers above)" ;;
    *)   verdict fail "HTTP" "-> unexpected status ${CODE}" ;;
esac

# ---------------- 6. Behind the edge: the backends themselves ----------------
step "6/6 — Backends: direct health probes (edge -> backend hops)"
for pair in "A:${MAC3_IP}:${BACKEND_A_PORT}" "B:${MAC4_IP}:${BACKEND_B_PORT}"; do
    bname="${pair%%:*}"; rest="${pair#*:}"; bip="${rest%%:*}"; bport="${rest##*:}"
    BC="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://${bip}:${bport}/health" 2>/dev/null || echo 000)"
    if [ "$BC" = "200" ]; then
        verdict ok "Backend ${bname}" "http://${bip}:${bport}/health -> 200"
    else
        fail "Backend ${bname}: direct probe failed (${BC})"
        note "Either the backend is down — OR this is expected because
      Extension C firewall isolation is active (only the edge may
      reach backend ports). Distinguish by probing FROM Mac 2."
    fi
done

# ---------------- Final verdict ----------------
echo
echo "============================================================"
if [ -z "$FAILED_LAYER" ]; then
    printf '%sVERDICT: every layer healthy — system fully operational.%s\n' "$c_green$c_bold" "$c_off"
else
    printf '%sVERDICT: first broken layer = %s%s\n' "$c_red$c_bold" "$FAILED_LAYER" "$c_off"
    echo
    echo " Everything ABOVE that layer worked; everything below it could"
    echo " not be judged reliably. Fix at that layer, re-run, walk down."
fi
echo "============================================================"
[ -z "$FAILED_LAYER" ] || exit 1
