#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# OpenClaw First Login Helper
# Handles: permission fix → config init → restart → device pairing
# Usage: chmod +x first-login.sh && ./first-login.sh
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
# 1. Check prerequisites
# ----------------------------------------------------------
if [ ! -f .env ]; then
    error ".env not found. Run ./setup.sh first."
    exit 1
fi

if ! docker compose ps --format '{{.Name}}' 2>/dev/null | grep -q openclaw-gateway; then
    error "openclaw-gateway container not found. Run: docker compose up -d"
    exit 1
fi

# Read config from .env
TOKEN=$(grep -E '^OPENCLAW_GATEWAY_TOKEN=' .env | cut -d= -f2)
PORT=$(grep -E '^OPENCLAW_GATEWAY_PORT=' .env 2>/dev/null | cut -d= -f2)
PORT=${PORT:-18789}
BIND=$(grep -E '^OPENCLAW_GATEWAY_BIND_ADDR=' .env 2>/dev/null | cut -d= -f2)
BIND=${BIND:-127.0.0.1}
OPENCLAW_IMAGE=$(grep -E '^OPENCLAW_IMAGE=' .env 2>/dev/null | cut -d= -f2)
OPENCLAW_IMAGE=${OPENCLAW_IMAGE:-ghcr.io/openclaw/openclaw:latest}

CONFIG_DIR=$(grep -E '^OPENCLAW_CONFIG_DIR=' .env 2>/dev/null | cut -d= -f2)
WORKSPACE_DIR=$(grep -E '^OPENCLAW_WORKSPACE_DIR=' .env 2>/dev/null | cut -d= -f2)
SKILLS_DIR=$(grep -E '^OPENCLAW_SKILLS_DIR=' .env 2>/dev/null | cut -d= -f2)

# ----------------------------------------------------------
# 2. Fix permissions for host path volumes
# ----------------------------------------------------------
fix_host_dir_permissions() {
    local dir="$1"
    local label="$2"
    if [ -n "$dir" ] && [ -d "$dir" ]; then
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
# 3. Ensure openclaw.json exists
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
        ok "openclaw.json already exists"
    fi
fi

# ----------------------------------------------------------
# 4. Restart gateway
# ----------------------------------------------------------
info "Restarting openclaw-gateway..."
docker compose restart openclaw-gateway
ok "Gateway restarted"

# ----------------------------------------------------------
# 5. Wait for healthy
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
# 6. Display login URL
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
# 7. Auto-approve device pairing
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
echo -e "${GREEN} First login setup complete!${NC}"
echo "=========================================="
echo ""
