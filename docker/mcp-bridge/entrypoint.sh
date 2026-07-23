#!/bin/bash
set -euo pipefail

: "${MCP_BEARER_TOKEN:?MCP_BEARER_TOKEN must be set}"
SSH_CONFIG_FILE="${SSH_CONFIG_FILE:-/config/ssh-config.json}"
PORT="${PORT:-8000}"
INTERNAL_PORT="${INTERNAL_PORT:-8001}"
OUTPUT_TRANSPORT="${OUTPUT_TRANSPORT:-sse}"

if [ ! -f "${SSH_CONFIG_FILE}" ]; then
  echo "[mcp-bridge] ERROR: SSH config file not found at ${SSH_CONFIG_FILE}" >&2
  echo "[mcp-bridge] Mount your config/ssh-config.json into the container." >&2
  exit 1
fi

echo "[mcp-bridge] starting ssh-mcp-server via supergateway (internal port ${INTERNAL_PORT}, transport ${OUTPUT_TRANSPORT})"
npx --no-install supergateway \
  --stdio "npx --no-install ssh-mcp-server --config-file ${SSH_CONFIG_FILE}" \
  --outputTransport "${OUTPUT_TRANSPORT}" \
  --port "${INTERNAL_PORT}" \
  --baseUrl "http://127.0.0.1:${INTERNAL_PORT}" \
  --healthEndpoint /healthz \
  --cors &
SUPERGATEWAY_PID=$!

echo "[mcp-bridge] starting auth proxy on 0.0.0.0:${PORT}"
PORT="${PORT}" INTERNAL_PORT="${INTERNAL_PORT}" MCP_BEARER_TOKEN="${MCP_BEARER_TOKEN}" \
  node /app/auth-proxy.js &
PROXY_PID=$!

trap 'kill -TERM ${SUPERGATEWAY_PID} ${PROXY_PID} 2>/dev/null || true' TERM INT

# If either process dies, bring the container down so the orchestrator restarts it.
wait -n "${SUPERGATEWAY_PID}" "${PROXY_PID}"
EXIT_CODE=$?
echo "[mcp-bridge] a child process exited (code ${EXIT_CODE}), shutting down"
kill -TERM "${SUPERGATEWAY_PID}" "${PROXY_PID}" 2>/dev/null || true
exit "${EXIT_CODE}"
