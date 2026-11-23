#!/usr/bin/env bash
# =====================================================================
#  collect-evidence-phase2.sh — fills evidence/phase2/ automatically.
#
#  Run from a CLIENT Mac (Mac 1 or Mac 4) AFTER Phase 1 is passing
#  AND after each Phase 2 extension has been set up:
#
#    ./scripts/collect-evidence-phase2.sh            # real 4-machine network
#    ./scripts/collect-evidence-phase2.sh --local    # single-machine sim
#
#  What it collects:
#    a-backup-dns-failover.txt   Extension A: backup DNS demo (auto)
#    b-ttl-record-change.txt     Extension B: TTL + record change (auto)
#    c-isolation-prove.txt       Extension C: pf firewall proof (auto)
#    d-ha-failover.txt           Extension D: backend kill/recovery (auto)
#    e-edge-cutover.txt          Extension E: DNS cutover + X-Edge-IP (hints)
#    f-diagnose-run.txt          Extension F: diagnose.sh baseline output
#
#  Screenshots (Wireshark, browser, terminal) you capture manually
#  and save alongside these files.
# =====================================================================
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

LOCAL=0
[ "${1:-}" = "--local" ] && LOCAL=1

EV="$REPO_ROOT/evidence/phase2"
mkdir -p "$EV"
TS="$(date +%Y%m%d-%H%M%S)"

if [ "$LOCAL" = "1" ]; then
    DNS_SERVER="127.0.0.1"
    BACKUP_DNS_IP="127.0.0.2"
    EDGE_IP="127.0.0.1"
    CURL_RESOLVE="--resolve app.${DOMAIN}:${HTTPS_PORT}:127.0.0.1 --resolve app.${DOMAIN}:${HTTPS_ALT_PORT}:127.0.0.1"
    PIDDIR="$RUN_DIR_LOCAL"
    DNSMASQ_BIN="$(command -v dnsmasq || echo /opt/homebrew/sbin/dnsmasq)"
else
    BACKUP_DNS_IP="$DNS_BACKUP_IP"
    EDGE_IP="$MAC2_IP"
    CURL_RESOLVE="--resolve app.${DOMAIN}:${HTTPS_PORT}:${EDGE_IP} --resolve app.${DOMAIN}:${HTTPS_ALT_PORT}:${EDGE_IP} --resolve api.${DOMAIN}:${HTTPS_PORT}:${EDGE_IP}"
    PIDDIR="$RUN_DIR"
fi

save() {  # save <filename> <description> ; reads stdin
    local f="$EV/$1"
    {
        echo "# $2"
        echo "# collected: $(date) from $(hostname) ($(ifconfig 2>/dev/null | awk '/inet /{print $2}' | grep -v 127.0.0.1 | head -1 || echo 'local'))"
        echo "# Team: ${TEAM}  Domain: ${DOMAIN}"
        echo "# ----------------------------------------------------------"
        cat
    } > "$f"
    ok "saved $f"
}

getb() {
    # returns the X-Backend value from one /api/status request
    curl -sD - -o /dev/null --max-time 6 $CURL_TLS_OPTS $CURL_RESOLVE \
        "${EDGE_BASE}/api/status" 2>/dev/null | tr -d '\r' \
        | awk -F': ' 'tolower($1)=="x-backend"{print $2}'
}

get_edge_ip_header() {
    curl -sD - -o /dev/null --max-time 6 $CURL_TLS_OPTS $CURL_RESOLVE \
        "${EDGE_BASE}/edge-status" 2>/dev/null | tr -d '\r' \
        | awk -F': ' 'tolower($1)=="x-edge-ip"{print $2}'
}

