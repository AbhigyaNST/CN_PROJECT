# Phase 2 Final Report — Template

*(Deliverable spec: "What changed from Phase 1 · resilience tests and
results · troubleshooting findings · learning summary (one paragraph per
extension)." Copy this file, replace `[...]`, attach evidence filenames
from `evidence/`. Aim for 6–10 pages with figures.)*

---

**Team:** [names + roll numbers]  **Team domain:** app.[teamX].test
**Machines:** [4 × macOS, roles]  **Date:** [review date]

## 1. System recap (½ page)

One paragraph + the topology diagram (`docs/topology.svg`): private DNS
(dnsmasq, Mac 1) → HTTPS edge (nginx, TLS termination + round-robin LB,
Mac 2) → two Python REST backends (Mac 3/4, ports 3001/3002). Phase 1
gate: client resolved `app.[teamX].test`, completed TCP+TLS, and received
alternating `X-Backend: A/B` responses. Evidence: `evidence/INDEX.md`.

## 2. What changed from Phase 1

| Component | Phase 1 state | Phase 2 change | Why |
|---|---|---|---|
| DNS | single resolver (Mac 1) | second resolver on Mac [3], clients list both | remove DNS SPOF (Ext A) |
| DNS records | static | TTL=30 + rehearsed controlled record change | bounded propagation, migration skill (Ext B) |
| Backend ports | open to whole LAN | pf: only edge IP may connect to 3001/3002 | service isolation / defense in depth (Ext C) |
| Load balancer | round-robin (failover already configured) | failover *demonstrated + measured*; recovery window documented | HA behaviour proof (Ext D) |
| Edge | single nginx (SPOF) | standby nginx on Mac [3] + DNS-based cutover procedure | edge resilience without hardware (Ext E) |
| Operations | ad-hoc debugging | `scripts/diagnose.sh` layer-walk + written methodology | systematic troubleshooting (Ext F) |

## 3. Resilience tests and results

*(For each: procedure, observed output, verdict, evidence file. Numbers
beat adjectives — measure the failover window!)*

### 3.1 Backup DNS failover (Extension A)
Procedure: [dig both resolvers → stop primary → time first successful
resolution via backup → curl service]. Result: resolution continued after
[~X s] resolver timeout; application never interrupted. Evidence:
`evidence/phase2/a-backup-dns-failover.txt`.

### 3.2 TTL behaviour + record change (Extension B)
Observed: client cached old answer for [≤30 s] after record flip; manual
flush (`dscacheutil -flushcache; killall -HUP mDNSResponder`) applied the
new answer immediately. Production link: [lower TTL before cutover; drain
window = TTL]. Evidence: `b-ttl-record-change.txt`.

### 3.3 Service isolation (Extension C)
From edge: backend `/health` → 200. From clients after pf apply: connection
**timed out** (drop ⇒ silence, not refused ⇒ RST — the diagnostic
difference). Service through the edge unaffected. Rollback verified:
`firewall-rollback.sh` restored `/etc/pf.conf` and prior pf state.
Evidence: `c-isolation-prove.txt` + rollback output.

### 3.4 HA failover at the LB (Extension D)
Backend A stopped → [N/N] requests served by B (0 user-visible errors;
worst-case added latency [X ms] on the two sacrificed attempts before
parking, per `max_fails=2`). nginx error log lines: [paste]. A restarted →
round-robin resumed after [≤10 s] (`fail_timeout`). Evidence:
`d-ha-failover.txt`, `nginx-error.log` excerpt.

### 3.5 Edge migration / DNS cutover (Extension E)
Standby nginx on Mac [3] serving same domain (wildcard SAN cert validates).
Record flipped edge→standby: cached clients kept hitting old edge
(`X-Edge-IP: [MAC2_IP]`) for [≤TTL] s; fresh lookups landed on standby
(`X-Edge-IP: [MAC3_IP]`); flush forced immediate. With old edge fully
stopped, service continued. Rollback: [record restored]. Evidence:
`e-edge-cutover.txt`.

### 3.6 Remaining single point of failure (required analysis)
[The edge during the TTL window of a real Mac-2 death without pre-started
standby; mitigation options and their trade-offs — DNS cutover (minutes,
no hardware), VRRP VIP (seconds, Linux-native), managed cloud LB (none —
multi-AZ by construction). State what YOUR system does today.]

## 4. Troubleshooting findings (Extension F)

* Method used during the injected-fault drill: [layer walk — DNS → IP →
  TCP → TLS → HTTP → backend; tool per layer; what each outcome implies].
* The injected fault was: [describe]. First broken layer: [X]. Signature
  observed: [exact error/output]. Root cause: [config line]. Fix:
  [command]. Time to isolate: [mm:ss].
* One-paragraph reflection: which layer was hardest to rule out and why;
  what evidence would have shortened the diagnosis.

## 5. Learning summary — one paragraph per extension

**A (backup DNS):** [what you now understand about resolver behaviour,
timeouts, caching masking failures, why DNS is always ≥2 servers…]

**B (TTL):** [TTL as a contract; staleness vs propagation; cutover
procedure in production; flush semantics…]

**C (isolation):** [stateful firewalls; drop vs return fingerprints;
security groups analogy; rollback discipline…]

**D (HA failover):** [passive vs active health checks; retry semantics of
proxy_next_upstream; instance-vs-service availability; measured recovery…]

**E (edge migration):** [DNS as a traffic-control plane; wildcard SANs and
SNI; TTL-bounded migration; observability via X-Edge-IP…]

**F (diagnosis):** [systematic layer isolation beats guessing; narrating
evidence; the five failure demos as calibration…]

## 6. Evidence appendix

Table mapping every claim above to files in `evidence/` (auto-index:
`evidence/INDEX.md`). Include: Wireshark exports (DNS/TCP/TLS), pcaps,
curl transcripts, nginx access/error log excerpts, dnsmasq query log,
failure-demo transcripts, pf apply/rollback outputs.

## 7. Honest limitations (evaluators reward this)

[Local CA has no revocation mechanism; passive health checks sacrifice up
to max_fails real requests per outage; DNS cutover is manual; edge↔backend
traffic unencrypted (mitigated by isolation); DHCP IP changes require
re-configure; single Wi-Fi AP = shared failure domain for the whole lab.]
