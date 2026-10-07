# Computer Networks Course Project: Private Network Service Platform

> **Core Principle:** *The application stays simple — the network is the project.*

A hands-on, team-based local networking project designed to demonstrate how real-world network requests travel across all layers of the OSI and TCP/IP stack from client to server and back. Built entirely on a private local network across **4 macOS laptops** with **zero cloud dependencies**.

---

## 1. Team Members & Roles

| Machine | Name | Enrollment Number | Assigned Role | Services Running | Course / Cloud Equivalent |
|---|---|---|---|---|---|
| **Mac 1** |Rudra Pratap Singh Choudhary  |2401010394  | **Private DNS Server + Client** | `dnsmasq` (Port 53/UDP), `dig`, `curl`, browser | Managed DNS Service (e.g., AWS Route 53) |
| **Mac 2** |Somraj Nandi  |2401020070  | **Edge Reverse Proxy + Load Balancer** | `nginx` (Ports 443 & 8443/TCP), TLS Termination | Cloud Load Balancer / API Gateway / CDN Edge |
| **Mac 3** |  |  | **Backend Server A** | Python REST Backend (Port 3001/TCP) | Application Server Instance A |
| **Mac 4** |  |  | **Backend Server B + Client** | Python REST Backend (Port 3002/TCP), `curl`, browser | Application Server Instance B + Client |

---

## 2. Project Architecture & End-to-End Request Flow

Clients never connect directly to the backend application servers. All traffic is resolved through the private DNS server and routed through the Edge reverse proxy.

```
                  ┌──────────────────────────────────────────────────────────┐
                  │                 Private LAN (Shared Wi-Fi)               │
                  └──────────────────────────────────────────────────────────┘
                                               │
       [1] DNS Query "app.team1.test" (UDP :53)│
       ───────────────────────────────────────►│ Mac 1 (DNS Server - dnsmasq)
       ◄───────────────────────────────────────│ Resolves to Mac 2 IP (TTL: 30s)
       [2] DNS Answer: 10.7.4.94               │
                                               │
Client (Mac 4 / Mac 1)                         │
       │                                       │
       │ [3] TCP 3-Way Handshake (SYN, SYN-ACK, ACK)
       │ [4] TLS 1.3 Handshake (ClientHello, ServerHello, Cert, Encrypted Extensions)
       │ [5] HTTPS Request: GET https://app.team1.test/api/status
       ▼
Mac 2 (Edge Nginx Reverse Proxy & Load Balancer - Port 443/8443)
       │
       │ Plain HTTP/1.1 (Internal LAN)
       ├─────────────────────────► Mac 3: Backend A (Port 3001) [Returns X-Backend: A]
       │       (Round-Robin)
       └─────────────────────────► Mac 4: Backend B (Port 3002) [Returns X-Backend: B]
```

### Complete Protocol Flow Across the Layers:
1. **Network & Data Link Layer:** All machines connect to the same Wi-Fi subnet (e.g., `10.7.x.x`), verified by bidirectional `ping` checks.
2. **DNS Resolution (UDP Port 53):** Client queries the private DNS resolver on Mac 1 for `app.team1.test`. `dnsmasq` returns the IP of Mac 2 (the Edge) with a 30-second TTL.
3. **TCP Connection (TCP Port 443):** Client initiates a TCP 3-way handshake (`SYN` → `SYN-ACK` → `ACK`) from an ephemeral source port to Mac 2 on port 443.
4. **TLS Termination (Port 443):** Client and Mac 2 perform a TLS 1.2/1.3 handshake. Mac 2 presents a certificate signed by our private Root CA. The client validates the certificate using its local system trust store (no `-k` flag required).
5. **Reverse Proxying & Load Balancing:** Nginx proxies the decrypted HTTP request to either Backend A (Mac 3:3001) or Backend B (Mac 4:3002) using round-robin distribution.
6. **HTTP Response & Caching:** The backend responds with JSON and an `X-Backend: A|B` header. Cacheable endpoints return `Cache-Control: public, max-age=60` and `ETag`, allowing client revalidation and `304 Not Modified` responses.

---

## 3. How to Run the Backends

Both backend instances are powered by a single, lightweight Python application (`backends/backend.py`) built exclusively with the **Python 3 standard library** (zero external dependencies, no `pip install` required).

### Run Backend A (on Mac 3):
```bash
python3 backends/backend.py --name A --port 3001
```

### Run Backend B (on Mac 4):
```bash
python3 backends/backend.py --name B --port 3002
```

### Backend Endpoints:
| Endpoint | Method | Response / Purpose |
|---|---|---|
| `/` | `GET` | Welcome JSON confirming backend status and operational details |
| `/api/status` | `GET` | Required contract: `{"backend": "A"|"B", "status": "ok"}` + `Cache-Control` + `ETag` + `X-Backend` header |
| `/api/cached` or `/api/data` | `GET` | Cacheable resource: `Cache-Control: public, max-age=60`, `ETag`. Supports conditional requests (`If-None-Match`) returning `304 Not Modified` |
| `/health` | `GET` | Liveness check returning `200 ok` |
| `/slow?seconds=5` | `GET` | Artificial delay endpoint to demonstrate edge proxy timeouts and failover |

