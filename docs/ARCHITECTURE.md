# Architecture Document — Private Network Service Platform

**Deliverable:** Architecture Document (Phase 1, updated for Phase 2)
**Team domain:** `app.team1.test` / `api.team1.test` *(replace `team1` with your team in `config.env`)*

---

## 1. Network topology

Diagram file: [`topology.svg`](topology.svg)

```
                          ┌───────────────────────────────────────────────┐
                          │        Private Wi-Fi / LAN (one subnet)       │
                          └───────────────────────────────────────────────┘
                             │            │             │            │
      ┌──────────────┐       │   ┌────────┴───────┐     │   ┌────────┴────────┐
      │ Test client  │◀──────┘   │ Mac 1          │     │   │ Mac 2           │
      │ (Mac 1 / 4)  │  ① DNS    │ PRIVATE DNS    │     │   │ THE EDGE        │
      │ browser/curl │  UDP :53  │ dnsmasq        │     │   │ nginx           │
      │  dig         │           │ zone team1.test│     │   │ TLS :443/:8443  │
      └──────┬───────┘           │ app/api → Mac2 │     │   │ HTTP→HTTPS :80  │
             │                   └────────────────┘     │   │ round-robin LB  │
             │  ② TCP 3-way handshake + TLS handshake   └─────────┬─────────┘
             │     + HTTPS request          TCP :443              │
             └────────────────────────────────────────────────────┘
                                                                   │
                             ③ proxied PLAIN HTTP (private LAN)    │
                                       ┌───────────────────────────┴──────────┐
                                       │                                      │
                            ┌──────────┴──────────┐            ┌──────────────┴────────┐
                            │ Mac 3               │            │ Mac 4                 │
                            │ BACKEND A           │            │ BACKEND B             │
                            │ python3 :3001       │            │ python3 :3002         │
                            │ X-Backend: A        │            │ X-Backend: B          │
                            │ Phase 2: backup DNS │            │ + test client         │
                            │ + standby edge      │            │                       │
                            └─────────────────────┘            └───────────────────────┘
```

## 2. Machine roles, IPs and services

*(fill in your real IPs — `scripts/configure.sh` stamps these everywhere)*

| Machine | IP (example) | Services (port/proto) | Role | Cloud equivalent |
|---|---|---|---|---|
| Mac 1 | 192.168.1.11 | dnsmasq — **53/UDP** (+53/TCP fallback) | Private DNS server + test client | **AWS Route 53** private hosted zone |
| Mac 2 | 192.168.1.12 | nginx — **443/TCP + 8443/TCP** (TLS), 80/8080 (redirect) | Edge: reverse proxy, TLS termination, round-robin load balancer | **Cloud LB / CDN edge** (AWS ALB, GCP LB, Cloudflare) |
| Mac 3 | 192.168.1.13 | backend.py A — **3001/TCP**; Phase 2: backup dnsmasq 53/UDP, standby nginx | Application server instance A (+ resilience roles) | **EC2/GCE instance** in a private subnet |
| Mac 4 | 192.168.1.14 | backend.py B — **3002/TCP** | Application server instance B + test client | second instance, other "AZ" |

**Port inventory (well-known vs ephemeral):** DNS 53/UDP (well-known) ·
HTTPS 443/TCP (well-known; 8443 permitted substitute) · backends
3001/3002 TCP (fixed, registered ports — deliberately *not* well-known so
they can run without root on macOS) · the **client side of every TCP
connection uses an ephemeral port** (macOS: 49152–65535), which together
with (client IP, server IP, server port) forms the connection's 4-tuple.

## 3. The journey of one request (layer by layer)

For `curl https://app.team1.test/api/status` on a client Mac:

| # | What happens | Protocol / Layer (OSI → TCP/IP) | Where |
|---|---|---|---|
| 1 | Client checks its DNS cache (mDNSResponder); on miss sends **A? app.team1.test** | DNS — Application → Application | client → Mac 1, **UDP 53** |
| 2 | dnsmasq answers from the local zone: **A = 192.168.1.12, TTL 30** (never forwarded upstream: `local=/team1.test/`) | DNS | Mac 1 → client |
| 3 | **TCP three-way handshake** SYN → SYN-ACK → ACK; client ephemeral port ↔ server 443 | TCP — Transport → Transport | client ↔ Mac 2 |
| 4 | **TLS handshake**: ClientHello (SNI=app.team1.test) → ServerHello → Certificate (edge cert + local CA) → key exchange → Finished; client validates chain against the trusted CA in its keychain | TLS — Session/Presentation → (rides on Transport) | client ↔ Mac 2 |
| 5 | Encrypted **HTTP request** `GET /api/status HTTP/1.1, Host: app.team1.test` inside the TLS tunnel | HTTP — Application → Application | client → Mac 2 |
| 6 | nginx picks the next upstream (**round-robin**: A, B, A, B…), opens a *plain HTTP* connection to it (new TCP handshake edge↔backend), forwards with `X-Forwarded-For` | HTTP + TCP | Mac 2 → Mac 3 **or** Mac 4 |
| 7 | Backend replies `200`, JSON `{"backend":"A",…}`, header **`X-Backend: A`**; nginx relays it back through the TLS tunnel; access log records `upstream=192.168.1.13:3001` | HTTP | Mac 3/4 → Mac 2 → client |
| 8 | Cached resources: `/api/cached` returns `Cache-Control: max-age=60` + `ETag`; later conditional request (`If-None-Match`) yields **304 Not Modified** — headers only | HTTP caching | backend via edge |

