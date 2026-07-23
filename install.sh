#!/usr/bin/env bash
#
# ssh-mcp-stack installer
#
# Usage (recommended, preserves interactive prompts even when piped through curl):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/10bn/ssh-mcp-stack/main/install.sh)"
#
# Non-interactive usage: set the SSH_*/TUNNEL_*/CLOUDFLARE_* env vars documented
# in README.md and export STACK_NONINTERACTIVE=1 before running.

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/10bn/ssh-mcp-stack.git}"
STACK_DIR="${STACK_DIR:-$HOME/ssh-mcp-stack}"
RECONFIGURE="${STACK_RECONFIGURE:-0}"
NONINTERACTIVE="${STACK_NONINTERACTIVE:-0}"

log()  { printf '\033[1;34m[install]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[install][warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[install][error]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 0. Input helper: reads from /dev/tty when interactive, otherwise falls back
#    to an already-set environment variable, otherwise fails with guidance.
# ---------------------------------------------------------------------------
prompt() {
  local var_name="$1" question="$2" default_value="${3:-}"
  local current_value="${!var_name:-}"
  local answer

  if [ -n "$current_value" ]; then
    return 0
  fi

  if [ "$NONINTERACTIVE" = "1" ] || [ ! -e /dev/tty ]; then
    if [ -n "$default_value" ]; then
      printf -v "$var_name" '%s' "$default_value"
      return 0
    fi
    die "Missing required value for \$$var_name. Export it and re-run, or drop STACK_NONINTERACTIVE for an interactive install."
  fi

  if [ -n "$default_value" ]; then
    read -r -p "$question [$default_value]: " answer < /dev/tty
    answer="${answer:-$default_value}"
  else
    read -r -p "$question: " answer < /dev/tty
  fi
  printf -v "$var_name" '%s' "$answer"
}

prompt_secret() {
  local var_name="$1" question="$2"
  local current_value="${!var_name:-}"
  local answer

  if [ -n "$current_value" ]; then
    return 0
  fi

  if [ "$NONINTERACTIVE" = "1" ] || [ ! -e /dev/tty ]; then
    return 0
  fi

  read -r -s -p "$question: " answer < /dev/tty
  echo >&2
  printf -v "$var_name" '%s' "$answer"
}

prompt_yes_no() {
  local question="$1" answer
  if [ "$NONINTERACTIVE" = "1" ] || [ ! -e /dev/tty ]; then
    echo "n"
    return 0
  fi
  read -r -p "$question [y/N]: " answer < /dev/tty
  echo "${answer:-n}"
}

# ---------------------------------------------------------------------------
# 1. Prerequisites
# ---------------------------------------------------------------------------
command -v docker >/dev/null 2>&1 || die "Docker is required. Install it first: https://docs.docker.com/engine/install/"
docker compose version >/dev/null 2>&1 || die "The 'docker compose' plugin is required (Docker Compose v2). See: https://docs.docker.com/compose/install/"
command -v git >/dev/null 2>&1 || die "git is required."

# ---------------------------------------------------------------------------
# 2. Fetch/update the repo
# ---------------------------------------------------------------------------
if [ -d "$STACK_DIR/.git" ]; then
  log "Found existing checkout at $STACK_DIR, updating..."
  git -C "$STACK_DIR" fetch --quiet origin
  if [ -n "$(git -C "$STACK_DIR" status --porcelain)" ]; then
    warn "Local changes detected in $STACK_DIR, skipping 'git pull' to avoid clobbering them."
  else
    git -C "$STACK_DIR" pull --quiet --ff-only
  fi
else
  log "Cloning $REPO_URL into $STACK_DIR..."
  git clone --quiet "$REPO_URL" "$STACK_DIR"
fi

cd "$STACK_DIR"
mkdir -p config secrets

# ---------------------------------------------------------------------------
# 3. Configuration wizard (skipped if .env already exists, unless STACK_RECONFIGURE=1)
# ---------------------------------------------------------------------------
if [ -f .env ] && [ "$RECONFIGURE" != "1" ]; then
  log ".env already exists, keeping current configuration (set STACK_RECONFIGURE=1 to redo the wizard)."
  # shellcheck disable=SC1091
  set -a; source .env; set +a
else
  log "Configuring your SSH MCP stack..."

  prompt SSH_HOST "SSH target host or IP"
  prompt SSH_PORT "SSH target port" "22"
  prompt SSH_USER "SSH username"
  prompt SSH_AUTH_METHOD "Auth method (password/key)" "key"

  SSH_PASSWORD="${SSH_PASSWORD:-}"
  SSH_PRIVATE_KEY_PATH="${SSH_PRIVATE_KEY_PATH:-}"
  SSH_PASSPHRASE="${SSH_PASSPHRASE:-}"

  if [ "$SSH_AUTH_METHOD" = "password" ]; then
    prompt_secret SSH_PASSWORD "SSH password"
    [ -n "$SSH_PASSWORD" ] || die "SSH_PASSWORD is required for auth method 'password'."
  else
    prompt SSH_PRIVATE_KEY_PATH "Path to private key on THIS machine" "$HOME/.ssh/id_ed25519"
    [ -f "$SSH_PRIVATE_KEY_PATH" ] || die "Private key not found at $SSH_PRIVATE_KEY_PATH"
    prompt_secret SSH_PASSPHRASE "Private key passphrase (leave empty if none)"
    cp "$SSH_PRIVATE_KEY_PATH" ./secrets/id_key
    chmod 600 ./secrets/id_key
  fi

  prompt COMMAND_WHITELIST "Command whitelist, comma-separated regexes (STRONGLY recommended)" "^ls( .*)?,^cat .*,^df.*,^systemctl status .*"
  if [ -z "$COMMAND_WHITELIST" ]; then
    warn "No command whitelist configured. ANY command will be executable on $SSH_HOST through this MCP server."
    confirm=$(prompt_yes_no "Type y to continue anyway with no whitelist")
    [ "$confirm" = "y" ] || die "Aborted. Re-run and provide a whitelist."
  fi

  prompt ALLOWED_REMOTE_PATHS "Allowed remote paths for upload/download, comma-separated absolute paths" "/var/www,/var/log"
  if [ -z "$ALLOWED_REMOTE_PATHS" ]; then
    warn "No allowedRemotePaths configured. SFTP upload/download will accept ANY remote path (e.g. ~/.ssh/authorized_keys)."
    confirm=$(prompt_yes_no "Type y to continue anyway")
    [ "$confirm" = "y" ] || die "Aborted. Re-run and provide allowed remote paths."
  fi

  prompt TUNNEL_MODE "Tunnel mode (quick = no account needed / named = stable hostname)" "quick"
  CLOUDFLARE_TUNNEL_TOKEN="${CLOUDFLARE_TUNNEL_TOKEN:-}"
  CLOUDFLARE_TUNNEL_HOSTNAME="${CLOUDFLARE_TUNNEL_HOSTNAME:-}"
  if [ "$TUNNEL_MODE" = "named" ]; then
    log "Create a tunnel in the Cloudflare Zero Trust dashboard (Networks > Tunnels), set its public"
    log "hostname's service to http://mcp-bridge:8000, then paste the tunnel token below."
    prompt CLOUDFLARE_TUNNEL_TOKEN "Cloudflare tunnel token"
    prompt CLOUDFLARE_TUNNEL_HOSTNAME "Public hostname you configured for the tunnel"
  fi

  MCP_BEARER_TOKEN="${MCP_BEARER_TOKEN:-}"
  if [ -z "$MCP_BEARER_TOKEN" ]; then
    MCP_BEARER_TOKEN=$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
  fi

  cat > .env <<EOF
MCP_BEARER_TOKEN=${MCP_BEARER_TOKEN}
MCP_OUTPUT_TRANSPORT=sse
TUNNEL_MODE=${TUNNEL_MODE}
CLOUDFLARE_TUNNEL_TOKEN=${CLOUDFLARE_TUNNEL_TOKEN}
CLOUDFLARE_TUNNEL_HOSTNAME=${CLOUDFLARE_TUNNEL_HOSTNAME}
EOF

  # Build ssh-config.json for a single "default" connection.
  WHITELIST_JSON="[]"
  if [ -n "$COMMAND_WHITELIST" ]; then
    WHITELIST_JSON=$(printf '%s' "$COMMAND_WHITELIST" | awk -F',' '{
      printf "["; for (i=1;i<=NF;i++){printf "%s\"%s\"", (i>1?",":""), $i}; printf "]"
    }')
  fi
  PATHS_JSON="[]"
  if [ -n "$ALLOWED_REMOTE_PATHS" ]; then
    PATHS_JSON=$(printf '%s' "$ALLOWED_REMOTE_PATHS" | awk -F',' '{
      printf "["; for (i=1;i<=NF;i++){printf "%s\"%s\"", (i>1?",":""), $i}; printf "]"
    }')
  fi

  json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
  }

  if [ "$SSH_AUTH_METHOD" = "password" ]; then
    AUTH_JSON="\"password\": \"$(json_escape "$SSH_PASSWORD")\""
  else
    AUTH_JSON="\"privateKey\": \"/secrets/id_key\""
    if [ -n "$SSH_PASSPHRASE" ]; then
      AUTH_JSON="${AUTH_JSON}, \"passphrase\": \"$(json_escape "$SSH_PASSPHRASE")\""
    fi
  fi

  cat > config/ssh-config.json <<EOF
