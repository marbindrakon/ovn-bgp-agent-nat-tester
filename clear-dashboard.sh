#!/usr/bin/env bash
# Clear all heartbeat state from the dashboard.
set -euo pipefail

# Source local configuration (API keys, etc.)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=local-config.env
source "${SCRIPT_DIR}/local-config.env"

DASHBOARD_URL="${DASHBOARD_URL:-https://snat-heartbeat.apps.lab-hub.lab.signal9.gg}"

if [[ -z "${DASHBOARD_API_KEY:-}" ]]; then
    echo "Error: DASHBOARD_API_KEY is not set in local-config.env." >&2
    exit 1
fi

echo "Clearing dashboard state at ${DASHBOARD_URL}..."
response=$(curl -s -w '\n%{http_code}' -X POST \
    -H "X-API-Key: ${DASHBOARD_API_KEY}" \
    "${DASHBOARD_URL}/clear")

http_code=$(echo "$response" | tail -1)
body=$(echo "$response" | head -n -1)

if [[ "$http_code" == "200" ]]; then
    echo "Dashboard cleared."
else
    echo "Failed (HTTP ${http_code}): ${body}" >&2
    exit 1
fi
