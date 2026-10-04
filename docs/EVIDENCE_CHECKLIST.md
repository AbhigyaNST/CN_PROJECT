# Evidence Checklist — "find any piece of evidence within 30 seconds"

The brief grades evidence, not claims. Run `./scripts/collect-evidence.sh`
(+ `--capture` with sudo for a pcap) to auto-fill most of this, then add
the manual screenshots. Keep filenames exactly as below — the folder is
designed to be browsed during evaluation.

```
evidence/
├── INDEX.md                      <- auto-generated map (collect-evidence.sh)
├── dns/
│   ├── 01-dig-app-*.txt          dig full output: QUESTION/ANSWER/SERVER, TTL 30 visible
│   ├── 02-dig-api-and-nslookup-* second record + nslookup cross-check
│   ├── 03-dnsmasq-query-log-*    server-side log lines (query[query] + reply)
│   └── 04-SCREENSHOT-dig.png     terminal screenshot for slides/report
├── tcp/
│   ├── 04-port-scan-*.txt        edge ports open; backend ports (state before/after pf)
│   ├── 11-full-flow-*.pcap       tcpdump capture (opens in Wireshark)
│   ├── 12-SCREENSHOT-handshake.png   Wireshark: SYN, SYN-ACK, ACK rows w/ ports
│   └── 13-SCREENSHOT-4tuple.png      any one frame: src/dst ip:port pairs highlighted
├── tls/
│   ├── 05-openssl-s-client-*     handshake summary + chain + "Verify return code: 0 (ok)"
│   ├── 06-curl-v-tls-*           curl -v TLS negotiation + HTTP response
│   ├── 07-SCREENSHOT-wireshark-tls.png  ClientHello/ServerHello/Certificate/CCS rows
│   └── 08-SCREENSHOT-encrypted-appdata.png  "Application Data" rows (HTTP unreadable)
├── http/
│   ├── 07-responses-and-headers-*  /api/status JSON + X-Backend, 301 redirect
│   ├── 10-nginx-access-*           edge log: client sockets + upstream= chosen backend
│   └── 11-SCREENSHOT-browser-padlock.png  https://app.team1.test in browser, no warnings
├── load-balancing/
│   └── 08-xbackend-alternation-*   12 requests: X-Backend A,B,A,B...
├── caching/
│   └── 09-cache-control-and-304-*  headers + conditional 304 exchange
├── failures/
│   ├── f1-wrong-dns.txt .. f5-wrong-port.txt   (terminal transcripts per scenario)
│   └── SCREENSHOTS for each of the 5 scenarios
└── phase2/
    ├── a-backup-dns-failover.txt   dig before/kill/after + curl still 200
    ├── b-ttl-record-change.txt     TTL countdown, old→new, flush effect
    ├── c-isolation-prove.txt       edge OK / client timeout / rollback OK
    ├── d-ha-failover.txt           all-B while A down, alternation restored
    ├── e-edge-cutover.txt          X-Edge-IP old→new across the TTL window
    └── f-diagnose-run.txt          diagnose.sh clean baseline output
```

## Manual captures — exact recipes

**Wireshark screenshots (Task G).** Capture on the client's en0, then:
1. Filter `dns` → expand the query for `app.team1.test` showing the
   Answer section with Mac 2's IP. Screenshot.
2. Filter `tcp.flags.syn==1` → show SYN and SYN-ACK; click the follow-up
   bare ACK. Point at source (ephemeral) / destination (443) ports. Screenshot.
3. Filter `tls.handshake` → ClientHello (expand SNI), ServerHello,
   Certificate, ChangeCipherSpec/Finished. Screenshot.
4. Filter `tls.app_data` → note that payload bytes are unreadable. Screenshot.
5. File → Export Packet Dissections → **As Plain Text** (all packets,
   summary + details) → save next to the screenshots. That's your textual,
   diff-able evidence.

**Browser evidence.** DevTools → Network → reload `https://app.team1.test/api/cached`:
screenshot the rows showing (a) status 200 with `cache-control: max-age=60`
response header, (b) on second load "(disk cache)" or a **304** with ~0 B
transferred, (c) Security tab showing the cert chain: `team1 Local Root CA`
→ `app.team1.test`.

**Failure scenarios.** For each of the five: one screenshot of the *break*
(command + failing output) and one of the *explanation moment* (e.g. ping
working while DNS fails). `./scripts/failures.sh` prints exactly the lines
to capture; tee them: `./scripts/failures.sh a | tee evidence/failures/all.txt`.

**Phase 2.** `./scripts/demo-phase2.sh <x> | tee evidence/phase2/<x>.txt`
for each extension, plus the pf rollback output (proves restore path).

## 30-second rule

Rehearse: evaluator says "show me the TLS handshake" → you open
`evidence/tls/07-SCREENSHOT-wireshark-tls.png` (or the .pcap with the saved
display filter) in under 30 s. Everything has a deterministic name and an
INDEX.md row. No digging, no "let me re-run it".
