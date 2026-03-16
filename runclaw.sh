#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# OpenClaw Run Script
# One-click: validate .env → fix permissions → restart docker
#            → configure LLM → health check → login → pairing
# Usage: chmod +x runclaw.sh && ./runclaw.sh
#        ./runclaw.sh stop    — stop all running containers
#        ./runclaw.sh update  — force re-run all steps (no skip)
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ----------------------------------------------------------
# Handle command arguments
# ----------------------------------------------------------
FORCE_UPDATE=false

case "${1:-}" in
    stop|--stop)
        info "Stopping OpenClaw containers..."
        docker compose down --remove-orphans 2>/dev/null || true
        docker rm -f openclaw-gateway 2>/dev/null || true
        ok "All containers stopped."
        exit 0
        ;;
    update|--update)
        FORCE_UPDATE=true
        warn "Force update mode — all steps will be executed"
        ;;
esac

# ----------------------------------------------------------
# 1. Check prerequisites
# ----------------------------------------------------------
if [ ! -f .env ]; then
    error ".env not found. Run ./setup.sh first."
    exit 1
fi

if ! command -v docker &>/dev/null; then
    error "Docker not found. Please install Docker first."
    exit 1
fi

# ----------------------------------------------------------
# 2. Read and validate .env
# ----------------------------------------------------------
info "Reading .env configuration..."

TOKEN=$(grep -E '^OPENCLAW_GATEWAY_TOKEN=' .env 2>/dev/null | cut -d= -f2 || true)
PORT=$(grep -E '^OPENCLAW_GATEWAY_PORT=' .env 2>/dev/null | cut -d= -f2 || true)
PORT=${PORT:-18789}
BIND=$(grep -E '^OPENCLAW_GATEWAY_BIND_ADDR=' .env 2>/dev/null | cut -d= -f2 || true)
BIND=${BIND:-127.0.0.1}
OPENCLAW_IMAGE=$(grep -E '^OPENCLAW_IMAGE=' .env 2>/dev/null | cut -d= -f2 || true)
OPENCLAW_IMAGE=${OPENCLAW_IMAGE:-ghcr.io/openclaw/openclaw:latest}

CONFIG_DIR=$(grep -E '^OPENCLAW_CONFIG_DIR=' .env 2>/dev/null | cut -d= -f2 || true)
WORKSPACE_DIR=$(grep -E '^OPENCLAW_WORKSPACE_DIR=' .env 2>/dev/null | cut -d= -f2 || true)
SKILLS_DIR=$(grep -E '^OPENCLAW_SKILLS_DIR=' .env 2>/dev/null | cut -d= -f2 || true)

# LLM provider settings
VLLM_BASE_URL=$(grep -E '^VLLM_BASE_URL=' .env 2>/dev/null | cut -d= -f2- || true)
VLLM_API_KEY=$(grep -E '^VLLM_API_KEY=' .env 2>/dev/null | cut -d= -f2- || true)
VLLM_MODEL=$(grep -E '^VLLM_MODEL=' .env 2>/dev/null | cut -d= -f2- || true)
VLLM_CONTEXT_WINDOW=$(grep -E '^VLLM_CONTEXT_WINDOW=' .env 2>/dev/null | cut -d= -f2- || true)
VLLM_CONTEXT_WINDOW=${VLLM_CONTEXT_WINDOW:-32768}
VLLM_MAX_TOKENS=$(grep -E '^VLLM_MAX_TOKENS=' .env 2>/dev/null | cut -d= -f2- || true)
VLLM_MAX_TOKENS=${VLLM_MAX_TOKENS:-8192}

ANTHROPIC_API_KEY=$(grep -E '^ANTHROPIC_API_KEY=' .env 2>/dev/null | cut -d= -f2- || true)
OPENAI_API_KEY=$(grep -E '^OPENAI_API_KEY=' .env 2>/dev/null | cut -d= -f2- || true)
OPENROUTER_API_KEY=$(grep -E '^OPENROUTER_API_KEY=' .env 2>/dev/null | cut -d= -f2- || true)

