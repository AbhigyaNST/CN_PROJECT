# Phase 2 Setup Guide — Harden, Recover, Troubleshoot (Extensions A–F)

Phase 2 **extends the Phase 1 network — nothing is rebuilt**. Work through
A → E in order; F is the live diagnosis drill. `./scripts/demo-phase2.sh`
rehearses every extension (add `--local` to drive the single-machine sim).

---

## Extension A — Backup DNS resolver

**Setup**

1. On **Mac 3** (any machine that is *not* Mac 1): install dnsmasq
   (`brew install dnsmasq`) and start the backup resolver:

   ```bash
   ./scripts/start-backup-dns.sh          # background daemon
   ./scripts/start-backup-dns.sh --fg     # or foreground (watch queries live)
   ```

   Config: `deploy/backup-dns/dnsmasq-backup.conf` — the **same zone, same
   records, same TTL**, listening on Mac 3's IP. Consistency matters: if
   the two servers disagreed, clients would see random answers depending
   on which resolver replied (split-horizon accidents are a classic
   production outage).
2. On every client Mac, list **both** resolvers, primary first:

   ```bash
   sudo networksetup -setdnsservers Wi-Fi <MAC1_IP> <DNS_BACKUP_IP>
   sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
   scutil --dns | head -20          # confirm resolver order
   ```

**Demo**

```bash
dig @<MAC1_IP> app.team1.test +short        # primary answers
dig @<DNS_BACKUP_IP> app.team1.test +short  # backup answers identically

# kill the primary (Mac 1):
sudo brew services stop dnsmasq

dig app.team1.test +short                   # client: primary times out,
                                            # resolver falls back to backup
curl https://app.team1.test/api/status      # service completely unaffected

# restore:
sudo brew services start dnsmasq
```

**Explain:** the fallback costs one resolver-timeout (a few seconds on the
first query; cached answers hide it entirely). This is why real DNS is
always ≥2 servers (Route 53 runs anycast fleets). **DNS-service failure vs
application failure:** DNS down ⇒ names don't resolve, no connection is
even attempted (`could not resolve host`); app down ⇒ resolution works,
TCP/TLS work, the edge answers 502 (or failover hides it). Different
layers, different symptoms, different fixes.

---

## Extension B — DNS TTL and controlled record change

Our zone already runs `local-ttl=30` (config.env `DNS_TTL`).

**Demo (client Mac)**

```bash
# 1. TTL is visible in every answer:
dig app.team1.test +noall +answer        # app.team1.test.  30  IN  A  <MAC2_IP>

# 2. Watch the CLIENT-SIDE cache countdown (macOS resolver):
dscacheutil -q host -a name app.team1.test   # repeat every ~10 s

# 3. Change the record on Mac 1 (e.g. point app at Mac 3's IP):
#    edit deploy/mac1/dnsmasq.conf -> address=/app.team1.test/<MAC3_IP>
sudo brew services restart dnsmasq       # FULL restart — HUP is NOT enough!

# 4. Client behaviour:
dscacheutil -q host -a name app.team1.test   # still the OLD IP while TTL runs
sleep 30                                     # ... one TTL window later:
dscacheutil -q host -a name app.team1.test   # NEW IP

# 5. Skip the wait with a manual flush:
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
dscacheutil -q host -a name app.team1.test   # NEW IP immediately

# 6. RESTORE the record + restart dnsmasq.
```

(`scripts/demo-phase2.sh --local b` automates the whole arc against a bogus
IP so nothing real breaks.)

**Explain:** TTL is a contract between authority and caches — an upper
bound on staleness and a lower bound on propagation speed. Production
cutover procedure: **lower TTL hours before** the migration (e.g. 300→30),
flip the record, watch traffic drain across one TTL window, keep the old
target alive until caches expire, then decommission. Flush = the impatient
operator's override, per machine only (you can never flush *the internet's*
caches — hence the drain window).

---

## Extension C — Service isolation (backend firewall rules)

**Concept:** backends should be reachable **only** through the edge. We
enforce that with macOS `pf` on Mac 3 and Mac 4.

**Setup + demo (on BOTH backend Macs)**

```bash
sudo ./scripts/firewall-apply.sh      # backs up pf state to run/, then applies
```

