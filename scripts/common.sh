#!/usr/bin/env bash
# =====================================================================
#  Shared helpers — sourced by the other scripts (not run directly).
# =====================================================================
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../config.env
source "$REPO_ROOT/config.env"

DOMAIN="${TEAM}.test"
APP_HOST="app.${DOMAIN}"
API_HOST="api.${DOMAIN}"

# Runtime dir (matches what configure.sh stamps into the configs):
RUN_DIR="/tmp/${TEAM}-run"
RUN_DIR_LOCAL="/tmp/${TEAM}-run/local"
CERT_DIR="$REPO_ROOT/deploy/mac2/certs"
CA_CERT="$CERT_DIR/ca.crt"
mkdir -p "$RUN_DIR" "$RUN_DIR_LOCAL"

# URL port suffixes ("" for the default ports so URLs stay clean)
if [ "$HTTPS_PORT" = "443" ]; then HTTPS_PORT_SUFFIX=""; else HTTPS_PORT_SUFFIX=":${HTTPS_PORT}"; fi
if [ "$HTTP_PORT"  = "80"  ]; then HTTP_PORT_SUFFIX="";  else HTTP_PORT_SUFFIX=":${HTTP_PORT}";  fi

EDGE_BASE="https://${APP_HOST}${HTTPS_PORT_SUFFIX}"

# Which DNS server do we query in demos/tests? (override with DNS_SERVER=...)
DNS_SERVER="${DNS_SERVER:-$MAC1_IP}"

# curl trust mode:
#   SYSTEM_TRUST=1 -> rely on the CA installed in the OS keychain/trust store
#                     (this is what the graded demo MUST use — no flags!)
#   otherwise      -> pin the CA file explicitly with --cacert (handy when
#                     testing from a machine that hasn't trusted the CA yet)
if [ "${SYSTEM_TRUST:-0}" = "1" ]; then
    CURL_TLS_OPTS=""
else
    CURL_TLS_OPTS="--cacert $CA_CERT"
fi
# Optional: force name resolution for curl (bypasses system DNS; used by
# the local simulation and by tests run from machines not pointed at Mac 1)
CURL_RESOLVE="${CURL_RESOLVE:-}"

curl_edge() {
    # curl_edge <curl args...> — adds trust/resolve/timeout defaults
    # shellcheck disable=SC2086
    curl --max-time 8 $CURL_TLS_OPTS $CURL_RESOLVE "$@"
}

# Pretty output
if [ -t 1 ]; then
    c_red=$'\033[31m'; c_green=$'\033[32m'; c_yellow=$'\033[33m'
    c_blue=$'\033[34m'; c_bold=$'\033[1m'; c_off=$'\033[0m'
else
    c_red=""; c_green=""; c_yellow=""; c_blue=""; c_bold=""; c_off=""
fi
FAILURES=0
step() { printf '\n%s==>%s %s%s%s\n' "$c_blue" "$c_off" "$c_bold" "$*" "$c_off"; }
info() { printf '  %s\n' "$*"; }
ok()   { printf '  %s[PASS]%s %s\n' "$c_green" "$c_off" "$*"; }
warn() { printf '  %s[WARN]%s %s\n' "$c_yellow" "$c_off" "$*"; }
fail() { printf '  %s[FAIL]%s %s\n' "$c_red" "$c_off" "$*"; FAILURES=$((FAILURES+1)); }
note() { printf '  %s›%s %s\n' "$c_yellow" "$c_off" "$*"; }
pause() { [ "${AUTO:-0}" = "1" ] || read -r -p "  -- press Enter to continue --" _; }
have() { command -v "$1" >/dev/null 2>&1; }

summary() {
    echo
    if [ "$FAILURES" -eq 0 ]; then
        printf '%sALL CHECKS PASSED%s\n' "$c_green$c_bold" "$c_off"
    else
        printf '%s%s CHECK(S) FAILED%s — see the output above\n' "$c_red$c_bold" "$FAILURES" "$c_off"
    fi
    return "$FAILURES"
}
