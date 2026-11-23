#!/usr/bin/env bash
# =====================================================================
#  configure.sh — regenerates every machine-ready file under deploy/
#  from config.env + templates/.  Run this ONCE after editing config.env
#  (and again whenever an IP / port / team name changes).
#
#    ./scripts/configure.sh
#
#  Outputs:
#    deploy/mac1/dnsmasq.conf                 (primary DNS — Task B)
#    deploy/backup-dns/dnsmasq-backup.conf    (backup DNS — Extension A)
#    deploy/mac2/nginx.conf                   (edge — Tasks D/E; two
#                                              placeholders are finalized
#                                              on Mac 2 by mac2-edge.sh)
#    deploy/firewall/backend-isolation.pf.conf(Extension C)
#    deploy/local/...                         (single-machine practice
#                                              simulation — practice/)
# =====================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=../config.env
source config.env

# ---- sanity checks ---------------------------------------------------
if ! printf '%s' "$TEAM" | grep -Eq '^[a-z0-9]+$'; then
    echo "ERROR: TEAM must be lowercase alphanumeric (e.g. team1). Got: '$TEAM'" >&2
    exit 1
fi
for v in MAC1_IP MAC2_IP MAC3_IP MAC4_IP DNS_BACKUP_IP; do
    val="${!v}"
    if ! printf '%s' "$val" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
        echo "ERROR: $v='$val' is not a valid IPv4 address. Edit config.env." >&2
        exit 1
    fi
done
if [ "$DNS_BACKUP_IP" = "$MAC1_IP" ]; then
    echo "ERROR: DNS_BACKUP_IP must NOT be Mac 1 (the whole point of Extension A)." >&2
    exit 1
fi

RUN_DIR="/tmp/${TEAM}-run"
RUN_DIR_LOCAL="$RUN_DIR/local"
mkdir -p "$RUN_DIR" "$RUN_DIR_LOCAL" \
         deploy/mac1 deploy/backup-dns deploy/mac2 deploy/mac3 deploy/mac4 \
         deploy/firewall deploy/local deploy/mac2/certs \
         evidence/dns evidence/tcp evidence/tls evidence/http \
         evidence/load-balancing evidence/caching evidence/failures evidence/phase2

if [ "$HTTPS_PORT" = "443" ]; then HTTPS_PORT_SUFFIX=""; else HTTPS_PORT_SUFFIX=":${HTTPS_PORT}"; fi

# ---- stamping function ----------------------------------------------
# Replaces every {{PLACEHOLDER}} with real values. {{CERT_DIR}} and
# {{MIME_TYPES}} are deliberately LEFT for mac2-edge.sh / run-local.sh,
# because only the machine that runs nginx knows its own repo path,
# Homebrew prefix and OpenSSL layout.
stamp() {
    src="$1"; dst="$2"; shift 2
    _run_dir="$RUN_DIR"; _mac1="$MAC1_IP"; _mac2="$MAC2_IP"; _mac3="$MAC3_IP"
    _mac4="$MAC4_IP"; _backup="$DNS_BACKUP_IP"; _suffix="$HTTPS_PORT_SUFFIX"
    # local-mode overrides passed as KEY=VALUE extras
    for kv in "$@"; do
        case "$kv" in
            RUN_DIR=*)        _run_dir="${kv#*=}" ;;
            MAC1_IP=*)        _mac1="${kv#*=}" ;;
            MAC2_IP=*)        _mac2="${kv#*=}" ;;
            MAC3_IP=*)        _mac3="${kv#*=}" ;;
            MAC4_IP=*)        _mac4="${kv#*=}" ;;
            DNS_BACKUP_IP=*)  _backup="${kv#*=}" ;;
        esac
    done
    sed -e "s|{{TEAM}}|$TEAM|g" \
        -e "s|{{MAC1_IP}}|$_mac1|g" \
        -e "s|{{MAC2_IP}}|$_mac2|g" \
        -e "s|{{MAC3_IP}}|$_mac3|g" \
        -e "s|{{MAC4_IP}}|$_mac4|g" \
        -e "s|{{DNS_BACKUP_IP}}|$_backup|g" \
        -e "s|{{DNS_PORT}}|$DNS_PORT|g" \
        -e "s|{{BACKEND_A_PORT}}|$BACKEND_A_PORT|g" \
        -e "s|{{BACKEND_B_PORT}}|$BACKEND_B_PORT|g" \
        -e "s|{{HTTPS_PORT}}|$HTTPS_PORT|g" \
        -e "s|{{HTTPS_ALT_PORT}}|$HTTPS_ALT_PORT|g" \
        -e "s|{{HTTP_PORT}}|$HTTP_PORT|g" \
        -e "s|{{HTTP_ALT_PORT}}|$HTTP_ALT_PORT|g" \
        -e "s|{{DNS_TTL}}|$DNS_TTL|g" \
        -e "s|{{RUN_DIR}}|$_run_dir|g" \
        -e "s|{{HTTPS_PORT_SUFFIX}}|$_suffix|g" \
        "$src" > "$dst"
    echo "  wrote $dst"
}