# --- Validate gateway token ---
if [ -z "$TOKEN" ]; then
    error "OPENCLAW_GATEWAY_TOKEN is empty in .env"
    echo "  Run: openssl rand -hex 32"
    echo "  Then set the value in .env"
    exit 1
fi
if [ ${#TOKEN} -lt 32 ]; then
    warn "OPENCLAW_GATEWAY_TOKEN is shorter than 32 chars — consider a stronger token"
fi
ok "Gateway token: ${TOKEN:0:8}...${TOKEN: -4} (${#TOKEN} chars)"

# --- Validate LLM provider ---
HAS_LLM=false
if [ -n "${VLLM_BASE_URL:-}" ] && [ -n "${VLLM_MODEL:-}" ]; then
    ok "LLM provider: vLLM (${VLLM_MODEL} @ ${VLLM_BASE_URL})"
    HAS_LLM=true
elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    ok "LLM provider: Anthropic (API key found)"
    HAS_LLM=true
elif [ -n "${OPENAI_API_KEY:-}" ]; then
    ok "LLM provider: OpenAI (API key found)"
    HAS_LLM=true
elif [ -n "${OPENROUTER_API_KEY:-}" ]; then
    ok "LLM provider: OpenRouter (API key found)"
    HAS_LLM=true
fi

if [ "$HAS_LLM" = false ]; then
    warn "No LLM provider configured!"
    echo "  Set one of the following in .env:"
    echo "    VLLM_BASE_URL + VLLM_MODEL       (Local vLLM)"
    echo "    ANTHROPIC_API_KEY                  (Anthropic)"
    echo "    OPENAI_API_KEY                     (OpenAI)"
    echo "    OPENROUTER_API_KEY                 (OpenRouter)"
    echo ""
fi

# --- Check vLLM endpoint reachability ---
if [ -n "${VLLM_BASE_URL:-}" ]; then
    info "Checking vLLM endpoint: ${VLLM_BASE_URL}/models ..."
    if curl -sf --connect-timeout 5 "${VLLM_BASE_URL}/models" &>/dev/null; then
        ok "vLLM endpoint reachable"
    else
        warn "vLLM endpoint unreachable (${VLLM_BASE_URL})"
        echo "  The service may not be running yet. OpenClaw will retry on startup."
    fi
fi

# ----------------------------------------------------------
# 3. Pull Docker image (with fallback to latest)
# ----------------------------------------------------------
info "Checking Docker image: ${OPENCLAW_IMAGE} ..."
if [ "$FORCE_UPDATE" = false ] && docker image inspect "${OPENCLAW_IMAGE}" &>/dev/null; then
    ok "Image already exists locally: ${OPENCLAW_IMAGE}"
else
    info "Pulling image: ${OPENCLAW_IMAGE} ..."
    if docker pull "${OPENCLAW_IMAGE}"; then
        ok "Image pulled: ${OPENCLAW_IMAGE}"
    else
        FALLBACK_IMAGE="ghcr.io/openclaw/openclaw:latest"
        warn "Failed to pull ${OPENCLAW_IMAGE} — falling back to ${FALLBACK_IMAGE}"
        if docker pull "${FALLBACK_IMAGE}"; then
            ok "Fallback image pulled: ${FALLBACK_IMAGE}"
            OPENCLAW_IMAGE="${FALLBACK_IMAGE}"
            # Update .env so docker compose also uses the fallback image
            sed -i "s|^OPENCLAW_IMAGE=.*|OPENCLAW_IMAGE=${FALLBACK_IMAGE}|" .env
            ok "Updated .env to use ${FALLBACK_IMAGE}"
        else
            error "Failed to pull fallback image ${FALLBACK_IMAGE}"
            exit 1
        fi
    fi
fi

# ----------------------------------------------------------
# 4. Fix permissions for host path volumes (skip if already correct)
# ----------------------------------------------------------
fix_host_dir_permissions() {
    local dir="$1"
    local label="$2"
    if [ -n "$dir" ] && [ -d "$dir" ]; then
        # Skip if permissions are already correct (owned by UID 1000 = node)
        if [ "$FORCE_UPDATE" = false ] && [ "$(stat -c '%u' "$dir" 2>/dev/null)" = "1000" ]; then
            ok "${label} permissions already correct — skipped"
            return
        fi
        info "Fixing permissions: ${dir} (${label})"
        docker run --rm --user root \
            -v "$(cd "$dir" && pwd):/mnt" \
            "${OPENCLAW_IMAGE}" \
            sh -c 'chown -R node:node /mnt'
        ok "${label} permissions fixed"
    fi
}

fix_host_dir_permissions "${CONFIG_DIR:-}" "config"
fix_host_dir_permissions "${WORKSPACE_DIR:-}" "workspace"
fix_host_dir_permissions "${SKILLS_DIR:-}" "skills"

# ----------------------------------------------------------
# 5. Ensure openclaw.json exists
# ----------------------------------------------------------
if [ -n "${CONFIG_DIR:-}" ] && [ -d "${CONFIG_DIR}" ]; then
    if [ ! -f "${CONFIG_DIR}/openclaw.json" ]; then
        info "Creating default openclaw.json..."
        docker run --rm --user root \
            -v "$(cd "$CONFIG_DIR" && pwd):/mnt" \
            "${OPENCLAW_IMAGE}" \
            sh -c '
            cat > /mnt/openclaw.json << EOFCFG
{
  "gateway": {
    "mode": "local",
    "controlUi": {
      "dangerouslyAllowHostHeaderOriginFallback": true
    }
  }
}
EOFCFG
            chown node:node /mnt/openclaw.json
        '
        ok "openclaw.json created"
    else
        ok "openclaw.json already exists — skipped"
    fi
fi

# ----------------------------------------------------------
# 6. Start Docker Compose (skip restart if already running with same config)
# ----------------------------------------------------------
NEED_RESTART=false
GATEWAY_STATUS=$(docker compose ps --format '{{.Service}} {{.State}}' 2>/dev/null | grep 'openclaw-gateway' || true)

if [ "$FORCE_UPDATE" = true ]; then
    info "Force update — restarting containers..."
    NEED_RESTART=true
elif echo "$GATEWAY_STATUS" | grep -q 'running'; then
    # Gateway is running — only restart if config files changed
    CONTAINER_CREATED=$(docker inspect --format '{{.Created}}' "$(docker compose ps -q openclaw-gateway)" 2>/dev/null || true)
    ENV_MODIFIED=$(stat -c '%Y' .env 2>/dev/null || echo "0")
    COMPOSE_MODIFIED=$(stat -c '%Y' docker-compose.yml 2>/dev/null || echo "0")
    CONTAINER_EPOCH=$(date -d "${CONTAINER_CREATED}" +%s 2>/dev/null || echo "0")

    if [ "$ENV_MODIFIED" -gt "$CONTAINER_EPOCH" ] || [ "$COMPOSE_MODIFIED" -gt "$CONTAINER_EPOCH" ]; then
        info "Config changed since last start — restarting containers..."
        NEED_RESTART=true
    else
        ok "Gateway already running with current config — skipped restart"
    fi
else
    NEED_RESTART=true
fi

if [ "$NEED_RESTART" = true ]; then
    info "Removing old containers..."
    docker compose down --remove-orphans 2>/dev/null || true
    docker rm -f openclaw-gateway 2>/dev/null || true
    info "Starting containers..."
    docker compose up -d
    ok "Containers started"
fi

# ----------------------------------------------------------
# 7. Wait for healthy
# ----------------------------------------------------------
info "Waiting for gateway to become healthy..."
for i in $(seq 1 30); do
    if curl -sf "http://127.0.0.1:${PORT}/healthz" &>/dev/null; then
        ok "Gateway health check passed"
        break
    fi
    if [ "$i" -eq 30 ]; then
        warn "Gateway health check timeout. Check: docker compose logs openclaw-gateway"
        exit 1
    fi
    sleep 2
done

# ----------------------------------------------------------
# 8. Configure LLM provider in openclaw.json (skip if already configured)
# ----------------------------------------------------------
if [ -n "${VLLM_BASE_URL:-}" ] && [ -n "${VLLM_MODEL:-}" ]; then
    # Check if vLLM is already configured with the same model
    CURRENT_MODEL=$(docker compose exec -T openclaw-gateway node dist/index.js config get agents.defaults.model 2>/dev/null \
        | grep -oP '"agents\.defaults\.model"\s*:\s*"\K[^"]+' || true)

    if [ "$FORCE_UPDATE" = false ] && [ "$CURRENT_MODEL" = "vllm/${VLLM_MODEL}" ]; then
        ok "vLLM already configured: vllm/${VLLM_MODEL} — skipped"
    else
        info "Writing vLLM config to openclaw.json..."
        docker compose exec -T openclaw-gateway node dist/index.js config set \
            models.providers.vllm \
            "{\"baseUrl\":\"${VLLM_BASE_URL}\",\"api\":\"openai-completions\",\"apiKey\":\"${VLLM_API_KEY:-EMPTY}\",\"models\":[{\"id\":\"${VLLM_MODEL}\",\"name\":\"${VLLM_MODEL}\",\"contextWindow\":${VLLM_CONTEXT_WINDOW},\"maxTokens\":${VLLM_MAX_TOKENS},\"reasoning\":false,\"input\":[\"text\"],\"cost\":{\"input\":0,\"output\":0}}]}" \
            2>&1 | grep -v "DeprecationWarning\|trace-deprecation\|Failed to discover" || true
        docker compose exec -T openclaw-gateway node dist/index.js config set \
            agents.defaults.model "vllm/${VLLM_MODEL}" \
            2>&1 | grep -v "DeprecationWarning\|trace-deprecation" || true
        ok "vLLM configured: vllm/${VLLM_MODEL}"

        # Restart gateway to apply config changes
        info "Restarting gateway to apply LLM config..."
        docker compose restart openclaw-gateway
        for i in $(seq 1 30); do
            if curl -sf "http://127.0.0.1:${PORT}/healthz" &>/dev/null; then
                ok "Gateway healthy after LLM config"
                break
            fi
            if [ "$i" -eq 30 ]; then
                warn "Gateway health check timeout after LLM config"
            fi
            sleep 2
        done
    fi
fi

# ----------------------------------------------------------
# 9. Display login URL
# ----------------------------------------------------------
echo ""
echo "=========================================="
echo -e "${GREEN} Login URL${NC}"
echo "=========================================="
echo ""
echo -e "  ${CYAN}http://${BIND}:${PORT}/#token=${TOKEN}${NC}"
echo ""
echo -e "  Open the URL above in your browser."
echo ""

# ----------------------------------------------------------
# 10. Auto-approve device pairing
# ----------------------------------------------------------
echo -e "${YELLOW}After opening the URL, press Enter here to approve device pairing...${NC}"
read -r

info "Checking pending device pairing requests..."

PENDING=$(docker compose exec -T openclaw-gateway node dist/index.js devices list 2>&1)

# Extract pending request IDs
REQUEST_IDS=$(echo "$PENDING" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' || true)

if [ -z "$REQUEST_IDS" ]; then
    warn "No pending pairing requests found."
    echo "  If the browser shows 'pairing required', refresh and try again."
else
    for REQ_ID in $REQUEST_IDS; do
        info "Approving device: ${REQ_ID}"
        docker compose exec -T openclaw-gateway node dist/index.js devices approve "$REQ_ID" 2>&1 | grep -v "DeprecationWarning\|trace-deprecation\|Failed to discover" || true
        ok "Device approved: ${REQ_ID}"
    done
    echo ""
    ok "Device pairing complete! Refresh your browser to enter Control UI."
fi

echo ""
echo "=========================================="
echo -e "${GREEN} OpenClaw is ready!${NC}"
echo "=========================================="
echo ""
