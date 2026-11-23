# Evidence Index — Complete Project Deliverable Map

> **30-Second Rule:** Evaluator asks for any proof -> find the corresponding row and file below immediately.

## Phase 1 Evidence (Tasks A–G)

| Protocol / Layer | Evidence File | Contents / What it Proves |
|---|---|---|
| **DNS (Task B, G)** | [`evidence/dns/01-dig-app-20261123-235554.txt`](file:///Users/rudra/Desktop/cn-project/evidence/dns/01-dig-app-20261123-235554.txt) | `dig @10.7.11.30 app.team1.test` returning Edge IP `10.7.31.44` with TTL 30s |
| **DNS (Task B, G)** | [`evidence/dns/02-dig-api-and-nslookup-20261123-235554.txt`](file:///Users/rudra/Desktop/cn-project/evidence/dns/02-dig-api-and-nslookup-20261123-235554.txt) | `api.team1.test` resolution + `nslookup` cross-validation |
| **TCP / Ports (Task A, G)** | [`evidence/tcp/04-port-scan-20261123-235554.txt`](file:///Users/rudra/Desktop/cn-project/evidence/tcp/04-port-scan-20261123-235554.txt) | Edge service ports (443, 8443, 80) OPEN; backend ports probed |
| **Packet Capture (Task G)** | [`evidence/tcp/11-full-flow-20260920-104548.pcap`](file:///Users/rudra/Desktop/cn-project/evidence/tcp/11-full-flow-20260920-104548.pcap) | Complete Wireshark `.pcap` capture of DNS, TCP 3-way handshake, TLS, and HTTP |
| **TLS / SSL (Task E, G)** | [`evidence/tls/05-openssl-s-client-20261123-235554.txt`](file:///Users/rudra/Desktop/cn-project/evidence/tls/05-openssl-s-client-20261123-235554.txt) | `openssl s_client` showing `Verify return code: 0 (ok)` and certificate chain |
| **TLS / SSL (Task E, G)** | [`evidence/tls/06-curl-v-tls-20261123-235554.txt`](file:///Users/rudra/Desktop/cn-project/evidence/tls/06-curl-v-tls-20261123-235554.txt) | `curl -v` negotiation showing TLS 1.3, ALPN, and encrypted payload |
| **HTTP (Task C, D)** | [`evidence/http/07-responses-and-headers-20261123-235554.txt`](file:///Users/rudra/Desktop/cn-project/evidence/http/07-responses-and-headers-20261123-235554.txt) | `GET /`, `GET /api/status`, and HTTP -> HTTPS 301 Redirect |
| **Load Balancing (Task D, G)** | [`evidence/load-balancing/08-xbackend-alternation-20261123-235554.txt`](file:///Users/rudra/Desktop/cn-project/evidence/load-balancing/08-xbackend-alternation-20261123-235554.txt) | 12 sequential requests proving round-robin alternation (`A, B, A, B...`) |
| **HTTP Caching (Task F)** | [`evidence/caching/09-cache-control-and-304-20261123-235554.txt`](file:///Users/rudra/Desktop/cn-project/evidence/caching/09-cache-control-and-304-20261123-235554.txt) | `Cache-Control: max-age=60`, `ETag`, and conditional `304 Not Modified` exchange |

---

## Phase 2 Evidence (Extensions A–F)

| Extension | Evidence File | Contents / What it Proves |
|---|---|---|
| **Extension A (Backup DNS)** | [`evidence/phase2/a-backup-dns-failover-20261123-235323.txt`](file:///Users/rudra/Desktop/cn-project/evidence/phase2/a-backup-dns-failover-20261123-235323.txt) | Dual resolver listing, primary killed, fallback to backup DNS resolver on Mac 3 |
| **Extension B (TTL & Expiry)** | [`evidence/phase2/b-ttl-record-change-20261123-235323.txt`](file:///Users/rudra/Desktop/cn-project/evidence/phase2/b-ttl-record-change-20261123-235323.txt) | 30s TTL visible, record changed, cache countdown, manual flush with `dscacheutil` |
| **Extension C (Service Isolation)** | [`evidence/phase2/c-isolation-prove-20261123-235323.txt`](file:///Users/rudra/Desktop/cn-project/evidence/phase2/c-isolation-prove-20261123-235323.txt) | `pf` firewall: direct client connection to 3001/3002 times out, while Edge succeeds |
| **Extension D (HA Failover)** | [`evidence/phase2/d-ha-failover-20261123-235323.txt`](file:///Users/rudra/Desktop/cn-project/evidence/phase2/d-ha-failover-20261123-235323.txt) | Backend A stopped -> 100% absorbed by Backend B with 200 OK -> alternation restored |
| **Extension E (Edge Cutover)** | [`evidence/phase2/e-edge-cutover-20261123-235323.txt`](file:///Users/rudra/Desktop/cn-project/evidence/phase2/e-edge-cutover-20261123-235323.txt) | Standby edge on Mac 3, DNS record flipped, `X-Edge-IP` transition observed |
| **Extension F (Diagnose Baseline)** | [`evidence/phase2/f-diagnose-run-20261123-235323.txt`](file:///Users/rudra/Desktop/cn-project/evidence/phase2/f-diagnose-run-20261123-235323.txt) | Clean 6-layer walk (DNS -> IP -> TCP -> TLS -> HTTP -> Backends: ALL PASS) |