---

## 4. How to Run the Infrastructure Services

### 1. Private DNS Server (`dnsmasq` on Mac 1):
```bash
# Start dnsmasq in foreground with query logging:
sudo dnsmasq --conf-file=deploy/mac1/dnsmasq.conf -d
```
*Listens on port 53/UDP, resolving `app.team1.test` and `api.team1.test` to Mac 2's Edge IP.*

### 2. Edge Reverse Proxy & Load Balancer (`nginx` on Mac 2):
```bash
# Start nginx with project configuration:
sudo nginx -c $(pwd)/deploy/mac2/nginx.conf

# To reload configuration:
sudo nginx -c $(pwd)/deploy/mac2/nginx.conf -s reload

# To stop nginx:
sudo nginx -c $(pwd)/deploy/mac2/nginx.conf -s stop
```
*Listens on ports 443 and 8443 (HTTPS) with TLS termination and load balances across Backend A and Backend B.*

---

## 5. Client Verification & Testing Commands

Run these verification commands from any client machine (Mac 1 or Mac 4) connected to the private LAN:

### 1. Test Private DNS Resolution:
```bash
# Query the private DNS server directly:
dig @10.7.14.12 app.team1.test +noall +answer

# Verify the domain does NOT exist on the public internet (proves it is private):
dig @8.8.8.8 app.team1.test
```

### 2. Test HTTPS and TLS Termination (Strict Validation - No `-k` flag!):
```bash
# Inspect the TLS handshake and certificate chain:
curl -v https://app.team1.test/api/status
```

### 3. Test Round-Robin Load Balancing:
```bash
# Send repeated requests and observe alternating X-Backend headers:
for i in {1..6}; do curl -sI https://app.team1.test/api/status | grep -i "X-Backend"; done
```
*Expected Output:*
```text
X-Backend: A
X-Backend: B
X-Backend: A
X-Backend: B
X-Backend: A
X-Backend: B
```

### 4. Test HTTP Caching & Conditional Requests (304 Not Modified):
```bash
# Initial request (returns 200 OK, Cache-Control: max-age=60, and ETag):
curl -i https://app.team1.test/api/data

# Conditional request using If-None-Match (returns 304 Not Modified with zero body bytes):
curl -i -H 'If-None-Match: "v1-static-hash"' https://app.team1.test/api/data
```

---

## 6. Required Failure Demonstration (Option A — Backend Failover)

To demonstrate network layer isolation and high-availability load balancer failover:

1. **Before State:** Execute curl requests to show traffic alternating between `A` and `B`:
   ```bash
   for i in {1..4}; do curl -sI https://app.team1.test/api/status | grep -i "X-Backend"; done
   ```
2. **Trigger Failure:** Terminate Backend A on Mac 3 by pressing `Ctrl + C`.
3. **After State:** Send requests again from the client:
   ```bash
   for i in {1..6}; do curl -sI https://app.team1.test/api/status | grep -i "X-Backend"; done
   ```
   *Result:* All requests continue to succeed with `HTTP 200 OK` and are served exclusively by `X-Backend: B`. Zero requests are dropped.
4. **Network Explanation:**
   - **Layer affected:** Application layer (Backend server down).
   - **Transport behavior:** The edge attempts a TCP connection to `10.7.20.87:3001`, which is refused.
   - **Recovery mechanism:** Nginx marks Backend A as temporarily unavailable (`max_fails=2`, `fail_timeout=10s`) and automatically retries the request on Backend B via `proxy_next_upstream`, shielding the client from downtime.
5. **Restoration:** Restart Backend A on Mac 3. After the 10-second timeout, Nginx seamlessly re-adds Backend A to the active round-robin pool.

---

## 7. Mapping to Computer Networks Course Topics

| Course Topic | Project Implementation & Proof |
|---|---|
| **OSI vs TCP/IP Models** | Direct mapping: DNS (Application/UDP), HTTP (Application/TCP), TLS (Session/Security), TCP (Transport), IP (Network), Ethernet/Wi-Fi (Link). |
| **DNS & Name Resolution** | Private `.test` namespace, UDP Port 53 queries, A records, and TTL caching behavior via `dnsmasq`. |
| **Transport Layer (TCP/UDP)** | TCP 3-way handshake (`SYN`, `SYN-ACK`, `ACK`), connection state, sequence/acknowledgement tracking, and socket pairs (ephemeral client port $\leftrightarrow$ well-known service port). |
| **Network Security & TLS** | TLS 1.2/1.3 cryptographic handshake, cipher suite negotiation, Public Key Infrastructure (PKI) with custom Root CA, and TLS termination at the edge proxy. |
| **HTTP Protocols & Caching** | HTTP/1.1 keep-alive connections, `Cache-Control: max-age=60`, `ETag` validators, and conditional `304 Not Modified` revalidation. |
| **Load Balancing & Resilience** | Reverse proxy architecture, round-robin load distribution, passive health checking (`max_fails`, `fail_timeout`), and upstream failover (`proxy_next_upstream`). |
