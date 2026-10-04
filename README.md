# Private Network Service Platform — CN Course Project

A complete, ready-to-run implementation of the two-phase Computer Networks
course project: a private service platform across **4 Macs on one LAN** —
**private DNS → HTTPS edge (reverse proxy + load balancer) → two backend
app servers** — with tooling for packet-level evidence, the five required
failure demos, and every Phase 2 resilience extension.

```
Client (Mac 1 / Mac 4)
   │ ① DNS query "app.team1.test"                       UDP :53
   ▼
Mac 1 — dnsmasq (private DNS)   ──answer──▶  192.168.x.12  (TTL 30)
   │ ② TCP handshake → TLS handshake → HTTPS request    TCP :443/:8443
   ▼
Mac 2 — nginx EDGE (TLS termination + round-robin LB + failover)
   │ ③ proxied plain HTTP                               TCP :3001 / :3002
   ├────────────▶  Mac 3 — Backend A   (responds  X-Backend: A)
   └────────────▶  Mac 4 — Backend B   (responds  X-Backend: B)
```

Full diagram: [`docs/topology.svg`](docs/topology.svg) · Written architecture
document (deliverable): [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)

## Zero-dependency promise

| Component | Technology | Install needed |
|---|---|---|
| Backends (A & B) | Python 3 **standard library only** — one file | none (macOS has python3) |
| Private DNS | dnsmasq | `brew install dnsmasq` (Mac 1, + backup machine) |
| Edge / LB / TLS | nginx | `brew install nginx` (Mac 2) |
| Certificates | OpenSSL local CA | none (macOS has openssl) |
| Evidence tools | curl, dig, tcpdump/Wireshark | Wireshark optional (`brew install --cask wireshark`) |

No cloud, no Docker, no pip/npm installs. Everything runs on your laptops.

## Repository map

| Path | What it is | Deliverable it feeds |
|---|---|---|
| `config.env` | **The only file you edit**: team name, 4 IPs, ports, TTL | — |
| `backends/backend.py` | Both REST backends (one file, roles A/B via flags) | Backend Source Code |
| `templates/` | dnsmasq / nginx / pf-firewall templates with `{{placeholders}}` | Configuration Bundle |
| `deploy/` | Generated, machine-ready configs (after `configure.sh`) | Configuration Bundle |
| `certs/` | Local-CA + edge-certificate builder, trust instructions | TLS certificate setup notes |
| `scripts/mac1-dns.sh` … `mac4-backend-b.sh` | Per-machine one-shot setup | — |
| `scripts/verify.sh` | Automated **Phase 1 gate** check (all tasks A–G) | Evidence |
| `scripts/demo-phase1.sh` | Rehearses graded demo steps 1–8 | Final Demonstration |
| `scripts/failures.sh` | The 5 required failure demos (guided + automated) | Evidence |
| `scripts/demo-phase2.sh` | Extensions A–F rehearsal | Phase 2 |
| `scripts/diagnose.sh` | Layer-by-layer fault diagnosis (Extension F) | Troubleshooting |
| `scripts/firewall-apply.sh` / `-rollback.sh` | pf service isolation + safe restore (Extension C) | Phase 2 |
| `scripts/collect-evidence.sh` | Auto-fills `evidence/` with dig/curl/log/pcap proof | Evidence Folder |
| `practice/run-local.sh` | **Entire platform on ONE machine** (rehearsal + emergency fallback) | — |
| `docs/` | Architecture, setup guides, evidence checklist, viva Q&A bank, report template | Architecture Document, Final Report |
| `evidence/` | Pre-structured folders (dns/tcp/tls/http/load-balancing/caching/failures/phase2) | Evidence Folder |

## Quickstart

### Option 1 — rehearse everything on one machine first (recommended!)

```bash
./practice/run-local.sh        # starts DNS + backup DNS + edge + both backends
./scripts/verify.sh --local    # full Phase-1 gate check
./scripts/failures.sh --local a       # all 5 failure demos, automated
./scripts/demo-phase2.sh --local a    # backup-DNS failover, automated
./practice/stop-local.sh
```

### Option 2 — deploy to the 4 Macs