Rules (`deploy/firewall/backend-isolation.pf.conf`): keep Apple's stock
anchors, then
`pass in quick proto tcp from <MAC2_IP> to any port {3001,3002}` followed by
`block drop in quick proto tcp from any to any port {3001,3002}`.

```bash
# from Mac 2 (edge) — WORKS:
curl --max-time 3 http://<MAC3_IP>:3001/health          # ok

# from Mac 1 / Mac 4 (clients) — TIMES OUT:
curl --max-time 3 http://<MAC3_IP>:3001/health          # hangs... dropped

# ...but the actual service is untouched through the edge:
curl https://app.team1.test/api/status                  # 200
```

**Rollback (mandatory — the brief requires a restore path):**

```bash
sudo ./scripts/firewall-rollback.sh   # reloads /etc/pf.conf, restores prior on/off state
```

**Explain:**
* *Timeout vs refused* is the fingerprint: `block drop` silently discards →
  client retransmits SYNs until timeout. Nothing listening would reply RST →
  instant "connection refused". You can identify a firewall purely from the
  failure mode.
* pf is **stateful**: the `pass` rule creates connection state, so return
  traffic flows without an explicit outbound rule.
* `quick` short-circuits rule evaluation — order + quick = precise policy.
* Cloud analogue: security groups / NACLs — instances in private subnets
  accept app-port traffic **only** from the load balancer's security group.
* Defense in depth: even if a client is compromised, it cannot probe or
  hit backends directly; all traffic must pass the one audited front door.

---

## Extension D — High-availability failover at the load balancer

Already configured in `nginx.conf`; this extension is about *proving* it.

```bash
# 1. Stop Backend A on Mac 3 (Ctrl+C). Then from a client, 10 requests:
for i in $(seq 10); do curl -sD - -o /dev/null https://app.team1.test/api/status | grep -i x-backend; done
#    -> every response X-Backend: B, every HTTP status 200. Users saw nothing.

# 2. Edge-side proof (Mac 2):
tail /tmp/team1-run/nginx-error.log
#    connect() failed (111: Connection refused) while connecting to upstream ...
#    ... nginx retried the SAME request on the next upstream, then parked A
#        after max_fails=2 within the fail_timeout=10s window.

# 3. Restart Backend A. Wait ~10 s (fail_timeout expiry):
for i in $(seq 10); do curl -sD - -o /dev/null https://app.team1.test/api/status | grep -i x-backend; done
#    -> A and B alternate again. Zero config changes, zero restarts of nginx.
```

**Explain:**
* Mechanism = **passive** health checking (learn from real traffic failures)
  + `proxy_next_upstream error timeout http_502 http_503 http_504`
  (retry budget: `proxy_next_upstream_tries 2`).
* Cloud LBs mostly use **active** probes (ALB pings `/health` every N
  seconds, marks targets healthy/unhealthy out-of-band). Trade-off: active
  detects idle-failures faster and avoids sacrificing real requests;
  passive is zero-overhead and needs no probe endpoint. We ship a
  `/health` endpoint so an active-check upgrade (`health_check` in
  nginx Plus, or a cron+curl watchdog) is trivial — say that.
* **Remaining single point of failure: the edge itself (Mac 2).** If it
  dies, DNS still resolves but every connection is refused. Eliminating it
  needs redundancy *at* the edge → Extension E (our no-hardware answer), a
  floating VIP via VRRP/keepalived (Linux-native, not macOS), or the cloud
  answer: managed LBs are multi-AZ by construction.

---

## Extension E — Controlled edge migration (DNS-based cutover)

**Setup — standby edge on Mac 3** (no new hardware; Mac 4 works too):

```bash
# on Mac 3 (which already has the repo + certs):
./scripts/mac2-edge.sh
# it WARNs "this machine does not have MAC2_IP" — expected and fine:
#   nginx listens on 0.0.0.0:443 of Mac 3, upstreams are Mac3:3001 +
#   Mac4:3002 (both reachable), and the certificate STILL VALIDATES on
#   clients because its SAN wildcard covers *.team1.test and clients
#   connect BY NAME (SNI), not by IP.
```

**Cutover demo:**