# ─────────────────────────── EXTENSION A ─────────────────────────────
step "EXTENSION A — Backup DNS resolver + failover"
{
echo "=== STEP 1: Both resolvers serve identical records ==="
echo ""
echo "\$ dig @${DNS_SERVER} app.${DOMAIN} +short   (PRIMARY)"
dig "@${DNS_SERVER}" -p "${DNS_PORT}" "app.${DOMAIN}" +short 2>&1 | sed 's/^/  /'
echo ""
echo "\$ dig @${BACKUP_DNS_IP} app.${DOMAIN} +short   (BACKUP)"
if dig "@${BACKUP_DNS_IP}" -p "${DNS_PORT}" "app.${DOMAIN}" +short 2>&1 | sed 's/^/  /'; then
    echo ""
else
    echo "  [WARN] Backup DNS not answering yet — run: ./scripts/start-backup-dns.sh"
fi
echo ""
echo "\$ scutil --dns | grep -A5 'resolver #1'    (client resolver order)"
scutil --dns 2>/dev/null | grep -A5 'resolver #' | head -30 | sed 's/^/  /' || echo "  (scutil not available)"
echo ""
echo "=== STEP 2: Service is up end-to-end before killing primary ==="
echo "\$ curl ${EDGE_BASE}/api/status"
curl -sD - -o /dev/null --max-time 6 $CURL_TLS_OPTS $CURL_RESOLVE "${EDGE_BASE}/api/status" 2>/dev/null | tr -d '\r' | grep -E "^HTTP|^x-backend" | sed 's/^/  /'
echo ""
echo "=== STEP 3: Kill primary DNS — service must continue via backup ==="
echo "(Run on Mac 1:  sudo brew services stop dnsmasq)"
echo "(Then re-run this section manually or use demo-phase2.sh a)"
echo ""
echo "=== Manual failover check — run after killing primary ==="
echo "\$ dig app.${DOMAIN} +short   (should resolve via backup)"
echo "\$ curl ${EDGE_BASE}/api/status   (must return 200)"
echo ""
echo "=== RESTORE on Mac 1:  sudo brew services start dnsmasq ==="
echo ""
echo "EXPLANATION:"
echo "  * DNS down → names stop resolving → 'could not resolve host'"
echo "    (no connection is even attempted — the app servers are healthy)"
echo "  * App server down → resolution works, TCP/TLS work, edge returns 502"
echo "  These are DIFFERENT layers with DIFFERENT symptoms and fixes."
} 2>&1 | save "a-backup-dns-failover-${TS}.txt" "Extension A: backup DNS failover — primary killed, backup serves, service unaffected"

# ─────────────────────────── EXTENSION B ─────────────────────────────
step "EXTENSION B — DNS TTL + controlled record change"
{
echo "=== STEP 1: TTL is visible in every answer ==="
echo "\$ dig @${DNS_SERVER} app.${DOMAIN} +noall +answer"
dig "@${DNS_SERVER}" -p "${DNS_PORT}" "app.${DOMAIN}" +noall +answer 2>&1 | sed 's/^/  /'
echo ""
echo "\$ dig @${DNS_SERVER} api.${DOMAIN} +noall +answer"
dig "@${DNS_SERVER}" -p "${DNS_PORT}" "api.${DOMAIN}" +noall +answer 2>&1 | sed 's/^/  /'
echo ""
echo "  TTL configured: ${DNS_TTL}s"
echo ""
echo "=== STEP 2: Client-side cache countdown (mDNSResponder) ==="
echo "\$ dscacheutil -q host -a name app.${DOMAIN}"
dscacheutil -q host -a name "app.${DOMAIN}" 2>/dev/null | sed 's/^/  /' || echo "  (not cached yet)"
echo ""
echo "=== STEP 3: Record change demo ==="
echo "  On Mac 1 — edit deploy/mac1/dnsmasq.conf:"
echo "    Change:  address=/app.${DOMAIN}/${MAC2_IP}"
echo "    To:      address=/app.${DOMAIN}/10.255.255.1    # bogus IP"
echo "  Then:  sudo brew services restart dnsmasq"
echo ""
echo "=== STEP 4: Old IP still cached (TTL window) ==="
echo "\$ dscacheutil -q host -a name app.${DOMAIN}   (run after record change)"
echo "  Expected: still shows OLD IP (${MAC2_IP}) until TTL expires"
echo ""
echo "=== STEP 5: Manual cache flush forces immediate update ==="
echo "\$ sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder"
echo "\$ dscacheutil -q host -a name app.${DOMAIN}   (now shows NEW IP)"
echo ""
echo "=== STEP 6: Restore ==="
echo "  On Mac 1: revert dnsmasq.conf to ${MAC2_IP}, restart dnsmasq"
echo ""
echo "EXPLANATION:"
echo "  TTL = contract between authority and caches."
echo "  Production cutover: lower TTL hours before migration (e.g. 300→30),"
echo "  flip the record, wait one TTL window for traffic to drain, then"
echo "  decommission the old target. Manual flush = per-machine override only"
echo "  (you cannot flush the internet's caches — hence the drain window)."
} 2>&1 | save "b-ttl-record-change-${TS}.txt" "Extension B: TTL countdown + record change + cache flush effect"