[
  {
    "name": "default",
    "host": "${SSH_HOST}",
    "port": ${SSH_PORT},
    "username": "${SSH_USER}",
    ${AUTH_JSON},
    "commandWhitelist": ${WHITELIST_JSON},
    "allowedRemotePaths": ${PATHS_JSON}
  }
]
EOF

  chmod 600 .env config/ssh-config.json
  log "Wrote .env and config/ssh-config.json"
fi

# ---------------------------------------------------------------------------
# 4. Bring the stack up
# ---------------------------------------------------------------------------
log "Building and starting the stack (docker compose up -d --build)..."
docker compose up -d --build

log "Waiting for mcp-bridge to become healthy..."
for _ in $(seq 1 30); do
  status=$(docker inspect --format '{{.State.Health.Status}}' ssh-mcp-bridge 2>/dev/null || echo "starting")
  [ "$status" = "healthy" ] && break
  sleep 2
done
if [ "${status:-}" != "healthy" ]; then
  warn "mcp-bridge did not report healthy in time. Check logs with: docker compose logs mcp-bridge"
fi

# ---------------------------------------------------------------------------
# 5. Report the public URL
# ---------------------------------------------------------------------------
PUBLIC_URL=""
if [ "${TUNNEL_MODE:-quick}" = "named" ]; then
  PUBLIC_URL="https://${CLOUDFLARE_TUNNEL_HOSTNAME}"
