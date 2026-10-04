# Viva Preparation Bank — Phase 1 + Phase 2

Every team member must be able to explain **any** component (brief §2).
Answers below are calibrated to what evaluators actually ask. Read them,
then close the file and explain each one out loud in your own words.

---

## DNS (Task B, Extension A/B)

**Q: What exactly happens when you type `https://app.team1.test` and press Enter?**
Browser asks the OS resolver → resolver checks its cache → on miss, sends a
DNS A query (UDP, port 53) to the configured nameserver (our dnsmasq on
Mac 1) → dnsmasq matches the local zone (`local=/team1.test/`) and replies
from `address=` records: A = Mac 2's IP, TTL 30 → browser opens a TCP
connection to that IP:443 → TLS handshake → HTTP request. DNS gave us a
*name→address mapping*; it played no part in the connection itself.

**Q: Recursive vs iterative resolution?**
Our clients ask dnsmasq recursively ("you get me the final answer").
dnsmasq for our zone is authoritative (answers from config, no iteration
needed); for other names it forwards (itself acting as a recursive
resolver toward the campus DNS, which iterates: root → .TLD → authoritative).
`.test` never leaves our server — it's reserved (RFC 6761) and `local=`
stops forwarding.

**Q: Why UDP for DNS? When TCP?**
Queries are tiny; UDP avoids handshake overhead — one packet each way.
TCP/53 is used for zone transfers and answers >512 bytes (EDNS0 raises the
UDP budget; resolvers fall back to TCP on truncation — the TC bit).
dnsmasq listens on both.

**Q: What is TTL and why did we pick 30 s?**
TTL tells caches how long an answer stays valid — the staleness/propagation
trade-off. 30 s makes Extension B (change record → watch cached answer →
expiry → flush) demonstrable in half a minute. Production: high TTL for
stable records (less load), lowered *before* migrations to shrink the
cutover window.

**Q: Why `.test` and not `.local`?**
`.local` is reserved for mDNS/Bonjour; macOS intercepts `.local` queries
into multicast before unicast DNS — our records would be flaky or ignored.
`.test` is reserved for documentation/testing and can never collide with
the real DNS hierarchy.

**Q: The primary DNS dies. What do users experience (Phase 2)?**
Clients listing both resolvers: the first query after failure waits out a
resolver timeout (~seconds) then the backup answers; already-cached answers
keep working for their TTL. Service itself (already-resolved connections)
never notices. DNS failure ≠ app failure: with DNS dead, new connections
can't *start* (`could not resolve host`); with the app dead, resolution
succeeds and you get refused/502 at later layers.

**Q: Where do email protocols fit (explanation-only per brief)?**
SMTP (25/587 submission), IMAP (993), POP3 (995) are application-layer
protocols like our HTTP; DNS serves them via MX records (mail routing =
another directory use of DNS). None run in our system.

## TCP / Transport (Tasks A, G; failure demos)

**Q: Walk the three-way handshake in YOUR capture.**
Client sends SYN (seq=x, ephemeral port 49152+ → server 443); Mac 2 replies
SYN-ACK (seq=y, ack=x+1); client ACKs (ack=y+1). Only then does any
application byte flow — visible in Wireshark as `tcp.len==0` on all three
segments. Both sides choose independent initial sequence numbers; SYN
consumes one sequence number.

**Q: What identifies a TCP connection?**
The 4-tuple: (client IP, client port, server IP, server port). That's why
failure demo #5 works: same IP, wrong port = a different (nonexistent)
socket → kernel answers RST → "connection refused". And why one client can
hold many connections to one server: ephemeral ports differ.

**Q: How does TCP provide reliability? Flow control?**
Sequence numbers + cumulative ACKs + retransmission on timeout/dup-ACKs
give ordered, lossless delivery; checksums catch corruption. Flow control:
receiver advertises a window (`rwnd`) in every ACK; sender never has more
than that in flight — receiver-driven backpressure. (Contrast congestion
control: network-driven — slow start, cwnd. On our LAN you'll see big
windows and zero retransmits — say why: no loss, short RTT.)

