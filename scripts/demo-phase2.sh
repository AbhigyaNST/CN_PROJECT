#!/usr/bin/env bash
# =====================================================================
#  demo-phase2.sh — rehearses PHASE 2 Extensions A–F on the running
#  Phase 1 network (nothing is rebuilt; we harden the same system).
#
#    ./scripts/demo-phase2.sh            # menu
#    ./scripts/demo-phase2.sh a          # one extension (a..f / all)
#    ./scripts/demo-phase2.sh --local a  # drive the single-machine sim
# =====================================================================
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

LOCAL=0; ARGS=()
for a in "$@"; do
    if [ "$a" = "--local" ]; then LOCAL=1; else ARGS+=("$a"); fi
done
if [ "$LOCAL" = "1" ]; then
    DNS_SERVER="127.0.0.1"; EDGE_IP="127.0.0.1"; BACKUP_DNS="127.0.0.2"
    CURL_RESOLVE=""   # local mode expects system DNS = 127.0.0.1 (+ .2 backup)
    PIDDIR="$RUN_DIR_LOCAL"; LCONF_SRC="$REPO_ROOT/deploy/local/dnsmasq.conf"
    DNSMASQ_BIN="$(command -v dnsmasq || echo /usr/sbin/dnsmasq)"
else
    EDGE_IP="$MAC2_IP"; BACKUP_DNS="$DNS_BACKUP_IP"
fi
getb() { curl -sD - -o /dev/null --max-time 6 $CURL_TLS_OPTS $CURL_RESOLVE "${EDGE_BASE}/api/status" 2>/dev/null | tr -d '\r' | awk -F': ' 'tolower($1)=="x-backend"{print $2}'; }
restart_local_dns() { sudo kill "$(cat "$PIDDIR/dnsmasq.pid")" 2>/dev/null; sleep 1; sudo "$DNSMASQ_BIN" --conf-file="$LCONF_SRC" --no-resolv; sleep 1; }

extension_A() {
step "EXTENSION A — Backup DNS resolver + failover"
cat <<EOF
  SHOW: clients list BOTH resolvers, primary first:
      sudo networksetup -setdnsservers Wi-Fi ${DNS_SERVER} ${BACKUP_DNS}
      sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
EOF
echo "  \$ dig @${DNS_SERVER} app.${DOMAIN} +short   (primary)"
dig "@${DNS_SERVER}" -p "${DNS_PORT}" "app.${DOMAIN}" +short | sed 's/^/    /'
echo "  \$ dig @${BACKUP_DNS} app.${DOMAIN} +short   (backup — same records)"
dig "@${BACKUP_DNS}" -p "${DNS_PORT}" "app.${DOMAIN}" +short | sed 's/^/    /' || warn "backup not answering — start it: ./scripts/start-backup-dns.sh"
cat <<EOF
  NOW STOP THE PRIMARY (Extension A requires it):
EOF
if [ "$LOCAL" = "1" ]; then
    sudo kill "$(cat "$PIDDIR/dnsmasq.pid")" 2>/dev/null && echo "    (local primary dnsmasq stopped)"
    sleep 1
else
    echo "    On Mac 1:  sudo brew services stop dnsmasq"
    pause
fi
echo "  \$ dig app.${DOMAIN} +short    (system resolver: primary dead -> falls back to backup)"
for try in 1 2 3; do
    # +tries=2 lets dig move on to the SECOND nameserver in resolv.conf
    R="$(dig "app.${DOMAIN}" +short +time=2 +tries=2 2>/dev/null | tail -1)"
    [ -n "$R" ] && break
    sleep 2
done
if [ -n "${R:-}" ]; then ok "resolved via backup: ${R} — SERVICE UNAFFECTED by primary DNS death"
else fail "no answer — client DNS list must include ${BACKUP_DNS} as second server"; fi
echo "  ... and the app still works end-to-end:"
getb | sed 's/^/    X-Backend: /'
if [ "$LOCAL" = "1" ]; then
    restart_local_dns; ok "local primary restarted"
else
    echo "  RESTORE on Mac 1:  sudo brew services start dnsmasq"
fi
cat <<EOF

  EXPLAIN (graded): DNS-service failure vs application-server failure —
    * DNS down (both resolvers): names stop resolving; NO connection is
      ever attempted; curl says "could not resolve host". The servers
      themselves are perfectly healthy.
    * App server down: resolution works, TCP/TLS work, the EDGE answers
      502 or failover hides it completely. Different layer, different
      symptom — that distinction is the diagnosis skill being tested.
EOF
pause
}

