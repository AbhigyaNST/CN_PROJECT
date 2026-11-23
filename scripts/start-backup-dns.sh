#!/usr/bin/env bash
# =====================================================================
#  Phase 2, Extension A — start the BACKUP DNS resolver.
#  Run on the machine with IP = DNS_BACKUP_IP (default: Mac 3).
#
#    ./scripts/start-backup-dns.sh            # daemon (background)
#    ./scripts/start-backup-dns.sh --fg       # foreground (see queries live)
#    ./scripts/start-backup-dns.sh --local    # single-machine sim instance
#    ./scripts/start-backup-dns.sh --stop     # stop the backup instance
# =====================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

MODE="daemon"; CONF="$REPO_ROOT/deploy/backup-dns/dnsmasq-backup.conf"; RUNDIR="$RUN_DIR"
for arg in "$@"; do
    case "$arg" in
        --fg)     MODE="fg" ;;
        --local)  CONF="$REPO_ROOT/deploy/local/dnsmasq-backup.conf"; RUNDIR="$RUN_DIR_LOCAL" ;;
        --stop)   MODE="stop" ;;
    esac
done

BREW_PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
if have dnsmasq; then DNSMASQ_BIN="$(command -v dnsmasq)"
elif [ -x "$BREW_PREFIX/sbin/dnsmasq" ]; then DNSMASQ_BIN="$BREW_PREFIX/sbin/dnsmasq"
else echo "dnsmasq not found (brew install dnsmasq)." >&2; exit 1; fi

PIDFILE="$RUNDIR/dnsmasq-backup.pid"

if [ "$MODE" = "stop" ]; then
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        sudo kill "$(cat "$PIDFILE")" && echo "[backup-dns] stopped (pid $(cat "$PIDFILE"))"
    else
        echo "[backup-dns] not running (no live pid at $PIDFILE)"
    fi
    exit 0
fi

[ -f "$CONF" ] || { echo "Missing $CONF — run ./scripts/configure.sh first." >&2; exit 1; }
mkdir -p "$RUNDIR"

echo "[backup-dns] starting: $CONF"
if [ "$MODE" = "fg" ]; then
    exec sudo "$DNSMASQ_BIN" --conf-file="$CONF" -d
else
    [ -f "$PIDFILE" ] && sudo kill "$(cat "$PIDFILE")" 2>/dev/null || true
    sudo "$DNSMASQ_BIN" --conf-file="$CONF"
    sleep 1
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        echo "[backup-dns] running (pid $(cat "$PIDFILE")), log: $RUNDIR/dnsmasq-backup-queries.log"
        echo "[backup-dns] test:  dig @${DNS_BACKUP_IP} app.${DOMAIN}"
    else
        echo "[backup-dns] FAILED to start — port 53 busy? check: sudo lsof -nP -iUDP:53" >&2
        exit 1
    fi
fi