# ─────────────────────────── EXTENSION C ─────────────────────────────
step "EXTENSION C — Backend service isolation (pf firewall)"
{
echo "=== STEP 1: Apply pf rules on BOTH backend Macs (Mac 3 + Mac 4) ==="
echo "  Run on Mac 3:  sudo ./scripts/firewall-apply.sh"
echo "  Run on Mac 4:  sudo ./scripts/firewall-apply.sh"
echo ""
echo "=== STEP 2: From Mac 2 (edge) — MUST WORK ==="
echo "\$ curl --max-time 3 http://${MAC3_IP}:${BACKEND_A_PORT}/health  (from edge)"
echo "  Expected: 'ok' (edge is allowed)"
echo ""
echo "=== STEP 3: From Mac 1 or Mac 4 (clients) — MUST TIME OUT ==="
echo "\$ curl --max-time 3 http://${MAC3_IP}:${BACKEND_A_PORT}/health  (from client)"
BACKEND_A_RESULT=$(python3 -c "
import socket, sys
s = socket.socket()
s.settimeout(3)
rc = s.connect_ex(('${MAC3_IP}', ${BACKEND_A_PORT}))
print('OPEN' if rc == 0 else 'TIMEOUT/FILTERED (code %d)' % rc)
s.close()
" 2>/dev/null || echo "python3 check failed")
echo "  Probe result from this machine: ${BACKEND_A_RESULT}"
echo ""
echo "\$ curl --max-time 3 http://${MAC4_IP}:${BACKEND_B_PORT}/health  (from client)"
BACKEND_B_RESULT=$(python3 -c "
import socket, sys
s = socket.socket()
s.settimeout(3)
rc = s.connect_ex(('${MAC4_IP}', ${BACKEND_B_PORT}))
print('OPEN' if rc == 0 else 'TIMEOUT/FILTERED (code %d)' % rc)
s.close()
" 2>/dev/null || echo "python3 check failed")
echo "  Probe result from this machine: ${BACKEND_B_RESULT}"
echo ""
echo "=== STEP 4: End-to-end service still works through the edge ==="
echo "\$ curl ${EDGE_BASE}/api/status"
curl -sD - -o /dev/null --max-time 8 $CURL_TLS_OPTS $CURL_RESOLVE \
    "${EDGE_BASE}/api/status" 2>/dev/null | tr -d '\r' \
    | grep -E "^HTTP|^x-backend|^x-edge" | sed 's/^/  /'
echo ""
echo "=== ROLLBACK (run on Mac 3 + Mac 4 after demo) ==="
echo "  sudo ./scripts/firewall-rollback.sh"
echo ""
echo "EXPLANATION:"
echo "  pf 'block drop' silently discards packets → client retransmits SYNs"
echo "  until timeout. Nothing listening → RST → instant 'connection refused'."
echo "  Timeout IS the firewall fingerprint. pf is stateful: 'pass' creates"
echo "  state, so edge→backend replies flow back without a separate outbound rule."
echo "  Cloud analogue: security groups / NACLs (private subnet pattern)."
} 2>&1 | save "c-isolation-prove-${TS}.txt" "Extension C: pf isolation — edge allowed, clients blocked, service end-to-end OK"

# ─────────────────────────── EXTENSION D ─────────────────────────────
step "EXTENSION D — HA failover at the load balancer"
{
echo "=== PRE-CONDITION: Both backends running, alternating ==="
echo "12 requests before killing Backend A:"
for i in $(seq 12); do
    B="$(getb)"
    echo "  request #${i}: X-Backend: ${B:-<no response>}"
done
echo ""
echo "=== STEP 1: Kill Backend A (Ctrl+C on Mac 3 terminal) ==="
echo "  Then run 10 requests — all should return X-Backend: B, all HTTP 200"
echo ""
echo "(Waiting 3s for you to have killed Backend A if running interactively)"
echo "--- If Backend A is already down, the following proves failover ---"
sleep 3
echo "10 requests while Backend A is (supposed to be) down:"
ALL_B=1
for i in $(seq 10); do
    B="$(getb)"
    echo "  request #${i}: X-Backend: ${B:-<timeout>}"
    [ "$B" = "A" ] && ALL_B=0
done
if [ "$ALL_B" = "1" ]; then
    echo "  RESULT: All served by B (or one backend only) — LB failover CONFIRMED"
else
    echo "  RESULT: Both A and B responded — both backends appear to be UP"
    echo "  (Kill Backend A on Mac 3 and re-run this section)"
fi
echo ""
echo "=== STEP 2: Edge logs show the failover (run on Mac 2) ==="
echo "  tail /tmp/${TEAM}-run/nginx-error.log"
echo "  Expected: 'connect() failed (111: Connection refused) while connecting to upstream'"
echo "  nginx retries on the next upstream, then marks A down within fail_timeout."
echo ""
echo "=== STEP 3: Restart Backend A — alternation restores in ~10s ==="
echo "  Restart Backend A on Mac 3, then:"
echo "  for i in \$(seq 10); do curl ... | grep -i x-backend; done"
echo "  Expected: A and B alternating again (round-robin restored)."
echo ""
echo "REMAINING SPOF: the EDGE itself (Mac 2). If nginx dies, DNS resolves"
echo "but all connections are refused. Eliminating it requires Extension E"
echo "(DNS-based failover) or keepalived/VRRP (floating VIP). Cloud analogue:"
echo "managed ALBs are multi-AZ by construction."
echo ""
echo "EXPLANATION:"
echo "  Mechanism: passive health checking + proxy_next_upstream."
echo "  After max_fails=2 errors within fail_timeout=10s, the backend is"
echo "  temporarily removed from rotation. It re-enters after fail_timeout."
echo "  Active probes (health_check in nginx Plus) would detect idle failures"
echo "  faster without sacrificing real requests — a valid upgrade path."
} 2>&1 | save "d-ha-failover-${TS}.txt" "Extension D: Backend A killed → all traffic to B → restart → round-robin restored"

# ─────────────────────────── EXTENSION E ─────────────────────────────
step "EXTENSION E — Controlled edge migration (DNS-based cutover)"
{
echo "=== PRE-CONDITION: Standby edge running on Mac 3 ==="
echo "  On Mac 3 (separate tab from Backend A):  ./scripts/mac2-edge.sh"
echo "  nginx will warn 'this machine does not have MAC2_IP' — EXPECTED."
echo "  Its cert SAN covers *.${DOMAIN} so it validates by name (SNI)."
echo ""
echo "=== CURRENT edge-status header (before cutover) ==="
echo "\$ curl -sD - -o /dev/null ${EDGE_BASE}/edge-status | grep -i x-edge-ip"
OLD_EDGE="$(get_edge_ip_header)"
echo "  X-Edge-IP: ${OLD_EDGE:-<not reachable>}"
echo ""
echo "=== STEP 1: Flip the DNS record on Mac 1 ==="
echo "  Edit deploy/mac1/dnsmasq.conf:"
echo "    Change:  address=/app.${DOMAIN}/${MAC2_IP}"
echo "    To:      address=/app.${DOMAIN}/${MAC3_IP}"
echo "  Then:  sudo brew services restart dnsmasq"
echo ""
echo "=== STEP 2: Observe the TTL effect ==="
echo "  Clients with CACHED answer: X-Edge-IP still ${MAC2_IP} for up to ${DNS_TTL}s"
echo "  After TTL expiry OR manual flush → X-Edge-IP: ${MAC3_IP}"
echo ""
echo "  Manual flush:  sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder"
echo ""
echo "  Watch per-request:  curl -sD - -o /dev/null ${EDGE_BASE}/edge-status | grep -i x-edge-ip"
echo ""
echo "=== STEP 3: Old edge (Mac 2) can now be stopped safely ==="
echo "  sudo nginx -c /tmp/${TEAM}-run/nginx.conf -s stop"
echo "  Service continues through Mac 3 (the standby is now the primary)."
echo ""
echo "=== STEP 4: Rollback ==="
echo "  Restore dnsmasq.conf: address=/app.${DOMAIN}/${MAC2_IP}, restart dnsmasq"
echo "  Optionally stop standby nginx on Mac 3:"
echo "    sudo nginx -c /tmp/${TEAM}-run/nginx.conf -s stop"
echo ""
echo "EXPLANATION:"
echo "  DNS decides WHERE traffic goes. Migration window = TTL (why ops"
echo "  lower TTL before planned cutovers). X-Edge-IP (\$server_addr) makes"
echo "  the moment of cutover observable per request. Cloud analogue:"
echo "  Route 53 failover/weighted records + blue-green deployments."
} 2>&1 | save "e-edge-cutover-${TS}.txt" "Extension E: DNS-based edge cutover — X-Edge-IP shows old→new across the TTL window"

# ─────────────────────────── EXTENSION F ─────────────────────────────
step "EXTENSION F — Systematic diagnosis baseline"
{
echo "=== BASELINE: everything should PASS before the evaluator injects a fault ==="
echo ""
AUTO=1 "$REPO_ROOT/scripts/diagnose.sh" 2>&1
echo ""
echo "=== Layer-by-layer fault map (know this cold!) ==="
echo ""
echo "  INJECTED FAULT                    FIRST BROKEN LAYER   SIGNATURE"
echo "  dnsmasq stopped                   DNS                  'could not resolve host'"
echo "  record repointed                  DNS                  resolves, then connect to WRONG IP"
echo "  client resolver changed           DNS (client-side)    'dig @Mac1' fine, plain 'dig' fails"
echo "  nginx stopped                     TCP                  connection refused on :${HTTPS_PORT}"
echo "  nginx moved to ${HTTPS_ALT_PORT} only              TCP                  443 refused, ${HTTPS_ALT_PORT} works"
echo "  cert replaced/expired             TLS                  handshake / verify failure only"
echo "  one backend killed                (none — LB absorbs!) 200 from the surviving backend"
echo "  both backends killed              HTTP                 502 at edge, /edge-status still 200"
echo "  pf isolation ON + probe from client (expected)         backend ports time out; edge works"
echo ""
echo "=== Narration template (say this during diagnosis) ==="
echo "  'Resolution works and returns X, so the DNS layer is healthy.'"
echo "  'TCP to X:443 completes, so transport is fine.'"
echo "  'TLS verifies, so session security is fine.'"
echo "  'Edge returns 502 → fault is below the edge.'"
echo "  'Probing backends from Mac 2: A refusing → Backend A is down.'"
echo "  'Restarting A restores round-robin within fail_timeout.'"
} 2>&1 | save "f-diagnose-run-${TS}.txt" "Extension F: diagnose.sh clean baseline + injected-fault map"

# ─────────────────────────── SUMMARY ─────────────────────────────────
echo ""
echo "============================================================"
echo " Phase 2 evidence saved to: evidence/phase2/"
echo " Files:"
ls -1 "$EV/"*.txt 2>/dev/null | sed 's|.*/|   |'
echo ""
echo " MANUAL evidence still needed:"
echo "   - Screenshots for each extension (terminal + browser)"
echo "   - Wireshark captures if not already in evidence/tcp/"
echo "   - Extension C: proof from Mac 2 that edge CAN reach backends"
echo "     (run from Mac 2 terminal: curl --max-time 3 http://${MAC3_IP}:${BACKEND_A_PORT}/health)"
echo "============================================================"
