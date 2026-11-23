#!/usr/bin/env bash
# =====================================================================
#  failures.sh — the FIVE REQUIRED FAILURE DEMONSTRATIONS (brief 6.3).
#  Each scenario is deliberately broken, observed, explained and then
#  restored. Marks are awarded for the EXPLANATION, not the breakage.
#
#    ./scripts/failures.sh            # menu
#    ./scripts/failures.sh 3          # one scenario
#    ./scripts/failures.sh a          # all, in order
#    ./scripts/failures.sh --local 3  # drive the single-machine sim
#
#  Layer vocabulary used below (be precise in the viva):
#    DNS = application-layer directory service over UDP/53
#    IP  = network-layer reachability
#    TCP = transport-layer connection (ports, handshake)
#    TLS = session security on top of TCP
#    HTTP= application protocol inside the TLS tunnel
# =====================================================================
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

LOCAL=0; ARGS=()
for a in "$@"; do
    if [ "$a" = "--local" ]; then LOCAL=1; else ARGS+=("$a"); fi
done
DNSMASQ_BIN="$(command -v dnsmasq || true)"
[ -n "$DNSMASQ_BIN" ] || for c in /opt/homebrew/sbin/dnsmasq /usr/local/sbin/dnsmasq /usr/sbin/dnsmasq; do [ -x "$c" ] && DNSMASQ_BIN="$c" && break; done
if [ "$LOCAL" = "1" ]; then
    DNS_SERVER="127.0.0.1"; EDGE_IP="127.0.0.1"
    CURL_RESOLVE="--resolve app.${DOMAIN}:${HTTPS_PORT}:127.0.0.1 --resolve app.${DOMAIN}:${HTTPS_ALT_PORT}:127.0.0.1"
    PIDDIR="$RUN_DIR_LOCAL"
else
    EDGE_IP="$MAC2_IP"; PIDDIR="$RUN_DIR_LOCAL"
fi
tcp_check() { python3 -c "import socket,sys; s=socket.socket(); s.settimeout(2); sys.exit(0 if s.connect_ex(('$1',$2))==0 else 1)" 2>/dev/null; }
getb() { curl -sD - -o /dev/null --max-time 6 $CURL_TLS_OPTS $CURL_RESOLVE "${EDGE_BASE}/api/status" 2>/dev/null | tr -d '\r' | awk -F': ' 'tolower($1)=="x-backend"{print $2}'; }

scenario_1() {
step "FAILURE 1 — Client configured with the WRONG DNS server"
cat <<EOF
  SETUP: the client's resolver points somewhere that doesn't know our zone.
  We simulate that by querying a dead address (10.255.255.1:53) instead of Mac 1.
EOF
echo "  \$ dig @10.255.255.1 app.${DOMAIN} +time=2 +tries=1"
dig @10.255.255.1 "app.${DOMAIN}" +time=2 +tries=1 2>&1 | grep -E "SERVER|connection timed out|no servers|status" | sed 's/^/    /'
echo
echo "  ... yet the edge machine itself is perfectly reachable:"
ping -c 1 "$EDGE_IP" >/dev/null 2>&1 && ok "ping ${EDGE_IP} works" || warn "ping ${EDGE_IP} failed"
tcp_check "$EDGE_IP" "$HTTPS_PORT" && ok "TCP ${EDGE_IP}:${HTTPS_PORT} open" || fail "edge port closed"
echo "  \$ dig @${DNS_SERVER} app.${DOMAIN} +short     (correct server)"
dig "@${DNS_SERVER}" -p "${DNS_PORT}" "app.${DOMAIN}" +short | sed 's/^/    /'
cat <<EOF

  EXPECTED OBSERVATION: name lookup fails/times out while direct IP
  connectivity to every machine still works.
  WHY: DNS and IP are INDEPENDENT layers. DNS is an application-layer
  directory that translates names to addresses; if the directory is
  unreachable, the browser cannot even begin a TCP connection — even
  though the network path itself is fine. Typing https://${EDGE_IP}...
  by IP would still work (but our demo rules forbid that — and the cert
  is issued for names, so TLS would complain: another good talking point).
EOF
pause
}