```bash
# 0) On EVERY Mac: copy this repo folder; install Homebrew + Xcode CLT.
#    Mac 1: brew install dnsmasq        Mac 2: brew install nginx

# 1) Edit config.env  ->  your TEAM name + the four real LAN IPs, then:
./scripts/configure.sh
./certs/make-ca-and-cert.sh

# 2) Trust the CA on every CLIENT Mac (Mac 1, Mac 4) — see certs/README.md
sudo security add-trusted-cert -d -r trustRoot \
     -k /Library/Keychains/System.keychain deploy/mac2/certs/ca.crt

# 3) One script per machine:
#    Mac 1:  ./scripts/mac1-dns.sh          (starts dnsmasq :53)
#    Mac 2:  ./scripts/mac2-edge.sh         (starts nginx :443/:8443)
#    Mac 3:  ./scripts/mac3-backend-a.sh    (Backend A :3001)
#    Mac 4:  ./scripts/mac4-backend-b.sh    (Backend B :3002)

# 4) On a client Mac: point DNS at Mac 1 (script prints the exact commands)
sudo networksetup -setdnsservers Wi-Fi <MAC1_IP>
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder

# 5) Prove the Phase-1 gate, then rehearse the graded sequence:
./scripts/verify.sh            # every check must PASS
./scripts/demo-phase1.sh       # the 8 graded demo steps, live
./scripts/collect-evidence.sh  # fills evidence/ automatically
```

Step-by-step hand-holding (including Task A network inventory and Task G
Wireshark captures): [`docs/SETUP_GUIDE_PHASE1.md`](docs/SETUP_GUIDE_PHASE1.md).
Phase 2 extensions A–F: [`docs/SETUP_GUIDE_PHASE2.md`](docs/SETUP_GUIDE_PHASE2.md).

## Changing team name, IPs, or ports

Everything derives from `config.env`. Edit it, re-run
`./scripts/configure.sh`, then restart the affected services
(DNS records need a **full** dnsmasq restart; nginx: `-s reload`).
Certificates cover `*.team1.test` via SAN wildcard, so a team-name change
only requires re-running `./certs/make-ca-and-cert.sh` and re-trusting the
new CA on clients.

## Mapping to the brief

| Brief item | Where it lives |
|---|---|
| Task A — LAN + topology | `docs/SETUP_GUIDE_PHASE1.md` §A, `docs/topology.svg`, demo step 2 |
| Task B — private DNS | `templates/dnsmasq.conf.tmpl`, `scripts/mac1-dns.sh` |
| Task C — two backends | `backends/backend.py` (`/`, `/api/status`, `X-Backend`) |
| Task D — edge + LB | `templates/nginx.conf.tmpl` (round-robin upstream) |
| Task E — HTTPS/TLS | `certs/`, nginx `ssl` block, `certs/README.md` (handshake notes) |
| Task F — caching/304 | `backend.py` `/api/cached`, demo step 7 |
| Task G — packet flow | `scripts/collect-evidence.sh`, `docs/EVIDENCE_CHECKLIST.md` |
| Failure demos (6.3) | `scripts/failures.sh` |
| Ext A — backup DNS | `templates/dnsmasq-backup.conf.tmpl`, `scripts/start-backup-dns.sh` |
| Ext B — TTL/cutover | `local-ttl` + `demo-phase2.sh b` |
| Ext C — isolation | `templates/backend-isolation.pf.conf.tmpl`, firewall scripts |
| Ext D — HA failover | nginx `max_fails`/`proxy_next_upstream`, `demo-phase2.sh d` |
| Ext E — edge migration | `demo-phase2.sh e`, wildcard SAN cert, `X-Edge-IP` header |
| Ext F — diagnosis | `scripts/diagnose.sh`, `docs/SETUP_GUIDE_PHASE2.md` §F |
| Viva preparation | `docs/VIVA_PREP.md` (60+ Q&A) |
| Final report | `docs/PHASE2_REPORT_TEMPLATE.md` |

## Verified

The complete platform — DNS resolution → TCP → TLS with local-CA validation →
round-robin load balancing → cache headers/304 → backend failover → 502
boundary → backup-DNS failover → TTL record change — was executed
end-to-end in the single-machine simulation. Transcripts:
[`docs/SIMULATION_RESULTS.md`](docs/SIMULATION_RESULTS.md).
