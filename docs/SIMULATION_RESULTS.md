# Simulation Results — End-to-End Verification Log

**Date:** 2026-09-20 · **Environment:** Debian 13 sandbox, single-machine
simulation (`practice/run-local.sh`): dnsmasq 2.91 (primary @127.0.0.1:53 +
backup @127.0.0.2:53), nginx 1.26.3 (edge :443/:8443/:80/:8080), Python 3.13
backends (:3001/:3002), OpenSSL 3 local CA. The sandbox's system resolver
was pointed at the simulated DNS and the team CA installed into the system
trust store — i.e., the sandbox acted as a *real client Mac* would.

Everything below was **executed**, not just configured. Sample artifacts
from this run live in `evidence/`.

## 1. Zero-flag client experience (the graded demo condition)

```
$ dig +short app.team1.test
127.0.0.1                                  # resolved by OUR dnsmasq
$ curl -s https://app.team1.test/api/status    # NO -k, NO --cacert, NO IP
{ "backend": "A", "status": "ok", ... }
$ curl -w '%{http_version} %{ssl_verify_result}' ...
HTTP version: 2 | status: 200 | TLS: 0     # HTTP/2 via ALPN, cert verified
```

## 2. Phase 1 gate — `scripts/verify.sh --local`: **ALL CHECKS PASSED**

| Check | Result |
|---|---|
| DNS app/api → edge IP, TTL 30 | PASS |
| TCP 443 / 8443 / 80 open | PASS |
| TLS chain vs local CA — `Verify return code: 0 (ok)`, TLSv1.3 TLS_AES_256_GCM_SHA384 | PASS |
| `GET /` 200 · `GET /api/status` 200 + `X-Backend` + backend field in JSON | PASS |
| `/edge-status` 200 (edge independent of backends) | PASS |
| `http://` → 301 → `https://` | PASS |
| Round-robin: 12 requests → **A=6, B=6, sequence A,B,A,B,A,B,A,B,A,B,A,B** | PASS |
| `Cache-Control: public, max-age=60` + `ETag` + conditional request → **304** | PASS |
| Backup DNS answers identically (Extension A ready) | PASS |

> Finding from this run (fixed): the first 304 attempt failed because the
> cached body included the backend's name → A and B produced different
> ETags → revalidation through round-robin missed. Fix: byte-identical
> cached representation across backends (identity lives in the `X-Backend`
> header, not the validator). Real origin fleets face exactly this issue.

## 3. The five required failure demonstrations — `scripts/failures.sh --local a`

| # | Scenario | Observed (actual output) |
|---|---|---|
| 1 | Wrong DNS server | dig to dead resolver times out; ping + TCP :443 to the edge still fine; correct resolver answers |
| 2 | Record → wrong IP (10.255.255.1) | resolution "succeeds" with the wrong address; curl cannot connect; record restored, service resumes |
| 3 | Backend A stopped | 8/8 requests served by B, zero user-visible errors; after restart + fail_timeout (10 s), round-robin resumes B,A,B,A… |
| 4 | Both backends stopped | `GET /api/status` → **502**; `GET /edge-status` → **200** (DNS+TCP+TLS+edge all healthy); restart → service restored |
| 5 | Wrong port (9443) | instant **connection refused** (RST — nothing bound) while :443 stays open |

## 4. Phase 2 extensions (automated parts)

**A — backup DNS failover:** primary dnsmasq killed → system resolver
(listing both) fell back to 127.0.0.2 → name still resolved → `curl
/api/status` still 200 (`X-Backend: B`). Primary restarted cleanly.

**B — TTL + controlled record change:** TTL 30 visible in answers; record
flipped to blackhole 10.255.255.1 → server instantly answers the new
record, clients re-resolving now fail to connect (DNS worked, destination
wrong); record restored. (Client-side cache countdown + flush demo is
macOS-specific: `dscacheutil` — documented in SETUP_GUIDE_PHASE2.md.)

**D — HA failover with edge-side proof:** Backend A killed → 8/8 served by
B; nginx error log captured the exact mechanism:

```
[error] connect() failed (111: Connection refused) while connecting to
        upstream ... request: "GET /api/status HTTP/2.0", upstream: "http://127.0.0.1:3001/..."
[warn]  upstream server temporarily disabled    <- max_fails=2 reached, parked 10 s
```

Backend A restarted → alternation resumed with **no config change, no
nginx restart**. (C — pf rules and E — edge cutover are macOS/multi-machine
demos: configs generated + validated here, procedures documented.)

## 5. Layer-by-layer diagnosis — `scripts/diagnose.sh --local`

```
1/6 DNS      PASS  @127.0.0.1 answered: app.team1.test -> 127.0.0.1
2/6 IP       PASS  (ICMP filtered in sandbox; reachability proven via TCP)
3/6 TCP      PASS  three-way handshake to 127.0.0.1:443 completes
4/6 TLS      PASS  chain verifies against team CA
5/6 HTTP     PASS  GET /api/status -> 200 — the full stack works
6/6 Backend  PASS  A :3001/health 200 · B :3002/health 200
VERDICT: every layer healthy — system fully operational.
```

## 6. Packet-level proof (Task G) — `evidence/tcp/11-full-flow-*.pcap`

One capture, one request's whole journey (72 packets):

```
DNS   127.0.0.1.51289 > 127.0.0.1.53:  A? app.team1.test        (query id 34709)
DNS   127.0.0.1.53 > 127.0.0.1.51289:  34709* A 127.0.0.1       (answer, same id)
TCP   .57442 > .443: Flags [S],  seq 2437834754                  (SYN, ephemeral→443)
TCP   .443   > .57442: Flags [S.], ack 2437834755                (SYN-ACK)
TCP   .57442 > .443: Flags [.], ack 1                            (ACK — handshake done)
TLS   .57442 > .443: [P.] seq 1:1575   (ClientHello)             → encrypted from here
...   application data only (payload unreadable — TLS works)
TCP   .53406 > .3002: Flags [S] ...    (SECOND handshake: edge→backend hop!)
HTTP  .53406 > .3002: [P.] length 183  (plain HTTP GET — visible because
                                        TLS terminates at the edge)
```

The same file shows seq/ack progression (reliable transfer), window sizes
(flow control), and both socket pairs of a proxied request.

## 7. Issues found & fixed during verification (engineering honesty)

1. dnsmasq wildcard-socket collision between primary/backup instances →
   added `bind-dynamic` (binds only listed addresses).
2. `kill -0` / `lsof` can't see root-owned processes from a normal user →
   stop/port-check logic now uses sudo probes.
3. Backend-specific ETags broke 304s behind round-robin → uniform cached
   representation (see §2 note).
4. Local-mode "bogus record" pointed at 127.0.0.9, which still reached the
   wildcard-bound nginx → changed to 10.255.255.1 (true blackhole).
5. `dig +short` prints ";; no servers could be reached" on stdout →
   diagnose.sh now filters for valid IPv4 only.
6. ICMP filtered in sandbox → diagnose.sh cross-checks TCP before blaming
   the IP layer (also correct for hardened hosts).