else
  log "Waiting for cloudflared to hand out a trycloudflare.com URL..."
  for _ in $(seq 1 15); do
    PUBLIC_URL=$(docker compose logs cloudflared 2>/dev/null | grep -Eo 'https://[a-zA-Z0-9.-]+\.trycloudflare\.com' | tail -1 || true)
    [ -n "$PUBLIC_URL" ] && break
    sleep 2
  done
fi

echo
log "Deployment complete."
if [ -n "$PUBLIC_URL" ]; then
  echo
  echo "  Public MCP endpoint : ${PUBLIC_URL}/sse"
  echo "  Bearer token         : $(grep '^MCP_BEARER_TOKEN=' .env | cut -d= -f2-)"
  echo
  echo "  Add this as a remote MCP connector, e.g.:"
  echo '  {'
  echo '    "url": "'"${PUBLIC_URL}"'/sse",'
  echo '    "headers": { "Authorization": "Bearer '"$(grep '^MCP_BEARER_TOKEN=' .env | cut -d= -f2-)"'" }'
  echo '  }'
else
  warn "Could not determine the public URL yet. Check it with: docker compose logs cloudflared"
fi
echo
echo "  Useful commands:"
echo "    docker compose logs -f          # follow logs"
echo "    docker compose restart          # restart the stack"
echo "    STACK_RECONFIGURE=1 bash install.sh   # redo the setup wizard"