scenario_2() {
step "FAILURE 2 — DNS record points to the WRONG IP address"
cat <<EOF
  SETUP: app.${DOMAIN} still resolves, but to a bogus IP (10.255.255.1).
EOF
if [ "$LOCAL" = "1" ] && [ -f "$PIDDIR/dnsmasq.pid" ]; then
    CONF="$REPO_ROOT/deploy/local/dnsmasq.conf"
    cp "$CONF" "$CONF.orig"
    sed -e "s|^address=/app\.${DOMAIN}\/.*|address=/app.${DOMAIN}/10.255.255.1|" "$CONF.orig" > "$CONF"
    sudo kill "$(cat "$PIDDIR/dnsmasq.pid")" 2>/dev/null; sleep 1
    sudo "$DNSMASQ_BIN" --conf-file="$CONF" --no-resolv; sleep 1
    echo "  (record changed + dnsmasq restarted — note: SIGHUP does NOT reload records, a full restart is needed!)"
    echo "  \$ dig @127.0.0.1 app.${DOMAIN} +short"
    dig @127.0.0.1 -p "${DNS_PORT}" "app.${DOMAIN}" +short | sed 's/^/    /'
    echo "  \$ curl ${EDGE_BASE}/api/status   (DNS now yields 10.255.255.1)"
    curl -s --max-time 4 "${EDGE_BASE}/api/status" -o /dev/null -w '    http code: %{http_code}\n' 2>/dev/null || echo "    curl could not connect (expected — name resolved, destination wrong)"
    # restore
    mv "$CONF.orig" "$CONF"
    sudo kill "$(cat "$PIDDIR/dnsmasq.pid")" 2>/dev/null; sleep 1
    sudo "$DNSMASQ_BIN" --conf-file="$CONF" --no-resolv; sleep 1
    echo "  (record restored)"
    dig @127.0.0.1 -p "${DNS_PORT}" "app.${DOMAIN}" +short | sed 's/^/    restored: /'
else
    cat <<EOF
  LIVE PROCEDURE (real network):
    1. On Mac 1 edit deploy/mac1/dnsmasq.conf:
         address=/app.${DOMAIN}/10.255.255.1
    2. Restart dnsmasq:  sudo brew services restart dnsmasq
       (a full restart — HUP only re-reads /etc/hosts, NOT config records)
    3. On the client:    dig app.${DOMAIN} +short     -> 10.255.255.1  (resolution SUCCEEDS)
                         curl ${EDGE_BASE}/api/status -> hangs / timeout (connection FAILS)
    4. Restore the record and restart dnsmasq again.
EOF
fi
cat <<EOF

  EXPECTED OBSERVATION: DNS answers happily — with the wrong address —
  and the subsequent TCP connection goes nowhere (timeout, since 10.x
  drops silently; a *refused* would mean a live host without the port).
  WHY: DNS is a DIRECTORY, not a connection. It has no idea whether the
  address it returns actually hosts the service. Garbage-in-garbage-out:
  a valid-looking answer sends the client to the wrong destination.
EOF
pause
}

scenario_3() {
step "FAILURE 3 — ONE backend stopped (service must continue)"
cat <<EOF
  SETUP: Backend A (Mac 3) is stopped; Backend B keeps running.
EOF
if [ "$LOCAL" = "1" ]; then
    pkill -f "backend.py --name A" 2>/dev/null && echo "  (killed local Backend A)" || warn "Backend A was not running"
    sleep 1
else
    echo "  >>> NOW press Ctrl+C in the Backend A terminal on Mac 3, then Enter here."
    pause
fi
echo "  \$ 8 requests through the edge while A is down:"
A=0; B=0
for i in $(seq 8); do
    R="$(getb)"; echo "    request #${i}: X-Backend: ${R:-<error>}"
    [ "$R" = "A" ] && A=$((A+1)); [ "$R" = "B" ] && B=$((B+1))
done
if [ "$A" -eq 0 ] && [ "$B" -ge 1 ]; then
    ok "Every request served by B — the SERVICE survived a backend failure"
    info "Mechanism: first attempts to A fail -> proxy_next_upstream retries on B"
    info "(same request!), and after max_fails=2 within fail_timeout=10s nginx"
    info "marks A DOWN and stops even trying it for the next 10 s."
else
    fail "Unexpected distribution A=${A} B=${B}"
fi
if [ "$LOCAL" = "1" ]; then
    nohup python3 "$REPO_ROOT/backends/backend.py" --name A --port "$BACKEND_A_PORT" > "$PIDDIR/backend-a.log" 2>&1 &
    echo "  (restarting local Backend A ...)"
    sleep 12   # > fail_timeout so nginx re-admits A
    echo "  \$ 8 requests after A is back:"
    A=0; B=0
    for i in $(seq 8); do
        R="$(getb)"; echo "    request #${i}: X-Backend: ${R:-<error>}"
        [ "$R" = "A" ] && A=$((A+1)); [ "$R" = "B" ] && B=$((B+1))
    done
    [ "$A" -ge 1 ] && [ "$B" -ge 1 ] && ok "Round-robin restored across both backends" || warn "distribution A=${A} B=${B} (give it another 10 s — fail_timeout window)"
else
    cat <<EOF
  RESTORE: start Backend A again on Mac 3. Within fail_timeout (10 s)
  nginx re-admits it and alternation resumes:
      for i in \$(seq 8); do curl -sD - -o /dev/null ${EDGE_BASE}/api/status | grep -i x-backend; done
EOF
fi
cat <<EOF

  WHY: the load balancer decouples service availability from instance
  availability — exactly what cloud LBs (AWS ALB target groups with
  health checks) do for fleets of app servers.
EOF
pause
}

