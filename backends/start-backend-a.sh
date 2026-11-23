#!/usr/bin/env bash
# Start Backend A — run this on Mac 3.   (Task C)
# Foreground on purpose: you SEE every request log line during the demo,
# including the client's ephemeral port (socket-pair evidence).
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config.env
source "$REPO/config.env"

echo "[backend-a] starting on port ${BACKEND_A_PORT} (LAN-reachable, 0.0.0.0)"
exec python3 "$REPO/backends/backend.py" --name A --port "$BACKEND_A_PORT"
