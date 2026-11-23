#!/usr/bin/env bash
# =====================================================================
#  demo-phase1.sh — rehearses the GRADED demonstration sequence
#  (brief section 8, steps 1–8) live on the real network.
#
#  Run from a CLIENT Mac (Mac 1 or Mac 4) that:
#    * uses Mac 1 (+ backup) as its DNS server
#    * trusts the team CA in its keychain  (NO curl -k anywhere!)
#
#    ./scripts/demo-phase1.sh          # interactive, pauses per step
#    AUTO=1 ./scripts/demo-phase1.sh   # non-stop (for testing)
# =====================================================================
set -uo pipefail
SYSTEM_TRUST=1     # the graded demo must rely on keychain trust only
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

echo "############################################################"
echo "#  PHASE 1 FINAL DEMONSTRATION — ${DOMAIN}"
echo "#  client: $(hostname)  ($(ifconfig 2>/dev/null | awk '/inet /{print $2}' | grep -v '^127' | head -1))"
echo "############################################################"

# ------------------------------------------------------------------ 1 --
step "DEMO 1 — Topology + IP/service inventory"
cat <<EOF
    Mac 1  ${MAC1_IP}  private DNS (dnsmasq :${DNS_PORT}) + client     ~ Route 53
    Mac 2  ${MAC2_IP}  EDGE nginx (TLS :${HTTPS_PORT}/:${HTTPS_ALT_PORT}, LB)      ~ cloud LB / CDN edge
    Mac 3  ${MAC3_IP}  Backend A (python :${BACKEND_A_PORT})               ~ app-server instance A
    Mac 4  ${MAC4_IP}  Backend B (python :${BACKEND_B_PORT}) + client      ~ app-server instance B

    Diagram: docs/topology.svg   Flow: client -> DNS -> HTTPS -> edge -> A|B
EOF
pause

# ------------------------------------------------------------------ 2 --
step "DEMO 2 — All machines on the same private LAN (ping sweep)"
for pair in "Mac1:${MAC1_IP}" "Mac2:${MAC2_IP}" "Mac3:${MAC3_IP}" "Mac4:${MAC4_IP}"; do
    name="${pair%%:*}"; ip="${pair##*:}"
    if ping -c 2 "$ip" >/dev/null 2>&1; then ok "${name} (${ip}) reachable"; ping -c 1 "$ip" 2>/dev/null | grep -E "bytes from|time=" | head -1 | sed 's/^/      /'
    else fail "${name} (${ip}) NOT reachable"; fi
done
info "(own interface data:  ifconfig en0 | grep 'inet \|ether')"
pause

# ------------------------------------------------------------------ 3 --
step "DEMO 3 — Resolve the private domain through OUR DNS (Task B)"
echo "  \$ dig app.${DOMAIN}   (system resolver -> Mac 1 dnsmasq)"
dig "app.${DOMAIN}" A | sed 's/^/    /'
echo
echo "  \$ dig @${MAC1_IP} app.${DOMAIN} +noall +answer   (ask the server directly)"
dig "@${DNS_SERVER}" -p "${DNS_PORT}" "app.${DOMAIN}" A +noall +answer | sed 's/^/    /'
info "DNS = APPLICATION layer over UDP/53. It only maps name -> IP."
info "Server-side proof: Mac 1 $ tail -f ${RUN_DIR}/dnsmasq-queries.log"
pause

# ------------------------------------------------------------------ 4 --
step "DEMO 4 — Open the service over HTTPS using the DOMAIN NAME (Tasks D+E)"
echo "  \$ curl -v ${EDGE_BASE}/api/status     (note: NO -k flag!)"
curl -v --max-time 8 "${EDGE_BASE}/api/status" 2>&1 | grep -E "Trying|Connected|SSL|TLS|subject|issuer|GET|HTTP/|x-backend|backend|{" | sed 's/^/    /' | head -30
info "Browser equivalent:  open ${EDGE_BASE}   — padlock, no warnings,"
info "because the team CA sits in the System keychain of this Mac."
pause

# ------------------------------------------------------------------ 5 --
step "DEMO 5 — Load balancing across BOTH backends (Task D)"
echo "  \$ for i in \$(seq 10); do curl -sD - -o /dev/null ${EDGE_BASE}/api/status | grep -i x-backend; done"
for i in $(seq 10); do
    curl -sD - -o /dev/null --max-time 8 "${EDGE_BASE}/api/status" 2>/dev/null | tr -d '\r' | grep -i '^x-backend:' | sed "s/^/    request #${i}: /"
done
info "Round-robin: nginx cycles through its upstream pool per request."
info "Edge-side proof: Mac 2 $ tail ${RUN_DIR}/nginx-access.log  (upstream= field)"
pause