**Q: Ephemeral vs well-known ports in this project?**
Well-known/registered server side: 53 DNS, 443/8443 HTTPS edge, 3001/3002
backends. Client side: OS-assigned ephemeral (macOS 49152–65535). Backend
logs print the pair per request; nginx's access log prints
`client=ip:port -> upstream=ip:port` — two socket pairs per proxied request
(client↔edge, edge↔backend): the edge is a full TCP endpoint on BOTH sides
(that's what "proxy" means at transport level).

**Q: Why could a timeout vs refused distinction diagnose a firewall?**
Refused = host's stack actively answered RST (reachable, nothing listening).
Timeout = silence — packets dropped before any stack replies (pf `block drop`,
cloud SGs). Different layers of "no".

## TLS / HTTPS (Task E)

**Q: TLS handshake steps, precisely.**
ClientHello (supported versions, cipher suites, client random, **SNI =
app.team1.test**, ALPN h2/http1.1) → ServerHello (chosen version/cipher,
server random) → Certificate (edge cert + our CA) → key exchange (ECDHE
shares → both derive identical session keys; in TLS 1.3 the server's
Certificate/hello are already encrypted) → Finished messages verify the
handshake wasn't tampered → symmetric encryption for all application data.

**Q: Why both asymmetric and symmetric crypto?**
Asymmetric (RSA/ECDHE) is expensive but solves key agreement over an open
network and authentication (certificate signatures). Symmetric (AES-GCM) is
fast for bulk data. TLS uses asymmetric once — to establish/authenticate —
then symmetric for the session. Forward secrecy comes from *ephemeral* DH:
session keys don't depend on the server's long-term key.

**Q: What does the client actually verify about the certificate?**
(1) Chain: edge cert signed by a CA in the trust store (our `ca.crt` in the
System keychain) — cryptographic signature check; (2) Name: SAN list
matches the hostname from the URL/SNI (CN is ignored by modern clients);
(3) Validity window: notBefore/notAfter (Apple caps server certs at 825
days); (4) Purpose: extendedKeyUsage=serverAuth; (5) Revocation in real
PKI (OCSP/CRL — absent in our local CA, be honest about that).

**Q: Why is HTTP invisible in your Wireshark capture?**
After the handshake, records are AEAD-encrypted; Wireshark shows TLS
"Application Data" with opaque bytes. To *prove* the HTTP layer exists, we
show it (a) via curl -v/browser (endpoints), and (b) in a Mac 2 capture of
edge↔backend hops, which are plain HTTP by design (TLS terminates at the edge).

**Q: Why terminate TLS only at the edge?**
One cert + one trust point, backends stay dumb HTTP servers (simple, fast,
easy to scale) — standard cloud pattern (ALB/CDN terminates, private
subnet plaintext). Trade-off: intra-LAN traffic is readable — mitigated by
Extension C isolation; cloud alternative when compliance demands: re-encrypt
edge→backend (end-to-end TLS).

**Q: SNI? ALPN?**
SNI: hostname in ClientHello (cleartext) so one IP:443 can serve many certs
— virtual hosting for TLS; our nginx matches `server_name`. ALPN: inside
the handshake, negotiates the application protocol over the same connection
— that's how HTTP/2 (`h2`) gets selected without extra round trips.

## HTTP / REST / Caching (Tasks C, D, F)

**Q: HTTP/1.1 vs HTTP/2 vs HTTP/3 (explanation-only)?**
1.1: text-based, one request/response at a time per connection (pipelining
effectively unused), keep-alive reuse. 2: binary framing, multiplexes many
streams over ONE TCP connection (fixes application-level HOL), HPACK header
compression, server push (deprecated in practice). Our nginx has `http2 on`
— show `curl --http2 -vI` negotiating `h2` via ALPN, or devtools' Protocol
column. 3: same semantics over **QUIC (UDP)** — encryption includes the
transport handshake (0-RTT resumption), per-stream delivery kills TCP-level
head-of-line blocking, connection IDs survive network changes (Wi-Fi→LTE).

**Q: Reverse vs forward proxy?**
Reverse proxy (nginx here): sits in front of *servers*; clients don't know
the backends; goals = load distribution, TLS termination, caching,
isolation. Forward proxy: sits in front of *clients* (corporate egress,
anonymity). Same machinery, opposite standpoint.

**Q: Why is `X-Backend` there? Is it standard?**
Custom debug header set by each backend and passed through by nginx —
makes LB decisions observable per response without reading logs. Real
clouds do similar (`X-Amz-Cf-Id`, `X-Served-By`). `X-` prefix =
unregistered/experimental header convention.

**Q: 502 vs 504 vs 301 vs 304 — in OUR system.**
502: edge reached, no valid upstream response (both backends dead/refused).
504: upstream accepted but didn't answer within `proxy_read_timeout`
(our `/slow?seconds=20` provokes it → then `proxy_next_upstream` retries
the other backend!). 301: our :80/:8080 → https redirect (permanent;
browsers cache it — careful during demos). 304: conditional GET/HEAD,
validator matched, headers-only response, zero body bytes.

**Q: Cache-Control vs ETag — how do they cooperate?**
`max-age=60` = freshness lifetime: within it, caches serve without asking
(fresh hit). After it, the entry is *stale* → revalidate with
`If-None-Match: <etag>` (and/or `If-Modified-Since`); server replies 304
(unchanged — reuse body, refresh timer) or 200 (new content). ETag = strong
validator (ours: hash of the exact bytes); Last-Modified = weak, 1-second
granularity. CDNs are this machinery at planetary scale.

**Q: REST design of the backends?**
Resource-oriented URLs (`/api/status`, `/api/cached`), standard methods
(GET; HEAD supported), status codes as semantics, JSON representations,
stateless (every request self-contained — no sessions; that's also why
plain round-robin is safe: any backend can serve any request. With state,
you'd need `ip_hash`/sticky sessions — know this trade-off).

## Load balancing / Cloud mapping (Task D, Extension D/E)

**Q: Strategies and why round-robin?**
round-robin (default — even spread, zero state), `least_conn` (fewest
active connections — better with heterogeneous request costs), `ip_hash`
(session stickiness), weighted variants. Our requests are uniform +
stateless → round-robin is optimal and easiest to *demonstrate* (strict
alternation). Cloud mapping: nginx upstream ≈ ALB target group; our passive
`max_fails`/`fail_timeout` ≈ ALB active health checks (we ship `/health`
so an active prober could be added); X-Backend ≈ target ID; our DNS
cutover (Ext E) ≈ Route 53 failover records; CDNs ≈ caching layer we
demonstrate via headers (we don't run one — say so and explain what it
would add: geo-distributed cache hits, DDoS absorption, edge TLS).

**Q: What is still a single point of failure after Phase 2? How would you kill it?**
The edge (nginx on Mac 2) — DNS survives its death, connections don't.
Options: (1) DNS-based standby + cutover (Extension E — implemented;
recovery bounded by TTL, manual or scripted trigger); (2) floating VIP via
VRRP/keepalived — sub-second, automatic, but Linux-native (no clean macOS
story); (3) cloud: managed LBs are multi-AZ redundant by construction —
the SPOF simply isn't the customer's problem. Bonus honest note: with (1),
in-flight TLS sessions to the old edge die; clients reconnect (new
handshake) to the new edge — TLS session resumption makes that cheap.

**Q: Why do clients never need backend IPs?**
Indirection: DNS points at the edge, the edge's upstream config points at
backends. Backends can be replaced, moved, scaled, firewalled (Ext C
actually *forbids* clients knowing them usefully) without touching any
client. That layering (name → edge → pool) is the entire cloud LB model.

## Topology / OSI mapping (Tasks A, G)

**Q: Map every protocol in one request to OSI and TCP/IP layers.**
Ethernet/Wi-Fi 802.11 framing + ARP → Link/Network-Access; IP + ICMP(ping)
→ Network/Internet; TCP (and UDP for DNS) → Transport; TLS → Session/
Presentation (a shim *on top of* TCP, below HTTP — in TCP/IP terms it's
just part of the application stack); DNS, HTTP → Application. One Wireshark
frame shows them all stacked — point at the tree.

**Q: Devices and topology?**
Star topology centered on the Wi-Fi AP (which bridges frames like a
switch; one broadcast/collision domain, one subnet — no router hops between
our Macs; the router only matters as default gateway toward the internet).
Roles: Mac1 authoritative DNS; Mac2 L7 gateway (it's an L4 endpoint too —
two separate TCP connections per proxied request); Mac3/4 origin servers.

**Q: Subnetting/NAT (out of scope unless faculty added it)?**
All machines share one prefix (e.g. 192.168.1.0/24) — same subnet, direct
L2 delivery via ARP, no routing. NAT happens only at the router toward the
internet; our private platform never needs it. If asked: /24 = 254 usable
hosts; our services would map to a DMZ/private-subnet split in production.

## Failure-scenario "why" answers (§6.3) — one-liners you must nail

1. **Wrong DNS server:** lookup fails while ping works — DNS (app layer,
   directory) is independent of IP reachability; no address ⇒ no connection
   attempt at all.
2. **Wrong record IP:** DNS "succeeds" with a lie — DNS validates nothing
   about the *service*, only maps names; client faithfully connects to the
   wrong place (timeout/refused there).
3. **One backend down:** invisible to users — proxy_next_upstream retries
   + passive marking; availability = service-level, not instance-level.
4. **Both backends down:** 502 from a healthy edge — proves layering:
   DNS✓ TCP✓ TLS✓ edge✓ app✗; the 502 is the edge *reporting* the boundary.
5. **Wrong port:** refused instantly — port is part of the socket identity;
   host-up says nothing about service-up (4-tuple!).

## Phase 2 viva adds

**Q: pf `block drop` vs `block return`?** drop = silence (timeout at the
client, stealthier); return = polite RST/ICMP (fast failure, reveals the
host). We used drop; the client-timeout was our *evidence*.
**Q: Why is pf "quick" needed?** first matching rule with `quick` wins —
without it, LAST match wins; order semantics matter when an allow must
override a later deny.
**Q: Stateful inspection?** pf remembers the handshake of allowed flows;
return traffic needs no explicit rule. That's why we only wrote inbound rules.
**Q: Active vs passive health checks?** (see above — probe vs learn-from-traffic;
ALB probes `/health` every N s; we detect on real failures within max_fails.)
**Q: Could a stale cached DNS answer break the cutover (Ext E)?** Yes — by
design bounded: clients on the old answer keep hitting the old edge until
TTL expiry/flush. That's the migration window; that's why TTL gets lowered
first. Long-lived TCP/TLS sessions don't re-resolve at all until they reconnect.

## "Explain your own config" drills (do these with the actual files open)

1. Read `deploy/mac1/dnsmasq.conf` aloud line-by-line — what each directive does.
2. Same for `deploy/mac2/nginx.conf` — especially `upstream`, `proxy_pass`,
   `proxy_next_upstream`, `max_fails`, the `ssl_*` block, `http2 on`,
   the redirect server, `/edge-status`.
3. `backend.py`: routing, X-Backend injection, ETag/304 logic, 0.0.0.0 bind,
   threading model (ThreadingHTTPServer = one thread per connection).
4. The pf rules file: anchors preserved, quick semantics, drop vs return.
5. `certs/make-ca-and-cert.sh`: CA → CSR → sign with extensions → chain file;
   why SANs; why 825 days; what each openssl command produced.