scenario_4() {
step "FAILURE 4 — BOTH backends stopped (edge vs backend boundary)"
if [ "$LOCAL" = "1" ]; then
    pkill -f "backend.py --name A" 2>/dev/null; pkill -f "backend.py --name B" 2>/dev/null
    echo "  (killed local Backends A and B)"; sleep 1
else
    echo "  >>> NOW stop BOTH backends (Ctrl+C on Mac 3 and Mac 4), then Enter."
    pause
fi
echo "  \$ curl ${EDGE_BASE}/api/status"
CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 $CURL_TLS_OPTS $CURL_RESOLVE "${EDGE_BASE}/api/status" 2>/dev/null || echo 000)
echo "    HTTP status: ${CODE}"
[ "$CODE" = "502" ] && ok "502 Bad Gateway — the textbook answer" || warn "got ${CODE} (502/504 both acceptable; explain which and why)"
echo "  \$ curl ${EDGE_BASE}/edge-status    (served BY the edge itself)"
curl -s --max-time 8 $CURL_TLS_OPTS $CURL_RESOLVE "${EDGE_BASE}/edge-status" | sed 's/^/    /'
echo
info "DNS still resolves. TCP still handshakes. TLS still validates."
info "Only the APPLICATION behind the edge is gone -> nginx answers 502."
if [ "$LOCAL" = "1" ]; then
    nohup python3 "$REPO_ROOT/backends/backend.py" --name A --port "$BACKEND_A_PORT" > "$PIDDIR/backend-a.log" 2>&1 &
    nohup python3 "$REPO_ROOT/backends/backend.py" --name B --port "$BACKEND_B_PORT" > "$PIDDIR/backend-b.log" 2>&1 &
    sleep 1; echo "  (both backends restarted)"
    sleep 11
    getb | sed 's/^/    service restored, X-Backend: /'
else
    echo "  RESTORE: start both backends; service returns within ~10 s (fail_timeout)."
fi
cat <<EOF

  WHY: a 502 pinpoints WHERE the edge ends and the backend begins —
  the reverse proxy did its job (accepted, terminated TLS, tried to
  forward) but got no valid upstream response. Compare with failure 1/2
  where the client never even reached the edge.
EOF
pause
}

scenario_5() {
step "FAILURE 5 — Client connects to the WRONG destination PORT"
echo "  The edge host is reachable and HTTPS works on ${HTTPS_PORT}:"
tcp_check "$EDGE_IP" "$HTTPS_PORT" && ok "TCP ${EDGE_IP}:${HTTPS_PORT} open" || fail "expected ${HTTPS_PORT} open"
echo
echo "  \$ curl --max-time 3 https://app.${DOMAIN}:9443/api/status   (wrong port)"
curl -sk --max-time 3 "https://${APP_HOST}:9443/api/status" -o /dev/null 2>&1
RC=$?
case $RC in
    7) echo "    curl exit 7: connection REFUSED" ;;
    28) echo "    curl exit 28: TIMEOUT" ;;
    *) echo "    curl exit ${RC}" ;;
esac
tcp_check "$EDGE_IP" 9443 && warn "port 9443 unexpectedly open" || ok "TCP ${EDGE_IP}:9443 closed — nothing listens there"
cat <<EOF

  EXPECTED OBSERVATION: the host answers ping and serves ${HTTPS_PORT}, but
  the connection to port 9443 fails instantly (RST -> "connection refused":
  the IP stack itself rejects it because NO socket is bound there).
  WHY: IP address and port are SEPARATE identifiers. Together (plus the
  client's ephemeral port) they form the 4-tuple that identifies a TCP
  connection: (client_ip:client_port <-> server_ip:server_port). Reaching
  a machine says nothing about reaching a SERVICE on it.
  Refused vs timeout is also diagnostic: refused = host up, port closed;
  timeout = packets dropped (firewall — exactly what Extension C does
  to the backend ports!).
EOF
pause
}

menu() {
cat <<EOF

============ REQUIRED FAILURE DEMONSTRATIONS (brief 6.3) ============
  1) Wrong DNS server configured on a client
  2) DNS record points to a wrong IP address
  3) One backend stopped
  4) Both backends stopped
  5) Wrong destination port on the client
  a) ALL of the above, in order
  q) quit
======================================================================
EOF
printf "  choose: "
}

run_one() {
    case "$1" in
        1) scenario_1 ;; 2) scenario_2 ;; 3) scenario_3 ;;
        4) scenario_4 ;; 5) scenario_5 ;;
        a|all) scenario_1; scenario_2; scenario_3; scenario_4; scenario_5 ;;
        *) echo "  invalid choice" ;;
    esac
}

if [ "${#ARGS[@]}" -ge 1 ]; then
    run_one "${ARGS[0]}"
else
    while true; do menu; read -r c; [ "$c" = "q" ] && break; run_one "$c"; done
fi
echo; ok "Failure demonstrations complete — every scenario restored."