echo "==> Stamping REAL deployment configs (from config.env)"
stamp templates/dnsmasq.conf.tmpl            deploy/mac1/dnsmasq.conf
stamp templates/dnsmasq-backup.conf.tmpl     deploy/backup-dns/dnsmasq-backup.conf
stamp templates/nginx.conf.tmpl              deploy/mac2/nginx.conf
stamp templates/backend-isolation.pf.conf.tmpl deploy/firewall/backend-isolation.pf.conf

echo "==> Stamping LOCAL practice-mode configs (everything on 127.0.0.x)"
LOCAL_OVERRIDES="RUN_DIR=$RUN_DIR_LOCAL MAC1_IP=127.0.0.1 MAC2_IP=127.0.0.1 MAC3_IP=127.0.0.1 MAC4_IP=127.0.0.1 DNS_BACKUP_IP=127.0.0.2"
# shellcheck disable=SC2086
stamp templates/dnsmasq.conf.tmpl        deploy/local/dnsmasq.conf        $LOCAL_OVERRIDES
# shellcheck disable=SC2086
stamp templates/dnsmasq-backup.conf.tmpl deploy/local/dnsmasq-backup.conf $LOCAL_OVERRIDES
# shellcheck disable=SC2086
stamp templates/nginx.conf.tmpl          deploy/local/nginx.conf          $LOCAL_OVERRIDES

# convenience copies for the backend machines (they only need the repo,
# but keeping a per-machine folder makes the deliverable obvious)
cp deploy/mac1/dnsmasq.conf deploy/mac3/ 2>/dev/null || true

cat <<EOF

============================================================
 configure.sh done.

   Team domain      : app.${TEAM}.test / api.${TEAM}.test
   Mac 1 (DNS)      : ${MAC1_IP}   -> deploy/mac1/dnsmasq.conf
   Mac 2 (edge)     : ${MAC2_IP}   -> deploy/mac2/nginx.conf
   Mac 3 (backendA) : ${MAC3_IP}   : ${BACKEND_A_PORT}
   Mac 4 (backendB) : ${MAC4_IP}   : ${BACKEND_B_PORT}
   Backup DNS (P2)  : ${DNS_BACKUP_IP} -> deploy/backup-dns/dnsmasq-backup.conf
   Runtime dir      : ${RUN_DIR}

 Next steps:
   1. ./certs/make-ca-and-cert.sh          (build the local CA + edge cert)
   2. Copy this whole repo folder to every Mac
   3. Mac 1: ./scripts/mac1-dns.sh
      Mac 2: ./scripts/mac2-edge.sh
      Mac 3: ./scripts/mac3-backend-a.sh
      Mac 4: ./scripts/mac4-backend-b.sh
   4. From a client Mac: ./scripts/verify.sh

 Want to rehearse everything on ONE machine first?
   ./practice/run-local.sh
============================================================
EOF