# ------------------------------------------------------------------ 6 --
step "DEMO 6 — Packet evidence: DNS, TCP handshake, TLS handshake (Task G)"
cat <<EOF
    Wireshark on the client Mac, capture interface en0 (the Wi-Fi one).
    Display filters to use live (and what to point at):

      dns                          -> query A? app.${DOMAIN} / answer ${MAC2_IP}
      tcp.flags.syn==1             -> SYN, SYN-ACK (note ports: client
                                      ephemeral 49xxx <-> server ${HTTPS_PORT})
      tcp.stream eq <N> && tcp.len==0 && tcp.flags.syn==0 && tcp.flags.ack==1
                                   -> the third ACK of the handshake
      tls.handshake.type==1        -> ClientHello (SNI = app.${DOMAIN})
      tls.handshake.type==2        -> ServerHello
      tls.handshake.type==11       -> Certificate (our edge cert + CA)
      tls.handshake.type==20       -> ChangeCipherSpec (TLS1.2; in TLS1.3
                                      it appears as a compatibility message)
      tls.app_data                 -> EVERYTHING after this is encrypted:
                                      Wireshark cannot read the HTTP layer
                                      (that itself is the proof TLS works)

    Ports recap for the viva: DNS = 53/UDP, HTTPS = ${HTTPS_PORT}/TCP,
    backends = ${BACKEND_A_PORT}/${BACKEND_B_PORT}/TCP (plain HTTP, LAN only).
EOF
if [ "${CAPTURE_NOW:-0}" = "1" ]; then
    info "CAPTURE_NOW=1: recording 30 s with tcpdump while generating traffic..."
    IFACE="$(route get default 2>/dev/null | awk '/interface:/{print $2}' || echo en0)"
    sudo tcpdump -i "$IFACE" -w "$REPO_ROOT/evidence/tcp/demo-capture-$(date +%H%M%S).pcap" "host ${MAC2_IP} or port 53" 2>/dev/null &
    TPID=$!; sleep 1
    dig "app.${DOMAIN}" >/dev/null 2>&1
    curl -s --max-time 8 "${EDGE_BASE}/api/status" -o /dev/null
    sleep 2; sudo kill "$TPID" 2>/dev/null
    ok "pcap saved under evidence/tcp/ — open it in Wireshark"
fi
pause

# ------------------------------------------------------------------ 7 --
step "DEMO 7 — HTTP headers + caching behaviour (Task F)"
echo "  \$ curl -sI ${EDGE_BASE}/api/cached"
curl -sI --max-time 8 "${EDGE_BASE}/api/cached" | sed 's/^/    /'
ETAG="$(curl -sI --max-time 8 "${EDGE_BASE}/api/cached" | tr -d '\r' | awk -F': ' 'tolower($1)=="etag"{print $2}')"
echo
echo "  \$ curl -sI -H 'If-None-Match: ${ETAG}' ${EDGE_BASE}/api/cached"
curl -sI --max-time 8 -H "If-None-Match: ${ETAG}" "${EDGE_BASE}/api/cached" | sed 's/^/    /'
cat <<EOF
    The three cases to explain:
      1. FRESH cache hit   — within max-age=60 the client doesn't even
                             send a request (browser devtools: "from disk
                             cache", 0 bytes on the wire).
      2. CONDITIONAL       — after max-age the client REVALIDATES with
                             If-None-Match; server answers 304, headers
                             only, no body => tiny exchange (above).
      3. FULL new request  — validator changed (try ?version=v2): 200
                             with a complete new body and new ETag.
EOF
pause

# ------------------------------------------------------------------ 8 --
step "DEMO 8 — Fail one backend, service CONTINUES (failure demo #3 + Extension D preview)"
cat <<EOF
    NOW: press Ctrl+C in the Backend A terminal on Mac 3 (or run
         ./scripts/failures.sh  -> scenario 3).
    Then watch what the client sees:
EOF
pause
echo "  \$ 10 requests with Backend A DOWN:"
DOWN_A=0; DOWN_B=0
for i in $(seq 10); do
    B="$(curl -sD - -o /dev/null --max-time 8 "${EDGE_BASE}/api/status" 2>/dev/null | tr -d '\r' | awk -F': ' 'tolower($1)=="x-backend"{print $2}')"
    [ "$B" = "A" ] && DOWN_A=$((DOWN_A+1)); [ "$B" = "B" ] && DOWN_B=$((DOWN_B+1))
    echo "    request #${i}: X-Backend: ${B:-<none>}"
done
if [ "$DOWN_A" -eq 0 ] && [ "$DOWN_B" -ge 1 ]; then
    ok "All traffic served by Backend B — nginx detected A's failures (max_fails=2/fail_timeout=10s) and retried via proxy_next_upstream"
else
    warn "Saw A=${DOWN_A} B=${DOWN_B} — make sure Backend A really was stopped during this step"
fi
cat <<EOF
    Restart Backend A now; within ~10 s (fail_timeout) nginx puts it back
    in the pool and round-robin A/B alternation resumes. That recovery
    without any config change IS Phase 2 Extension D.
EOF
pause

echo
ok "PHASE 1 DEMONSTRATION SEQUENCE COMPLETE (steps 1–8)."
info "Remaining graded steps 9–11 belong to Phase 2 + viva: see"
info "scripts/demo-phase2.sh and docs/VIVA_PREP.md."