At every hop below the application layer, IP (Network → Internet) addresses
packets across the LAN and Ethernet/Wi-Fi (Link → Link) frames carry them —
in Wireshark you see all of it stacked in one pane.

## 4. Design decisions (defend these in the viva)

1. **`.test` namespace** — reserved for documentation/testing (RFC 6761);
   guaranteed never to collide with real DNS. `.local` is reserved by mDNS
   (Bonjour), which macOS queries *before* unicast DNS — using it breaks
   resolution nondeterministically.
2. **dnsmasq** — tiny, single-binary DNS+DHCP daemon; authoritative for our
   zone via `address=` records, forwarding everything else to the campus
   resolver so clients keep internet access. One config file, query logging
   built in (`log-queries`) = free evidence.
3. **TLS terminates only at the edge** — one certificate, one trust point;
   edge→backend hops are plain HTTP over a private, firewall-isolated LAN
   (Extension C). Same as cloud LBs terminating TLS in front of private
   subnets. Con: traffic behind the edge is readable on the LAN — which is
   exactly why isolation exists (honest trade-off to state out loud).
4. **Local CA instead of bare self-signed cert** — trust once per client,
   works for any number of names (`*.team1.test` wildcard SAN covers the
   Phase 2 standby edge), and mirrors real PKI: CA signs → server presents
   chain → client validates. Server cert capped at 825 days (Apple's max).
5. **Round-robin + passive health checks** — nginx default scheduling
   (per-request rotation across the upstream block); `max_fails=2
   fail_timeout=10s` parks a failing backend; `proxy_next_upstream` retries
   failed requests on the next one, so a single backend death is invisible
   to clients. Cloud analogue: ALB target groups with health checks.
6. **Backends bind 0.0.0.0 on fixed ports 3001/3002** — LAN-reachable (a
   127.0.0.1 bind would be invisible to the edge); fixed registered ports
   avoid root privileges and make firewall rules trivial.
7. **Both 443 and 8443 (80 and 8080) served** — the brief permits the
   substitution with no deduction; listening on both removes demo-day risk.
8. **X-Backend / X-Edge / X-Edge-IP headers** — observability at the
   protocol level: every response tells you *which* backend and *which*
   edge served it, which is how load balancing and the DNS cutover are
   proven without reading logs mid-demo.

## 5. Phase 2 resilience additions

| Extension | Change | Effect |
|---|---|---|
| A — Backup DNS | second dnsmasq (same zone) on Mac 3; clients list both resolvers | primary DNS death → resolution continues via backup in ~seconds |
| B — TTL control | `local-ttl=30` | record changes propagate within 30 s; manual flush (`dscacheutil`) forces instantly |
| C — Service isolation | pf on Mac 3/4: only Mac 2 may reach 3001/3002 | backends invisible to clients; attack/accident surface reduced to the edge |
| D — HA failover | `max_fails` + `proxy_next_upstream` | backend failure absorbed; service continues on the healthy one |
| E — Edge migration | standby nginx on Mac 3 + DNS record cutover | edge SPOF mitigated without new hardware; bounded by TTL |

### Single point of failure analysis (asked explicitly in the brief)

After Phase 2 the remaining SPOF is **the edge nginx on Mac 2**: DNS still
resolves if Mac 2 dies, but every TCP connection is refused. Mitigations:
(i) our DNS-cutover standby (Extension E — minutes of exposure, bounded by
TTL, no hardware); (ii) a floating virtual IP with VRRP (keepalived on
Linux; not native on macOS); (iii) the cloud answer — managed load
balancers are multi-AZ redundant by construction, so customers never own
this problem. DNS-based failover's recovery window = TTL, which is why
production systems lower TTL before migrations.

## 6. What maps to what (course concepts → components)

| Course topic | Concrete artifact in this project |
|---|---|
| DNS / Route 53 | dnsmasq zone `team1.test`, TTL=30, backup resolver, `dig` evidence |
| TCP, ports, handshake | ephemeral↔well-known port pairs, SYN/SYN-ACK/ACK in captures, backend logs print full socket pairs |
| Reliable transfer / flow control | seq/ack numbers visible in Wireshark; retransmission-free LAN baseline to contrast |
| TLS / HTTPS | local CA, SAN cert, handshake packets, encrypted `Application Data` |
| HTTP/1.1, HTTP/2, REST | JSON REST backends; nginx `http2 on` (curl `--http2`, devtools "Protocol" column); HTTP/3 = explanation only (QUIC/UDP, 0-RTT, no head-of-line blocking) |
| Caching / CDN | `Cache-Control`, `ETag`, `If-None-Match` → 304 |
| Cloud load balancing | nginx upstream = ALB analogue; X-Backend = target identity |
| Topologies / devices | star topology around the Wi-Fi AP (switch role), all hosts one broadcast domain |
| Email protocols | explanation-only per the brief (SMTP/IMAP/POP3, ports 25/587/993/110, MX records — none run here) |
