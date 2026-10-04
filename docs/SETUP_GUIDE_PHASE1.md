# Phase 1 Setup Guide — Build & Observe (Tasks A–G)

Work through the tasks **in order**. Each task ends with the verification
that the graders will ask for. Commands assume the repo lives at
`~/cn-project` on every Mac (any path works — scripts are location-aware).

> **Rehearse first:** everything below can be dry-run on ONE machine with
> `./practice/run-local.sh` before you touch the 4-Mac setup.

---

## Task A — Establish the private LAN

**Goal:** all four Macs on the same Wi-Fi/LAN, mutually reachable, with a
recorded inventory.

1. Connect all Macs to the **same** Wi-Fi (lab Wi-Fi / home router / one
   phone's hotspot). Avoid campus "client-isolation" networks — if `ping`
   between Macs fails while both have IPs, isolation is the usual suspect;
   use a hotspot instead.
2. On **each** Mac, record its inventory:

   ```bash
   ifconfig en0 | grep "inet "        # private IPv4 + netmask (en0 = Wi-Fi)
   route -n get default | grep gateway  # default gateway
   ifconfig en0 | grep ether          # MAC (link-layer) address
   networksetup -listallnetworkservices # exact service name to use later ("Wi-Fi")
   ```

   | Machine | IPv4 | Mask | Gateway | Interface | MAC |
   |---|---|---|---|---|---|
   | Mac 1 |  |  |  | en0 |  |
   | Mac 2 |  |  |  | en0 |  |
   | Mac 3 |  |  |  | en0 |  |
   | Mac 4 |  |  |  | en0 |  |

3. Enter the four IPs into `config.env`, then on one Mac:

   ```bash
   ./scripts/configure.sh
   ```

4. Ping **every pair** (from each Mac to the other three):

   ```bash
   ping -c 3 <other-mac-ip>
   ```

   Screenshot/record all of them — demo step 2.
5. Topology diagram: `docs/topology.svg` (already drawn; update the IPs in
   the doc when you present).

**Why it matters (viva):** all machines sit in one broadcast domain (star
topology around the AP, which acts as a switch). ARP resolves IP→MAC on the
link layer before any IP packet flows.

---

## Task B — Private DNS server (Mac 1)

**Goal:** `app.team1.test` and `api.team1.test` resolve to **Mac 2's IP**
from every client, using *your* server.

1. On Mac 1: `brew install dnsmasq` (Homebrew from https://brew.sh).
2. Deploy + start:

   ```bash
   ./scripts/mac1-dns.sh          # copies config, starts service, self-tests
   ```

   What it installs (also readable in `deploy/mac1/dnsmasq.conf`):
   * `listen-address=127.0.0.1,<MAC1_IP>` on port 53 — privileged port, so
     dnsmasq runs as root (`sudo brew services`).
   * `local=/team1.test/` — our zone is answered locally, **never**
     forwarded upstream.
   * `address=/app.team1.test/<MAC2_IP>` etc., `local-ttl=30`.
   * `log-queries` → every query logged to `/tmp/team1-run/dnsmasq-queries.log`
     — tail it during the demo to show the server *seeing* queries.
3. On **Mac 4** (and optionally Mac 2/3) point the system resolver at Mac 1:

   ```bash
   sudo networksetup -setdnsservers Wi-Fi <MAC1_IP>
   sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
   ```

   (GUI equivalent: System Settings → Network → Wi-Fi → Details → DNS.)
   Phase 2 adds the backup: `... Wi-Fi <MAC1_IP> <DNS_BACKUP_IP>`.
4. Verify **from a client Mac**:

   ```bash
   dig app.team1.test                       # via system resolver -> Mac 1
   dig @<MAC1_IP> app.team1.test +noall +answer
   nslookup app.team1.test <MAC1_IP>
   ```

   Expect `ANSWER SECTION: app.team1.test. 30 IN A <MAC2_IP>`.
5. From now on **always access the app by name**, never by IP (brief rule).

**DNS vs the connection (must be able to explain):** DNS is a *directory
lookup* — one UDP/53 round trip that returns an IP address. Nothing is
"connected" yet. The TCP+TLS+HTTP interaction with that IP happens after,
independently. Failure demos 1 & 2 prove the layers are separate.

---

## Task C — Two backend services (Mac 3 & Mac 4)

**Goal:** two tiny REST backends, LAN-reachable, self-identifying.

1. Copy the repo to Mac 3 and Mac 4 (same `config.env`).
2. Mac 3: `./scripts/mac3-backend-a.sh` → runs `backend.py --name A --port 3001`.
   Mac 4: `./scripts/mac4-backend-b.sh` → `--name B --port 3002`.
3. Keep these in **their own Terminal windows** — Ctrl+C there is how you
   perform the failure demos, and the request log (client socket pair per
   request) is live evidence.
4. Verify from Mac 2 (later: it's the only machine allowed to reach them
   in Phase 2):

   ```bash
   curl http://<MAC3_IP>:3001/api/status    # {"backend":"A","status":"ok",...}
   curl http://<MAC4_IP>:3002/api/status    # {"backend":"B",...}
   ```

Endpoint contract (brief): `GET /` (service-running JSON) · `GET /api/status`
(`backend` + `status`) · every response carries `X-Backend: A|B`. Extras we
added on purpose: `/api/cached` (Task F), `/health` (probes), `/slow?seconds=N`
(timeout/failover demos).

**Binding note:** backends bind `0.0.0.0` (all interfaces). A `127.0.0.1`
bind would only accept loopback traffic — invisible to every other machine.

---

## Task D — Edge reverse proxy + load balancer (Mac 2)

**Goal:** clients reach backends **only** through `https://app.team1.test`.

1. Mac 2: `brew install nginx`, then:

   ```bash
   ./scripts/mac2-edge.sh
   ```

   It finalizes `deploy/mac2/nginx.conf` (cert paths + mime.types for this
   machine) into `/tmp/team1-run/nginx.conf`, validates (`nginx -t`) and
   starts nginx on 443+8443 (sudo — privileged ports).
2. Verify round-robin from a client:

   ```bash
   for i in $(seq 10); do
     curl -sD - -o /dev/null https://app.team1.test/api/status | grep -i x-backend
   done
   ```

   Expect alternating `A, B, A, B…`. Also check the edge's own log on Mac 2:

   ```bash
   tail -f /tmp/team1-run/nginx-access.log
   # ... client=<ip>:<ephemeral_port> -> upstream=<MAC3_IP>:3001 status=200 ...
   ```

**Key config concepts (viva):**
* `upstream backends { server A; server B; }` — the pool. Round-robin is
  nginx's default policy (could switch to `least_conn`, `ip_hash` — know
  what each does and when it matters, e.g. sessions/sticky clients).
* `proxy_pass http://backends` — makes nginx a **reverse** proxy: clients
  see only the edge; backends see only the edge (via `X-Real-IP` /
  `X-Forwarded-For` headers we add).
* **Why clients never need backend IPs:** location transparency — backends
  can move, scale, die, or be replaced; only the edge's pool config
  changes. Exactly what AWS ALB target groups give you.

---

## Task E — HTTPS / TLS (Mac 2)

**Goal:** padlock-clean HTTPS with a certificate clients genuinely trust.

1. Build the local CA + edge cert (once, on any machine — Mac 2 natural):

   ```bash
   ./certs/make-ca-and-cert.sh
   ```

   Produces `ca.crt/ca.key` (CA) and `edge.crt/edge.key/edge-fullchain.crt`
   (server). SANs: `app/api/*.team1.test`, Mac 2 IP, 127.0.0.1. Server cert
   validity 825 days — Apple's maximum (longer = automatic distrust).
2. Trust the CA on **every client Mac** (Mac 1, Mac 4):

   ```bash
   sudo security add-trusted-cert -d -r trustRoot \
        -k /Library/Keychains/System.keychain \
        ~/cn-project/deploy/mac2/certs/ca.crt
   ```

   Safari/Chrome/curl use the System keychain. **Firefox needs a separate
   import** (certs/README.md).
3. Restart/reload nginx (`mac2-edge.sh` again, or `sudo nginx -c
   /tmp/team1-run/nginx.conf -s reload`).
4. Verify — **the demo forbids `-k`, so never use it**:

   ```bash
   curl -v https://app.team1.test/api/status   # "SSL certificate verify ok"
   open https://app.team1.test                 # browser padlock, no warnings
   ```

**Handshake you must narrate** (see certs/README.md for the full diagram):
ClientHello (versions, ciphers, **SNI=app.team1.test**, client random) →
ServerHello (choices, server random) → Certificate (edge cert + CA; client
validates signature chain, name match, expiry) → key exchange (ECDHE —
both derive identical session keys; private keys never travel) → Finished
→ all following bytes are symmetric-encrypted `Application Data`.

---

## Task F — HTTP caching behaviour

**Goal:** show `Cache-Control`, `ETag`, and a real **304**.

```bash
# 1. First request — full response + cache metadata
curl -I https://app.team1.test/api/cached
#    Cache-Control: public, max-age=60
#    ETag: "b4c1..."   Last-Modified: Wed, 01 Jan 2025 09:00:00 GMT

# 2. Conditional request — client asks "still the same?"
ETAG=$(curl -sI https://app.team1.test/api/cached | tr -d '\r' | awk -F': ' 'tolower($1)=="etag"{print $2}')
curl -I -H "If-None-Match: $ETAG" https://app.team1.test/api/cached
#    HTTP/2 304      <- headers only, ZERO body bytes re-sent

# 3. Content changed (?version=v2) -> new ETag -> full 200 again
curl -I "https://app.team1.test/api/cached?version=v2"
```

Browser version: open `https://app.team1.test/api/cached`, DevTools →
Network → reload → see "(disk cache)" or a 304 row with ~0 bytes.

**Explain the three cases:** *fresh hit* (within max-age: no request at
all) vs *conditional revalidation* (after max-age: tiny request, 304 if
unchanged) vs *full request* (validator changed: whole body again). CDNs
live on exactly this machinery (`ETag` ≈ object version, `max-age` ≈ edge
freshness window).

---

## Task G — Capture the complete protocol flow

**Goal:** Wireshark proof of DNS → TCP → TLS → HTTP for ONE request.

1. `brew install --cask wireshark` (grant the ChmodBPF helper when asked).
2. Capture on **en0** (the Wi-Fi interface) of the client Mac. Optionally
   run two captures at once: client Mac (sees DNS + client-side TLS) and
   Mac 2 (sees decrypted-origin HTTP to backends — great for discussion).
3. Generate traffic: `dig app.team1.test` then
   `curl https://app.team1.test/api/status`.
4. Point at each layer with display filters:

   | Evidence | Filter | What to explain |
   |---|---|---|
   | DNS query/answer | `dns` | A? app.team1.test → A <MAC2_IP>; **UDP port 53**; query+response IDs match |
   | TCP handshake | `tcp.flags.syn==1` | SYN (client eph. port → 443), SYN-ACK, then the bare ACK (`tcp.flags.ack==1 && tcp.len==0`); **no app data before the handshake completes** |
   | Seq/ack numbers | `tcp.stream eq N` | relative seq/ack advancing by payload length = reliable, ordered, flow-controlled delivery |
   | TLS handshake | `tls.handshake.type==1` / `==2` / `==11` / `==20` | ClientHello (find **SNI** inside), ServerHello, Certificate, ChangeCipherSpec (TLS1.2; a *compatibility* CCS may appear in TLS1.3) |
   | Encrypted payload | `tls.app_data` | after Finished, HTTP is unreadable — proof TLS works |
   | Ports recap | — | DNS 53/UDP; HTTPS 443/TCP; backends 3001/3002 TCP (visible only in a Mac 2 capture) |

5. Save captures + export text (File → Export Packet Dissections → As Plain
   Text) into `evidence/`. `scripts/collect-evidence.sh --capture` also
   records a tcpdump `.pcap` of the same flow automatically.

**No-Wireshark fallback** (tcpdump ships with macOS):

```bash
sudo tcpdump -i en0 -w evidence/tcp/flow.pcap "host <MAC2_IP> or port 53"
# ...generate traffic, Ctrl+C, then open flow.pcap in Wireshark
```

---

## Required failure demonstrations (brief §6.3)

Run `./scripts/failures.sh` (menu) — it breaks, observes, explains and
restores each scenario:

| # | Scenario | Expected observation | The lesson |
|---|---|---|---|
| 1 | Wrong DNS server on client | lookup fails; `ping` to all IPs still fine | DNS ⟂ IP reachability |
| 2 | Record points to wrong IP | resolution succeeds, connection dies | DNS is a directory, not a connection |
| 3 | One backend stopped | all requests served by the other one | LB absorbs instance failure |
| 4 | Both backends stopped | **502** from edge; `/edge-status` still 200; DNS+TLS fine | where edge ends, backend begins |
| 5 | Wrong destination port | instant "connection refused"; host pings fine | IP address and port are separate identifiers (4-tuple) |

Save every scenario's terminal output into `evidence/failures/`.

---

## Phase 1 gate — run this last

```bash
./scripts/verify.sh          # from a client Mac; everything must PASS
./scripts/demo-phase1.sh     # rehearse the graded sequence (steps 1–8)
./scripts/collect-evidence.sh
```

## Troubleshooting quick hits

* **`dig` works but browser/curl doesn't** → you forgot the CA trust, or
  DNS was set on the wrong network service (`networksetup -listallnetworkservices`).
* **dnsmasq won't start** → port 53 taken (`sudo lsof -nP -iUDP:53`); turn
  off Internet Sharing; remember it needs sudo.
* **nginx: "Address already in use"** → previous instance: `sudo nginx -c
  /tmp/team1-run/nginx.conf -s stop`; or something else holds 443/80.
* **Changed a DNS record but nothing changed** → dnsmasq needs a FULL
  restart (HUP re-reads `/etc/hosts`, not `address=` records) AND the
  client cache must expire/flush (`sudo dscacheutil -flushcache; sudo
  killall -HUP mDNSResponder`).
* **IPs changed overnight (DHCP)** → update `config.env` → `configure.sh` →
  restart dnsmasq + nginx. (This TTL/DHCP fragility is a great viva point:
  production uses static leases or DHCP reservations.)
* **Everything is fine but load balancing looks lopsided** → keep-alive:
  one TCP connection can serve many requests to the SAME backend; round-
  robin balances *connections/requests at proxy time* — 10 separate `curl`
  invocations alternate cleanly.
