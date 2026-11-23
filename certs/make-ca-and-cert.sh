#!/usr/bin/env bash
# =====================================================================
#  make-ca-and-cert.sh — Task E: build the team's LOCAL Certificate
#  Authority and the edge server certificate signed by it.
#
#  Why a local CA instead of a bare self-signed certificate?
#    * One CA cert can be trusted once on every client machine, and it
#      can sign certs for ANY number of names (app, api, standby edge).
#    * It mirrors how the real PKI works: a CA signs, servers present
#      cert+chain, clients validate the chain against trusted roots.
#
#  Outputs (deploy/mac2/certs/):
#    ca.key / ca.crt                  — the CA (keep ca.key SECRET;
#                                       ca.crt goes to every client)
#    edge.key / edge.crt              — server key + certificate
#    edge-fullchain.crt               — edge.crt + ca.crt (nginx serves this)
#
#  Works with macOS system OpenSSL (LibreSSL), Homebrew OpenSSL 3 and Linux.
# =====================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../config.env
source "$REPO_ROOT/config.env"

DOMAIN="${TEAM}.test"
OUT="$REPO_ROOT/deploy/mac2/certs"
mkdir -p "$OUT"

# Prefer real OpenSSL if Homebrew has it (macOS ships LibreSSL by default;
# both work with this script, but OpenSSL 3 is nicer).
OPENSSL="$(command -v openssl)"
for cand in /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl; do
    [ -x "$cand" ] && OPENSSL="$cand" && break
done
echo "==> Using: $OPENSSL ($("$OPENSSL" version 2>&1 | head -1))"

DAYS_CA=1825    # CA validity: 5 years
DAYS_SRV=825    # server cert: 825 days — the MAXIMUM macOS will accept
                # for TLS server certificates (longer => trust errors!)

# ---- 1. Root CA ------------------------------------------------------
echo "==> Generating CA key + self-signed CA certificate"
"$OPENSSL" genrsa -out "$OUT/ca.key" 4096 2>/dev/null
"$OPENSSL" req -x509 -new -nodes -key "$OUT/ca.key" -sha256 -days "$DAYS_CA" \
    -out "$OUT/ca.crt" \
    -subj "/O=${TEAM} CN Course Project/CN=${TEAM} Local Root CA"

# ---- 2. Server key + CSR ---------------------------------------------
echo "==> Generating edge server key + CSR (CN=app.${DOMAIN})"
"$OPENSSL" genrsa -out "$OUT/edge.key" 2048 2>/dev/null
"$OPENSSL" req -new -key "$OUT/edge.key" -out "$OUT/edge.csr" \
    -subj "/O=${TEAM} CN Course Project/CN=app.${DOMAIN}"

# ---- 3. Extension file with SANs --------------------------------------
# Modern clients IGNORE the CN and require subjectAltName. The wildcard
# *.DOMAIN lets the same cert serve the standby edge in Phase 2 (Ext. E).
cat > "$OUT/edge-ext.cnf" <<EOF
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = app.${DOMAIN}
DNS.2 = api.${DOMAIN}
DNS.3 = *.${DOMAIN}
DNS.4 = ${DOMAIN}
IP.1  = ${MAC2_IP}
IP.2  = 127.0.0.1
EOF

# ---- 4. Sign the server cert with our CA -------------------------------
echo "==> Signing edge certificate with the local CA"
"$OPENSSL" x509 -req -in "$OUT/edge.csr" \
    -CA "$OUT/ca.crt" -CAkey "$OUT/ca.key" -CAcreateserial \
    -out "$OUT/edge.crt" -days "$DAYS_SRV" -sha256 \
    -extfile "$OUT/edge-ext.cnf" 2>/dev/null

# ---- 5. Full chain for nginx (server cert + issuing CA) ----------------
cat "$OUT/edge.crt" "$OUT/ca.crt" > "$OUT/edge-fullchain.crt"

chmod 600 "$OUT"/*.key

# ---- 6. Self-verify + summary ------------------------------------------
echo
echo "==> Verification:"
"$OPENSSL" verify -CAfile "$OUT/ca.crt" "$OUT/edge.crt"
"$OPENSSL" x509 -in "$OUT/edge.crt" -noout -subject -issuer -dates
echo "    Subject Alternative Names:"
"$OPENSSL" x509 -in "$OUT/edge.crt" -noout -text \
    | grep -A1 "Subject Alternative Name" | tail -1 | sed 's/^ */      /'

cat <<EOF

============================================================
 Certificates ready in: deploy/mac2/certs/

   ca.crt              -> TRUST THIS on every client Mac:
       sudo security add-trusted-cert -d -r trustRoot \\
            -k /Library/Keychains/System.keychain \\
            "$OUT/ca.crt"
   edge-fullchain.crt  -> nginx ssl_certificate
   edge.key            -> nginx ssl_certificate_key (NEVER share)

 Full instructions: certs/README.md
============================================================
EOF