extension_B() {
step "EXTENSION B — TTL behaviour + controlled record change"
echo "  \$ dig @${DNS_SERVER} app.${DOMAIN} +noall +answer   (look at the TTL column)"
dig "@${DNS_SERVER}" -p "${DNS_PORT}" "app.${DOMAIN}" +noall +answer | sed 's/^/    /'
cat <<EOF
  Our TTL is ${DNS_TTL}s (dnsmasq: local-ttl). On a Mac client the answer is
  cached by mDNSResponder, so watch the countdown there with:
      dscacheutil -q host -a name app.${DOMAIN}      (repeat every few seconds)
EOF
if [ "$LOCAL" = "1" ]; then
    cp "$LCONF_SRC" "$LCONF_SRC.orig"
    # 10.255.255.1 = guaranteed blackhole (NOT a 127.x: on Linux/macOS the
    # whole loopback /8 answers locally, and the edge listens on a wildcard
    # socket — a 127.x "bogus" record would still reach nginx and prove nothing!)
    sed -e "s|^address=/app\.${DOMAIN}/${EDGE_IP}|address=/app.${DOMAIN}/10.255.255.1|" "$LCONF_SRC.orig" > "$LCONF_SRC"
    restart_local_dns
    echo "  (record CHANGED: app.${DOMAIN} -> 10.255.255.1, dnsmasq restarted)"
    echo "  \$ dig @127.0.0.1 app.${DOMAIN} +short   (server now answers the NEW record)"
    dig @127.0.0.1 -p "${DNS_PORT}" "app.${DOMAIN}" +short | sed 's/^/    /'
    echo "  A client whose cache still holds the OLD answer keeps working for <=${DNS_TTL}s;"
    echo "  a client that re-resolves NOW is sent to 10.255.255.1 and fails:"
    curl -s --max-time 3 "${EDGE_BASE}/api/status" -o /dev/null -w '    curl to new (bogus) record -> http_code %{http_code}\n' 2>/dev/null || echo "    curl could not connect (expected — DNS worked, destination is a blackhole)"
    echo "  On macOS: sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder"
    echo "  => the client picks up the NEW record IMMEDIATELY (skipping the TTL wait)."
    mv "$LCONF_SRC.orig" "$LCONF_SRC"; restart_local_dns
    echo "  (record restored:)"
    dig @127.0.0.1 -p "${DNS_PORT}" "app.${DOMAIN}" +short | sed 's/^/    /'
else
    cat <<EOF
  LIVE PROCEDURE (real network):
    1. Mac 1: edit deploy/mac1/dnsmasq.conf -> point app.${DOMAIN} at another IP
       (e.g. ${MAC3_IP}); FULL restart:  sudo brew services restart dnsmasq
       (SIGHUP does NOT reload address= records — classic pitfall!)
    2. Client immediately:  dscacheutil -q host -a name app.${DOMAIN}
       -> still the OLD IP while the cached TTL counts down.
    3. Wait ${DNS_TTL}s (or flush: sudo dscacheutil -flushcache;
       sudo killall -HUP mDNSResponder) -> NEW IP instantly.
    4. Restore the record + restart dnsmasq.
EOF
fi
cat <<EOF

  EXPLAIN (graded): this is exactly how production DNS-based migration /
  traffic cutover works — lower the TTL BEFORE a migration, flip the
  record, and stale clients drift to the new target within one TTL
  window; a manual flush forces it now. Long TTLs = slow rollback.
EOF
pause
}

extension_C() {
step "EXTENSION C — Service isolation (backend firewall rules)"
cat <<EOF
  APPLY on Mac 3 AND Mac 4 (pf rules from deploy/firewall/):
      sudo ./scripts/firewall-apply.sh        # backs up pf state to run/ first

  PROVE it:
      # from Mac 2 (the edge) — WORKS:
      curl --max-time 3 http://${MAC3_IP}:${BACKEND_A_PORT}/health        -> ok
      # from Mac 1 or Mac 4 (clients) — TIMES OUT (packets dropped):
      curl --max-time 3 http://${MAC3_IP}:${BACKEND_A_PORT}/health        -> hangs
      # ... yet the service is perfectly usable through the edge:
      curl ${EDGE_BASE}/api/status                -> 200

  ROLLBACK (required after the demo — the brief demands a restore path):
      sudo ./scripts/firewall-rollback.sh     # restores /etc/pf.conf + prior state

  EXPLAIN (graded):
    * Defense in depth: backends become reachable ONLY through the one
      audited front door. Same idea as cloud security groups: private
      subnets, LB-only ingress to app ports.
    * Dropped (timeout) vs refused is diagnostic: our pf rule DROPS,
      so clients see a timeout; nothing listening would send RST and
      curl would fail instantly with "connection refused".
EOF
pause
}