```bash
# 1. On Mac 1, flip the edge record:  address=/app.team1.test/<MAC3_IP>
sudo brew services restart dnsmasq

# 2. On a client — watch WHICH edge answers, per request:
curl -sD - -o /dev/null https://app.team1.test/api/status | grep -i x-edge-ip
#    cached clients:      X-Edge-IP: <MAC2_IP>   (old edge, up to TTL=30 s)
#    after expiry/flush:  X-Edge-IP: <MAC3_IP>   (standby now serving)
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder   # force it

# 3. Meanwhile: stop nginx on Mac 2 entirely — service continues via the
#    standby. (That's the SPOF being removed, live.)

# 4. Rollback: restore the record to <MAC2_IP>, restart dnsmasq,
#    (optionally) stop the standby:  sudo nginx -c /tmp/team1-run/nginx.conf -s stop
```

**Explain:** both edges serve the same domain with the same certificate
policy; DNS decides *where* traffic goes. Migration window = TTL, which is
why ops lower TTL before planned cutovers (Extension B logic in
production). The `X-Edge-IP` header (nginx `$server_addr`) makes the
cutover observable per request — evaluators can see the exact moment
traffic moves. Cloud analogue: Route 53 failover/weighted records in front
of multi-region deployments; blue-green cutover.

---

## Extension F — Faculty-injected fault: systematic diagnosis

The graded skill is **method**, not luck. Walk layers top-down, say each
step out loud, and let the evidence narrow the fault. `./scripts/diagnose.sh`
automates exactly this walk; know it cold anyway:

```
1. DNS      dig app.team1.test  &&  dig @<MAC1_IP> app.team1.test
              no answer        -> DNS layer: server down? client resolver
                                  settings? record deleted?
              WRONG answer     -> DNS layer: record tampered (demo #2)
              answer OK        -> continue (remember: the answer may lie)
2. IP       ping <the IP DNS gave you>
              unreachable      -> network layer (Wi-Fi/subnet/isolation)
3. TCP      nc -z -v -w2 <ip> 443   (or curl -v, watch where it dies)
              refused          -> nothing listening: edge down / wrong port
              timeout          -> firewall dropping (Extension C active?)
4. TLS      openssl s_client -connect <ip>:443 -servername app.team1.test -CAfile ca.crt
              verify != 0      -> cert swapped/expired/wrong name/untrusted CA
5. HTTP     curl -v https://app.team1.test/api/status
              502/504          -> edge healthy, BACKENDS broken (killed?
                                  firewalled from the edge? wrong upstream
                                  ports in nginx.conf?)
              200 wrong body   -> application layer
6. Backend  (FROM Mac 2, or isolation blocks you — say that!)
            curl http://<MAC3_IP>:3001/health
```

**Where classic injected faults land:**

| Injected fault | First broken layer | Signature |
|---|---|---|
| dnsmasq stopped / record removed | DNS | `could not resolve` / no answer |
| record repointed | DNS | resolves, then connect fails at the WRONG IP |
| client resolver changed | DNS (client-side) | `dig @Mac1` fine, plain `dig` fails |
| nginx stopped | TCP | connection **refused** on 443 |
| nginx moved to 8443 only | TCP | 443 refused, 8443 works |
| cert replaced/expired | TLS | handshake or verify failure only |
| one backend killed | *(none!)* | LB absorbs it — SAY THIS OUT LOUD |
| both backends killed | HTTP | 502 at edge, `/edge-status` still 200 |
| pf isolation ON + you probe from client | *(expected)* | backend ports time out; edge works |

Narration template (marks are awarded for this): *"Resolution works and
returns X, so the DNS layer is healthy. TCP to X:443 completes, so
transport is fine. TLS verifies, so session security is fine. The edge
returns 502, which means the edge itself is up but no backend answered —
the fault is below the edge. Probing backends from Mac 2 shows A refusing
connections: Backend A's process is down. Restarting it restores
round-robin within fail_timeout."*

---

## Phase 2 checklist (demo step 9 + Review 2)

- [ ] Backup DNS running; clients list both; failover demonstrated (A)
- [ ] TTL countdown + record change + flush demonstrated (B)
- [ ] pf isolation applied on Mac 3/4, proven, **rolled back** (C)
- [ ] Backend kill/recovery absorbed transparently; SPOF named (D)
- [ ] Standby edge + DNS cutover with TTL effects shown (E)
- [ ] `diagnose.sh` walk rehearsed by EVERY team member (F)
- [ ] Phase 2 report drafted from `docs/PHASE2_REPORT_TEMPLATE.md`
- [ ] New evidence saved under `evidence/phase2/`
