#!/usr/bin/env bash
# =====================================================================
#  practice/stop-local.sh — stop every service started by run-local.sh
# =====================================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
QUIET=0; [ "${1:-}" = "--quiet" ] && QUIET=1
source "$REPO_ROOT/scripts/common.sh"

kill_pidfile() {  # kill_pidfile <pidfile> <label> <use-sudo>
    local pf="$1" label="$2" use_sudo="${3:-0}"
    if [ -f "$pf" ]; then
        local pid; pid="$(cat "$pf")"
        # NOTE: plain `kill -0` fails with EPERM on root-owned processes —
        # for sudo services we must probe (and kill) via sudo.
        if [ "$use_sudo" = "1" ]; then
            if sudo kill -0 "$pid" 2>/dev/null; then
                sudo kill "$pid" 2>/dev/null || true
                [ "$QUIET" = 0 ] && echo "  stopped $label (pid $pid)"
            fi
        else
            if kill -0 "$pid" 2>/dev/null; then
                kill "$pid" 2>/dev/null || true
                [ "$QUIET" = 0 ] && echo "  stopped $label (pid $pid)"
            fi
        fi
    fi
    rm -f "$pf"
}

# nginx first (it proxies to the backends)
if [ -f "$RUN_DIR_LOCAL/nginx.pid" ] && sudo kill -0 "$(cat "$RUN_DIR_LOCAL/nginx.pid")" 2>/dev/null; then
    NGINX_BIN="$(command -v nginx || echo /usr/sbin/nginx)"
    for c in /opt/homebrew/bin/nginx /usr/local/bin/nginx /usr/sbin/nginx; do [ -x "$c" ] && NGINX_BIN="$c" && break; done
    sudo "$NGINX_BIN" -c "$RUN_DIR_LOCAL/nginx.conf" -s stop 2>/dev/null || sudo kill "$(cat "$RUN_DIR_LOCAL/nginx.pid")" 2>/dev/null
    [ "$QUIET" = 0 ] && echo "  stopped nginx edge"
fi
rm -f "$RUN_DIR_LOCAL/nginx.pid"
kill_pidfile "$RUN_DIR_LOCAL/dnsmasq.pid" "dnsmasq primary" 1
kill_pidfile "$RUN_DIR_LOCAL/dnsmasq-backup.pid" "dnsmasq backup" 1
kill_pidfile "$RUN_DIR_LOCAL/backend-a.pid" "Backend A" 0
kill_pidfile "$RUN_DIR_LOCAL/backend-b.pid" "Backend B" 0
# belt & braces (e.g. if pid files were lost)
pkill -f "backend.py --name [AB] --port" 2>/dev/null || true
sleep 1
[ "$QUIET" = 0 ] && echo "  local simulation fully stopped."
exit 0