extension_D() {
step "EXTENSION D — High-availability failover at the load balancer"
if [ "$LOCAL" = "1" ]; then
    pkill -f "backend.py --name A" 2>/dev/null && echo "  (Backend A stopped)" || warn "Backend A wasn't running"
    sleep 1
else
    echo "  >>> Stop Backend A on Mac 3 (Ctrl+C), then press Enter."
    pause
fi
echo "  \$ 8 requests with A down:"
A=0; B=0
for i in $(seq 8); do R="$(getb)"; echo "    #${i}: X-Backend: ${R:-<error>}"; [ "$R" = A ] && A=$((A+1)); [ "$R" = B ] && B=$((B+1)); done
[ "$A" -eq 0 ] && [ "$B" -ge 1 ] && ok "100% served by B — users never saw the failure" || warn "A=${A} B=${B}"
if [ -f "$RUN_DIR_LOCAL/nginx-error.log" ] || [ -f "$RUN_DIR/nginx-error.log" ]; then
    ELOG="$RUN_DIR/nginx-error.log"; [ "$LOCAL" = 1 ] && ELOG="$RUN_DIR_LOCAL/nginx-error.log"
    echo "  nginx error log (edge-side proof of detection + retry):"
    grep -E "connect\(\) failed|upstream|no live" "$ELOG" 2>/dev/null | tail -3 | sed 's/^/    /'
fi
if [ "$LOCAL" = "1" ]; then
    nohup python3 "$REPO_ROOT/backends/backend.py" --name A --port "$BACKEND_A_PORT" > "$RUN_DIR_LOCAL/backend-a.log" 2>&1 &
    echo "  (Backend A restarted — waiting out the 10 s fail_timeout window...)"; sleep 12
    echo "  \$ 8 requests with A back:"
    A=0; B=0
    for i in $(seq 8); do R="$(getb)"; echo "    #${i}: X-Backend: ${R:-<error>}"; [ "$R" = A ] && A=$((A+1)); [ "$R" = B ] && B=$((B+1)); done
    [ "$A" -ge 1 ] && [ "$B" -ge 1 ] && ok "round-robin restored automatically — no config change, no restart of nginx"
else
    echo "  RESTORE: start A again; after fail_timeout (10 s) nginx re-admits it and alternation resumes."
fi
cat <<EOF

  EXPLAIN (graded):
    * Mechanism: proxy_next_upstream retries a FAILED request on the next
      server; max_fails=2 / fail_timeout=10s then parks the bad server.
      These are PASSIVE health checks (learn from real traffic). Cloud
      equivalent: ALB target-group health checks (ACTIVE probes).
    * SINGLE POINT OF FAILURE that remains: the edge itself (nginx on
      Mac 2). If Mac 2 dies, DNS still resolves but every connection is
      refused. Removing it needs redundancy AT the edge: a standby nginx
      + DNS cutover (Extension E — our approach, no new hardware), or a
      floating VIP (keepalived/VRRP — Linux-native; cloud equivalent:
      managed LBs are multi-AZ by default, so the SPOF simply doesn't exist).
EOF
pause
}

extension_E() {
step "EXTENSION E — Controlled edge migration (DNS-based cutover)"
cat <<EOF
  No new hardware needed — the standby reuses Mac 3 (or Mac 4):

  1. STANDBY EDGE on Mac 3 (same repo copy, same finalize logic):
        ./scripts/mac2-edge.sh
     It warns "this machine does not have MAC2_IP" — expected; nginx here
     listens on 0.0.0.0:${HTTPS_PORT} of Mac 3. The cert still validates because
     its SAN wildcard covers *.${DOMAIN} and clients connect BY NAME.
     Upstreams (Mac3:${BACKEND_A_PORT}, Mac4:${BACKEND_B_PORT}) are reachable from Mac 3.

  2. CUTOVER via DNS on Mac 1: edit deploy/mac1/dnsmasq.conf
        address=/app.${DOMAIN}/${MAC3_IP}        # was ${MAC2_IP}
     FULL restart:  sudo brew services restart dnsmasq

  3. OBSERVE THE TTL EFFECT (this is what's graded):
        * clients with a cached answer keep hitting the OLD edge for up
          to ${DNS_TTL}s (curl -D - ... | grep -i x-edge-ip  still shows ${MAC2_IP})
        * fresh lookups land on the STANDBY (x-edge-ip shows ${MAC3_IP})
        * flush forces it now: sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
     The X-Edge-IP response header (nginx \$server_addr) makes the cutover
     directly visible per request — point at it in the demo.

  4. ROLLBACK: restore the record to ${MAC2_IP}, restart dnsmasq, (optionally)
     stop the standby:  sudo nginx -c /tmp/${TEAM}-run/nginx.conf -s stop

  EXPLAIN: this is exactly how real DNS-based failovers/migrations work
  (Route 53 failover records, blue-green cutover) — bounded by TTL, which
  is why ops teams LOWER TTL before a planned cutover (Extension B logic).
EOF
pause
}

extension_F() {
step "EXTENSION F — Faculty-injected fault: the diagnosis METHOD"
cat <<EOF
  Say your reasoning OUT LOUD and walk the layers top-down (partial
  credit is explicitly awarded for methodology). Tool per layer:

    1. DNS      dig app.${DOMAIN}  /  dig @${MAC1_IP} app.${DOMAIN}
                -> no answer?          = DNS layer (server down, client
                  resolver settings, or record removed)
                -> wrong answer?       = DNS layer (record tampered)
    2. IP       ping <resolved IP>
                -> unreachable         = network layer (Wi-Fi, subnet)
    3. TCP      nc -z -v -w2 <ip> ${HTTPS_PORT}   (or curl -v)
                -> refused             = edge service down / wrong port
                -> timeout             = firewall dropping
    4. TLS      openssl s_client -connect <ip>:${HTTPS_PORT} -servername app.${DOMAIN} -CAfile ca.crt
                -> verify fails        = cert replaced/expired/name mismatch
    5. HTTP     curl -v https://app.${DOMAIN}/api/status
                -> 502/504             = edge fine, BACKENDS broken
                -> 200 but wrong data  = application layer
    6. Backend  (from Mac 2!) curl http://${MAC3_IP}:${BACKEND_A_PORT}/health

  Automated version:   ./scripts/diagnose.sh [host] [port]

  Likely injected faults and where they land:
    dnsmasq stopped ............... DNS (no answer)
    record repointed .............. DNS (wrong answer)
    client resolver changed ....... DNS (client-side)
    nginx stopped ................. TCP (refused at :${HTTPS_PORT})
    nginx port changed ............ TCP (refused; :${HTTPS_ALT_PORT} may still work)
    cert swapped / expired ........ TLS (validation error)
    one backend killed ............ NOTHING visible (LB absorbs it — say so!)
    both backends killed .......... HTTP 502 (edge healthy)
    backend firewall enabled ...... edge->backend timeout => 502/504
EOF
echo "  Running diagnose.sh now as a baseline (everything should pass):"
AUTO=1 "$REPO_ROOT/scripts/diagnose.sh" || true
pause
}

menu() {
cat <<EOF

============= PHASE 2 EXTENSIONS (brief section 7) =============
  a) Backup DNS resolver + failover          (Extension A)
  b) DNS TTL + controlled record change      (Extension B)
  c) Service isolation / firewall rules      (Extension C)
  d) HA failover at the load balancer        (Extension D)
  e) Controlled edge migration / cutover     (Extension E)
  f) Troubleshooting methodology             (Extension F)
  all) everything in order      q) quit
================================================================
EOF
printf "  choose: "
}

run_one() {
    case "$1" in
        a) extension_A ;; b) extension_B ;; c) extension_C ;;
        d) extension_D ;; e) extension_E ;; f) extension_F ;;
        all) extension_A; extension_B; extension_C; extension_D; extension_E; extension_F ;;
        *) echo "  invalid choice" ;;
    esac
}

if [ "${#ARGS[@]}" -ge 1 ]; then run_one "${ARGS[0]}"
else while true; do menu; read -r c; [ "$c" = q ] && break; run_one "$c"; done; fi
echo; ok "Phase 2 demonstration complete."
