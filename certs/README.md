# TLS Certificate Setup Notes (Task E deliverable)

## What we built and why

Instead of a bare self-signed certificate we run a **tiny private PKI**,
exactly like the real internet, but local:

```
team1 Local Root CA  (ca.key signs — stays on ONE machine)
        │  signs
        ▼
edge certificate     (edge.key + edge.crt, served by nginx on Mac 2)
   SANs: app.team1.test, api.team1.test, *.team1.test, team1.test,
         <Mac 2 IP>, 127.0.0.1
```

* **Clients trust the CA once** → every certificate it signs is trusted
  (browsers show the padlock, `curl` works with no flags).
* **The wildcard SAN** means the same certificate also works for the
  standby edge in Phase 2 (Extension E) — no re-issuing during cutover.
* **Server cert validity is 825 days** — macOS *rejects* TLS server
  certificates valid for longer, a real-world platform constraint worth
  mentioning in the viva.
* **nginx serves the full chain** (`edge-fullchain.crt` = server cert +
  CA cert) so clients can build the chain of trust even if they only
  have the root installed.

## Generate (once, on any machine — Mac 2 is natural)

```bash
./certs/make-ca-and-cert.sh
```

## Trust the CA on EVERY client Mac (Mac 1 and Mac 4 at minimum)

```bash
sudo security add-trusted-cert -d -r trustRoot \
     -k /Library/Keychains/System.keychain \
     /path/to/cn-project/deploy/mac2/certs/ca.crt
```

This is the System keychain, so it covers **Safari, Chrome and macOS
`curl`** (they all use the system trust store).

**Firefox** keeps its own store: Settings → Privacy & Security →
Certificates → View Certificates → Authorities → Import → `ca.crt` →
tick "Trust this CA to identify websites".

Verify trust works (must succeed **without** `-k` and **without** `--cacert`):

```bash
curl -v https://app.team1.test/api/status
# look for:  SSL certificate verify ok
```

## Remove trust again (after the project)

```bash
sudo security delete-certificate -c "team1 Local Root CA" \
     /Library/Keychains/System.keychain
```

## Security notes for the viva

* `ca.key` and `edge.key` never leave the machine that needs them; only
  `ca.crt` is distributed. (A CA key can mint trusted certs for *any*
  name — that's why real CAs guard theirs in HSMs.)
* The demo must not use `curl -k` — bypassing validation defeats the
  entire purpose of TLS (the brief explicitly forbids it).
* TLS terminates **at the edge**; edge→backend hops are plain HTTP on a
  private, firewall-isolated LAN segment (Phase 2 Extension C restricts
  who can even reach those ports). Real clouds do the same thing inside
  a VPC, or re-encrypt (end-to-end TLS) when compliance demands it.

## The handshake you must be able to explain (Wireshark, Task G)

```
Client                                  nginx (Mac 2)
  │── ClientHello ─────────────────────────►│  supported TLS versions, cipher
  │                                         │  suites, SNI = app.team1.test,
  │                                         │  client random
  │◄───────────── ServerHello ──────────────│  chosen version + cipher,
  │◄───────────── Certificate ──────────────│  server random; edge cert + CA
  │◄───────────── (KeyExchange/ServerHelloDone or TLS1.3 EncryptedExtensions…)
  │   client validates: signature by trusted CA? name matches SNI? not expired?
  │── key-share / premaster ───────────────►│  both derive the SAME session keys
  │── ChangeCipherSpec + Finished ─────────►│  (in TLS 1.3 a compatibility CCS
  │◄───────────── Finished ─────────────────│   may appear unencrypted)
  │== encrypted HTTP request/response ======│  Wireshark now shows only
                                            │  "Application Data"
```
