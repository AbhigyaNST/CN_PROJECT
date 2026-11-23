# Phase 1 — 5-Minute Video Recording Guide (Rubric-Mapped)

> All commands use your real values from [`config.env`](file:///Users/rudra/Desktop/cn-project/config.env)

```
Mac 1 (DNS)      10.7.14.12   dnsmasq  UDP :53
Mac 2 (Edge)     10.7.4.94    nginx    TCP :443 / :8443
Mac 3 (Backend A) 10.7.15.253 backend  TCP :3001
Mac 4 (Backend B) 10.7.17.142 backend  TCP :3002
Domain: app.team1.test
```

---

## ⏱ Timing Map — Every Rubric Point

| Time | Rubric | What you show |
|---|---|---|
| 0:00–0:45 | **A1 + A5** | Machine roles + ping all pairs |
| 0:45–1:30 | **A2 + A3 + A4** | dnsmasq.conf + dig from client + NXDOMAIN |
| 1:30–2:30 | **B3 + B1 + B2** | nginx.conf + curl -v + round-robin loop |
| 2:30–3:30 | **C1 + C2 + C3** | Wireshark DNS / TCP / TLS |
| 3:30–4:00 | **D1 + D2** | curl -sI caching headers + verbal explanation |
| 4:00–5:00 | **D3** | Failure demo: stop Backend A + restore |

---

## 🎬 SECTION A — LAN Setup & Private DNS `0:00 – 1:30`

---

### `0:00 – 0:45` ▶ A1: Machine IPs + Roles · A5: Ping Proof

**Screen layout:** Single clean terminal on Mac 4 (your test client Mac).

**Run this block exactly — pause 2 seconds after each ping finishes:**
```bash
# Show your own IP and interface first (proves you are on the LAN)
ifconfig en0 | grep "inet "

# A5 — Ping all machines from this client
ping -c 4 10.7.14.12   # Mac 1 — DNS
ping -c 4 10.7.4.94    # Mac 2 — Edge
ping -c 4 10.7.15.253  # Mac 3 — Backend A
# Mac 4 is this machine (10.7.17.142) — skip self-ping
```

> **Say while pings run:**  
> "I'm on Mac 4 — `10.7.17.142`. This is the test client.  
> Mac 1 at `10.7.14.12` is our private DNS server running dnsmasq.  
> Mac 2 at `10.7.4.94` is the Edge — nginx with TLS and load balancing.  
> Mac 3 at `10.7.15.253` runs Backend A on port 3001. Mac 4 runs Backend B on 3002.  
> All four pings succeed with zero packet loss — Layer 3 is confirmed across the LAN."

> **A1 ✅** — Roles and IPs are spoken + on screen via `ifconfig`  
> **A5 ✅** — Ping proof from a client machine to all 3 others

---

### `0:45 – 1:30` ▶ A2: dnsmasq Config · A3: dig from Client · A4: NXDOMAIN

**Step 1 — Open the config file** ([`deploy/mac1/dnsmasq.conf`](file:///Users/rudra/Desktop/cn-project/deploy/mac1/dnsmasq.conf)):

```bash
cat deploy/mac1/dnsmasq.conf
```

**Point at and narrate these lines specifically:**
```
listen-address=127.0.0.1,10.7.14.12     ← A2: bound to LAN interface
port=53
address=/app.team1.test/10.7.4.94       ← A2: maps name to Edge IP
address=/api.team1.test/10.7.4.94       ← A2: same for api subdomain
local-ttl=30                             ← A2: 30-second TTL
local=/team1.test/                       ← A2: .test zone is local-only
no-resolv                                ← never forwarded upstream
```

> **Say:** "This is the complete dnsmasq configuration. `listen-address` binds to Mac 1's LAN IP — other machines can reach it. Both `app` and `api` subdomains map to the Edge at `10.7.4.94`. The `.test` zone is flagged as local-only and never forwarded to the internet."

**Step 2 — A3: dig from THIS client machine (Mac 4, NOT Mac 1):**
```bash
dig @10.7.14.12 app.team1.test
```

**Point at the output:**
```
;; SERVER: 10.7.14.12#53        ← evaluator checks this: must be YOUR DNS, not 8.8.8.8
;; ANSWER SECTION:
app.team1.test.    30    IN    A    10.7.4.94    ← Edge IP, TTL 30
```

> **Say:** "Query sent from Mac 4 to Mac 1 at `10.7.14.12` — not Google. The ANSWER SECTION returns the Edge IP `10.7.4.94` with TTL 30. DNS is working across the LAN."

> **A3 ✅**

**Step 3 — A4: NXDOMAIN from 8.8.8.8:**
```bash
dig @8.8.8.8 app.team1.test
```

**Point at:**
```
;; status: NXDOMAIN    ← this is what the evaluator is checking for
;; SERVER: 8.8.8.8#53  ← confirms this went to Google, not our DNS
```

> **Say:** "When we ask Google's DNS, we get NXDOMAIN — this name does not exist on the public internet. It exists exclusively on our private DNS server. This is what makes it a private network service."

> **A2 ✅** · **A4 ✅**

---

## 🎬 SECTION B — HTTPS, Reverse Proxy & Load Balancing `1:30 – 2:30`

---

### `1:30 – 1:50` ▶ B3: nginx Configuration

**Open [`deploy/mac2/nginx.conf`](file:///Users/rudra/Desktop/cn-project/deploy/mac2/nginx.conf):**
```bash
cat deploy/mac2/nginx.conf
```

**Point at and narrate these blocks:**
```nginx
# B3: upstream block
upstream backends {
    server 10.7.15.253:3001 max_fails=2 fail_timeout=10s;  # Backend A
    server 10.7.17.142:3002 max_fails=2 fail_timeout=10s;  # Backend B
}

# B3: server block — TLS termination
server {
    listen 443 ssl;
    listen 8443 ssl;
    http2 on;
    ssl_certificate     .../edge-fullchain.crt;
    ssl_certificate_key .../edge.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

    location / {
        proxy_pass http://backends;                         # → upstream pool
        proxy_next_upstream error timeout http_502;         # failover
    }
}
```

> **Say:** "The `upstream` block lists both backend IPs and ports. No load-balancing method is set — nginx defaults to **round-robin**, alternating A and B. `max_fails=2, fail_timeout=10s` is passive health-checking. The server block terminates TLS on 443 and 8443 and proxies plain HTTP to the backends — that's TLS termination at the edge."

> **B3 ✅**

---

### `1:50 – 2:10` ▶ B1: curl -v HTTPS (no -k flag)

```bash
curl -v https://app.team1.test/api/status
```

**Wait for output. Point at these lines explicitly:**
```
* TLSv1.3 (OUT), TLS handshake, Client hello      ← TLS handshake
* SSL connection using TLSv1.3 / TLS_AES_256_GCM_SHA384
* subject: CN=app.team1.test                       ← cert matches domain
* SSL certificate verify ok.                       ← no -k flag, genuine
< HTTP/2 200                                       ← 200 OK
```

> **Say:** "TLS 1.3 negotiated. Certificate subject matches our domain name. `SSL certificate verify ok` — our local CA is trusted in the macOS Keychain so no `-k` flag is needed anywhere. HTTP/2 200."

> **B1 ✅**

---

### `2:10 – 2:30` ▶ B2: Round-Robin Load Balancing

```bash
for i in {1..6}; do
  curl -s https://app.team1.test/api/status | grep -E '"backend"'
done
```

**Expected output — pause and let evaluator read it:**
```
"backend": "A"
"backend": "B"
"backend": "A"
"backend": "B"
"backend": "A"
"backend": "B"
```

> **Say:** "Six requests, perfect A-B-A-B-A-B alternation. Both backends appear. Round-robin is confirmed — nginx is distributing load across Mac 3 and Mac 4."

> **B2 ✅**

---

## 🎬 SECTION C — Wireshark Packet Evidence `2:30 – 3:30`

**Pre-step before this section:**  
On your Mac: clear DNS cache first so you generate a fresh DNS lookup.
```bash
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
```

Then start Wireshark capturing on `en0`. Say:  
> "I've cleared the macOS DNS cache. Starting a live Wireshark capture on `en0` — this will generate one fresh DNS lookup and one new TLS connection."

```bash
curl -s https://app.team1.test/api/status > /dev/null
```

> "Capture complete. I'll stop the capture and walk through the three filters."

---

### `2:30 – 2:50` ▶ C1: DNS Filter

**In Wireshark, apply filter:** `dns`

**Point at two rows:**
1. **Query row:** `Standard query A app.team1.test`  
   - Source: your Mac IP (`10.7.17.142` on Mac 4)  
   - Destination: `10.7.14.12` (Mac 1 DNS)  
   - Protocol: **UDP**, Port **53**

2. **Response row:** `Standard query response A 10.7.4.94`  
   - Source: `10.7.14.12`  
   - TTL: **30**

> **Say:** "DNS query from my Mac to Mac 1 at `10.7.14.12` over UDP port 53. The response is the Edge IP `10.7.4.94` with TTL 30 — exactly what dnsmasq is configured to return."

> **C1 ✅**

---

### `2:50 – 3:10` ▶ C2: TCP 3-Way Handshake

**Apply filter:** `tcp.flags.syn==1 && ip.addr==10.7.4.94`

**Point at three rows in order:**
1. **SYN** — From: `10.7.17.142:EPHEMERAL` → `10.7.4.94:443` · Seq=0  
2. **SYN-ACK** — From: `10.7.4.94:443` → `10.7.17.142:EPHEMERAL` · Seq=0, Ack=1  
3. **ACK** — From: `10.7.17.142` → `10.7.4.94:443` · Ack=1

> **Say:** "SYN from my Mac's ephemeral port to the Edge at `10.7.4.94:443`. SYN-ACK from the Edge acknowledges it. My ACK completes the handshake. Seq=0, Ack=1. This three-way handshake establishes a reliable, ordered, connection-oriented TCP channel before any TLS or HTTP data is sent."

> **C2 ✅**

---

### `3:10 – 3:30` ▶ C3: TLS Handshake

**Apply filter:** `tls && ip.addr==10.7.4.94`

**Point at packets in order:**
1. **ClientHello** → offered TLS 1.3, cipher suites
2. **ServerHello + Certificate** → server selects cipher, sends cert
3. **Application Data** rows → all subsequent rows

> **Say:** "ClientHello — my Mac offers TLS options. ServerHello — the Edge selects TLS 1.3 and presents its certificate. After the handshake, every subsequent packet shows only `Application Data` — Wireshark cannot decode the HTTP headers or body because they are encrypted inside the TLS record layer. This is what end-to-end encryption looks like at the packet level."

> **C3 ✅**

---

## 🎬 SECTION D — Caching & Failure Demo `3:30 – 5:00`

---

### `3:30 – 4:00` ▶ D1: Cache Headers · D2: Explanation

**Run on Mac 4:**
```bash
curl -sI https://app.team1.test/api/cached
```

**Point at:**
```
HTTP/2 200
cache-control: public, max-age=60
etag: "..."
x-backend: B
date: ...
```

> **Say — D1:** "The response carries `Cache-Control: public, max-age=60` and an `ETag` header."

> **Say — D2:** "`max-age=60` tells the client this response is fresh for 60 seconds — it can serve it from local cache without contacting the server at all. After 60 seconds, the cache entry expires and the client must revalidate. The ETag is a fingerprint of the content. The client sends it back in an `If-None-Match` header on the next request:"

```bash
ETAG=$(curl -sI https://app.team1.test/api/cached | tr -d '\r' | awk -F': ' 'tolower($1)=="etag"{print $2}')
curl -sI -H "If-None-Match: $ETAG" https://app.team1.test/api/cached | head -5
```

```
HTTP/2 304
```

> **Say:** "304 Not Modified — zero body bytes transferred. The server confirmed the cached copy is still valid. The network carries headers only, not data."

> **D1 ✅** · **D2 ✅**

---

### `4:00 – 5:00` ▶ D3: Failure Demo — Option A: Stop Backend A

**Screen layout:** Side-by-side. Left = SSH into Mac 3. Right = curl on Mac 4.

---

**[4:00 – 4:15] BEFORE state — both healthy:**

**Right terminal:**
```bash
for i in {1..4}; do curl -s https://app.team1.test/api/status | grep '"backend"'; done
```
```
"backend": "A"
"backend": "B"
"backend": "A"
"backend": "B"
```

> **Say:** "Before state: A and B alternating normally. Both backends healthy."

---

**[4:15 – 4:35] ACTION — kill Backend A:**

**Left terminal (Mac 3):**
```bash
pkill -f "backend.py"
lsof -iTCP:3001 -sTCP:LISTEN    # should return empty — nothing listening
```

> **Say:** "Backend A process is killed. Port 3001 is now closed. Mac 3 is still on the network — but the service is gone."

**Right terminal — immediately:**
```bash
for i in {1..6}; do curl -s https://app.team1.test/api/status | grep '"backend"'; done
```
```
"backend": "B"
"backend": "B"
"backend": "B"
"backend": "B"
"backend": "B"
"backend": "B"
```

> **Say:** "Every request returns HTTP 200 from Backend B — no errors, no timeouts. nginx detected the TCP connection failure to port 3001, triggered `proxy_next_upstream`, and silently retried on Backend B — within the same request. After two failures in 10 seconds, it marks Backend A down.  
> **Layer affected: Transport layer.** The failure is a TCP connection refused — port 3001 has no listening socket. The DNS, IP, and application layers are untouched."

---

**[4:35 – 5:00] RESTORE:**

**Left terminal (Mac 3):**
```bash
python3 backends/backend.py --name A --port 3001 &
lsof -iTCP:3001 -sTCP:LISTEN    # confirms it's listening again
```

> **Say:** "Backend A is restored."

**Right terminal:**
```bash
sleep 12   # wait for fail_timeout=10s to expire
for i in {1..4}; do curl -s https://app.team1.test/api/status | grep '"backend"'; done
```
```
"backend": "A"
"backend": "B"
"backend": "A"
"backend": "B"
```

> **Say:** "After the 10-second `fail_timeout`, nginx re-admits Backend A. Round-robin resumes. System is fully restored.  
> The key principle: the load balancer **decouples instance availability from service availability** — one server crashed and the service never went down. This concludes my Phase 1 demonstration."

> **D3 ✅**

---

## ✅ Pre-Recording Checklist

**Before you press record:**
- [ ] All 4 Macs on same Wi-Fi — verify `ping` works between all pairs
- [ ] dnsmasq running on Mac 1: `sudo brew services list | grep dnsmasq`
- [ ] nginx running on Mac 2: `sudo brew services list | grep nginx`
- [ ] Backend A running on Mac 3: `lsof -iTCP:3001 -sTCP:LISTEN`
- [ ] Backend B running on Mac 4: `lsof -iTCP:3002 -sTCP:LISTEN`
- [ ] CA trusted in macOS Keychain: `security find-certificate -c "team1 Local Root CA" /Library/Keychains/System.keychain`
- [ ] Font size 16–18pt (`Cmd + +` in terminal)
- [ ] Wireshark installed, capturing on `en0`
- [ ] Two terminals ready for failure section (SSH to Mac 3 on left, curl on right)

**Never show on screen:**
- `scripts/failures.sh`
- `scripts/demo-phase1.sh`  
- `practice/run-local.sh`

---

## 🗂 Files to open on screen

| Timestamp | File | Lines to highlight |
|---|---|---|
| 0:45 | [`deploy/mac1/dnsmasq.conf`](file:///Users/rudra/Desktop/cn-project/deploy/mac1/dnsmasq.conf) | `listen-address=`, `address=/app...`, `local-ttl=30`, `local=/team1.test/` |
| 1:30 | [`deploy/mac2/nginx.conf`](file:///Users/rudra/Desktop/cn-project/deploy/mac2/nginx.conf) | `upstream backends {}`, `listen 443 ssl`, `ssl_certificate`, `proxy_pass`, `proxy_next_upstream` |

---
---

# Per-Mac Startup Guide — Start to End

> **Your real values (from `config.env`)**
> ```
> TEAM     = team1         → domain: app.team1.test / api.team1.test
> Mac 1    = 10.7.14.12   → DNS server (dnsmasq :53)
> Mac 2    = 10.7.4.94    → Edge nginx (:443 / :8443)
> Mac 3    = 10.7.15.253  → Backend A (:3001)
> Mac 4    = 10.7.17.142  → Backend B (:3002) + test client
> Run dir  = /tmp/team1-run
> ```
> Every Mac needs the **same repo folder** copied to it before you start.

---

## ⚙️ ONE-TIME SETUP (do before demo day, not on camera)

### On Mac 2 — generate the local CA + certificates
```bash
cd /Users/rudra/Desktop/cn-project
./certs/make-ca-and-cert.sh
# Creates:
#   deploy/mac2/certs/ca.crt              ← share this with Mac 1 and Mac 4
#   deploy/mac2/certs/edge-fullchain.crt  ← stays on Mac 2
#   deploy/mac2/certs/edge.key            ← stays on Mac 2
```

### On Mac 1 — trust the CA (so Mac 1 can also be a client if needed)
```bash
sudo security add-trusted-cert -d -r trustRoot \
     -k /Library/Keychains/System.keychain \
     /Users/rudra/Desktop/cn-project/deploy/mac2/certs/ca.crt
```

### On Mac 4 — trust the CA (REQUIRED — this is the test client)
```bash
sudo security add-trusted-cert -d -r trustRoot \
     -k /Library/Keychains/System.keychain \
     /Users/rudra/Desktop/cn-project/deploy/mac2/certs/ca.crt

# Verify it took
security find-certificate -c "team1 Local Root CA" /Library/Keychains/System.keychain
```

### On Mac 4 — point DNS at Mac 1 (REQUIRED — do once, stays until you reset)
```bash
# Find your Wi-Fi service name first
networksetup -listallnetworkservices
# It's usually "Wi-Fi" — if different substitute below

sudo networksetup -setdnsservers Wi-Fi 10.7.14.12
sudo dscacheutil -flushcache
sudo killall -HUP mDNSResponder

# Verify
scutil --dns | grep "nameserver\[0\]"   # must say: 10.7.14.12
dig app.team1.test +short                # must return: 10.7.4.94
```

---

## 🚀 DEMO DAY LAUNCH ORDER

Run each step, **wait for it to succeed**, then move to the next.

---

### STEP 1 — Mac 2: Start the Edge (nginx)

```bash
cd /Users/rudra/Desktop/cn-project
./scripts/mac2-edge.sh
```

**What it does automatically:**
- Checks cert files exist in `deploy/mac2/certs/`
- Installs nginx via Homebrew if not present
- Stamps `deploy/mac2/nginx.conf` with cert paths → writes `/tmp/team1-run/nginx.conf`
- Runs `nginx -t` (config test), then `sudo nginx -c /tmp/team1-run/nginx.conf`
- Self-tests by hitting `https://app.team1.test/edge-status` with `--cacert`

**You should see at the end:**
```
[PASS] Edge answers over HTTPS with a VALIDATED certificate (no -k anywhere)
```

**Verify manually:**
```bash
sudo lsof -iTCP:443 -sTCP:LISTEN -P -n    # nginx worker visible
sudo lsof -iTCP:8443 -sTCP:LISTEN -P -n
```

**If nginx is already running from a previous attempt:**
```bash
# Stop it first, then re-run mac2-edge.sh
sudo nginx -c /tmp/team1-run/nginx.conf -s stop
./scripts/mac2-edge.sh
```

---

### STEP 2 — Mac 1: Start DNS (dnsmasq)

```bash
cd /Users/rudra/Desktop/cn-project
./scripts/mac1-dns.sh
```

**What it does automatically:**
- Installs dnsmasq via Homebrew if not present
- Copies `deploy/mac1/dnsmasq.conf` → `$(brew --prefix)/etc/dnsmasq.conf`
- Runs `sudo brew services restart dnsmasq`
- Self-tests: `dig @127.0.0.1 app.team1.test` and checks it returns `10.7.4.94`

**You should see:**
```
[PASS] app.team1.test -> 10.7.4.94 (correct: the edge, Mac 2)
```

**Verify manually:**
```bash
sudo brew services list | grep dnsmasq          # started
sudo lsof -iUDP:53 -P -n | grep dnsmasq         # listening
dig @127.0.0.1 app.team1.test +short             # 10.7.4.94
```

**The script also prints the exact commands to run on client Macs:**
```
sudo networksetup -setdnsservers Wi-Fi 10.7.14.12
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
```

---

### STEP 3 — Mac 3: Start Backend A

```bash
cd /Users/rudra/Desktop/cn-project
./scripts/mac3-backend-a.sh
```

**What it does:** Calls `backends/start-backend-a.sh` which runs:
```bash
python3 backends/backend.py --name A --port 3001
```

Runs **in the foreground** — you will see every request logged live.  
**Keep this terminal open and visible during the demo.**

**Verify (from Mac 3, in a second terminal tab):**
```bash
curl -s http://127.0.0.1:3001/api/status | python3 -m json.tool
# Expected: {"backend": "A", "status": "ok", ...}
lsof -iTCP:3001 -sTCP:LISTEN -P -n              # python3 listening
```

> **⚠ For failure demo D3:** You will `Ctrl+C` this terminal on camera.  
> Position this window on the **left side** of your split screen.

---

### STEP 4 — Mac 4: Start Backend B

Mac 4 runs two things simultaneously — open **two terminal tabs**:

**Tab 1 — Backend B (leave running):**
```bash
cd /Users/rudra/Desktop/cn-project
./scripts/mac4-backend-b.sh
```

The script prints client setup reminders (DNS + CA trust), asks you to press Enter, then launches:
```bash
python3 backends/backend.py --name B --port 3002
```

**Verify (Tab 2 — your client terminal):**
```bash
curl -s http://127.0.0.1:3002/api/status | python3 -m json.tool
# Expected: {"backend": "B", "status": "ok", ...}
lsof -iTCP:3002 -sTCP:LISTEN -P -n
```

---

### STEP 5 — Mac 4: Final Go/No-Go Check (Tab 2)

Run `verify.sh` — it tests every Phase 1 requirement automatically:

```bash
cd /Users/rudra/Desktop/cn-project
SYSTEM_TRUST=1 ./scripts/verify.sh
```

> `SYSTEM_TRUST=1` tells it to use the macOS Keychain (no `--cacert` flag) — exactly what the graded demo requires.

**Every line must show `[PASS]`. If all pass → you are ready to record.**

```
[PASS] A: DNS resolves app.team1.test -> 10.7.4.94
[PASS] B: TCP port 443 open on 10.7.4.94
[PASS] C/D: HTTP 200 from /api/status
[PASS] E: TLS certificate verify ok (system trust, no -k)
[PASS] F: X-Backend: A seen
[PASS] F: X-Backend: B seen (round-robin confirmed)
[PASS] ...
ALL CHECKS PASSED
```

If anything fails, verify.sh tells you exactly which layer is broken.

---

## 🎬 During the Video — Terminal Layout

```
┌─────────────────────────┬─────────────────────────┐
│   Mac 3 SSH / Terminal  │   Mac 4 Client Terminal  │
│   Backend A running     │   All curl/dig commands  │
│   (foreground logs)     │   go here                │
│                         │                          │
│  [For D3: kill here]    │  [All video commands]    │
└─────────────────────────┴─────────────────────────┘
```

**Mac 2 nginx access log** — useful to tail in a background tab on Mac 2:
```bash
tail -f /tmp/team1-run/nginx-access.log
# Shows: which backend served each request, client IP:port, timing
```

---

## 🔴 STOP EVERYTHING AFTER DEMO

```bash
# Mac 2 — stop nginx
sudo nginx -c /tmp/team1-run/nginx.conf -s stop

# Mac 1 — stop dnsmasq
sudo brew services stop dnsmasq

# Mac 3 — Ctrl+C in the backend terminal, or:
pkill -f "backend.py --name A"

# Mac 4 — Ctrl+C in the backend terminal, or:
pkill -f "backend.py --name B"

# Mac 4 — restore normal DNS
sudo networksetup -setdnsservers Wi-Fi Empty
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
```
