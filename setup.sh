#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# OpenClaw Docker Compose 一鍵部署腳本
# 用法：chmod +x setup.sh && ./setup.sh
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 顏色輸出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ----------------------------------------------------------
# 1. 檢查前置需求
# ----------------------------------------------------------
info "檢查 Docker 環境..."

if ! command -v docker &>/dev/null; then
    error "Docker 未安裝！請先執行："
    echo "  curl -fsSL https://get.docker.com | sudo sh"
    echo "  sudo usermod -aG docker \$USER"
    exit 1
fi

if ! docker compose version &>/dev/null; then
    error "Docker Compose V2 未安裝！請更新 Docker 或手動安裝 compose plugin。"
    exit 1
fi

if ! docker info &>/dev/null 2>&1; then
    error "Docker daemon 未運行或權限不足。請確認 Docker 已啟動且使用者已在 docker 群組。"
    exit 1
fi

ok "Docker $(docker version --format '{{.Server.Version}}') + Compose $(docker compose version --short)"

# ----------------------------------------------------------
# 2. 生成 .env 檔案
# ----------------------------------------------------------
if [ -f .env ]; then
    warn ".env 已存在，跳過生成。如需重新生成請先刪除 .env"
else
    info "從 .env.example 生成 .env..."

    if [ ! -f .env.example ]; then
        error ".env.example 不存在！請確認檔案完整。"
        exit 1
    fi

    cp .env.example .env

    # 自動生成隨機 token
    TOKEN=$(openssl rand -hex 32)
    if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' "s/^OPENCLAW_GATEWAY_TOKEN=$/OPENCLAW_GATEWAY_TOKEN=${TOKEN}/" .env
    else
        sed -i "s/^OPENCLAW_GATEWAY_TOKEN=$/OPENCLAW_GATEWAY_TOKEN=${TOKEN}/" .env
    fi

    ok ".env 已生成，Gateway Token: ${TOKEN}"
    echo ""
    warn "請妥善保存此 Token，登入 UI 時需要使用！"
    echo ""
fi

# ----------------------------------------------------------
# 3. 初始化 config（首次部署需要）
# ----------------------------------------------------------
info "初始化 OpenClaw 設定..."
docker compose pull --quiet

# 建立 volumes 並修正權限
docker compose up --no-start 2>/dev/null || true

CONFIG_VOL=$(docker volume ls --format '{{.Name}}' | grep openclaw-config || true)
WORKSPACE_VOL=$(docker volume ls --format '{{.Name}}' | grep openclaw-workspace || true)

# 修正 volume 權限（Docker 預設建立為 root，container 以 node 使用者執行）
if [ -n "$CONFIG_VOL" ]; then
    docker run --rm --user root \
        -v "${CONFIG_VOL}:/mnt/config" \
        ghcr.io/openclaw/openclaw:latest \
        sh -c 'chown -R node:node /mnt/config'

    # 建立最小 config（若不存在）
    docker run --rm --user root \
        -v "${CONFIG_VOL}:/mnt/config" \
        ghcr.io/openclaw/openclaw:latest \
        sh -c '
        if [ ! -f /mnt/config/openclaw.json ]; then
            cat > /mnt/config/openclaw.json << EOFCFG
{
  "gateway": {
    "mode": "local",
    "controlUi": {
      "dangerouslyAllowHostHeaderOriginFallback": true
    }
  }
}
EOFCFG
            chown node:node /mnt/config/openclaw.json
            echo "Config created."
        else
            echo "Config already exists."
        fi
    '
fi

# 修正 workspace volume 權限（獨立處理，確保 node 使用者可寫入）
if [ -n "$WORKSPACE_VOL" ]; then
    docker run --rm --user root \
        -v "${WORKSPACE_VOL}:/mnt/workspace" \
        ghcr.io/openclaw/openclaw:latest \
        sh -c 'chown -R node:node /mnt/workspace'
fi
ok "設定初始化完成"

# ----------------------------------------------------------
# 4. 啟動 Gateway 服務
# ----------------------------------------------------------
info "啟動 OpenClaw Gateway..."
docker compose up -d
ok "Gateway 已啟動！"

# ----------------------------------------------------------
# 5. 顯示結果
# ----------------------------------------------------------
echo ""
echo "=========================================="
echo -e "${GREEN} OpenClaw 部署完成！${NC}"
echo "=========================================="
echo ""

# 讀取 port
PORT=$(grep -E '^OPENCLAW_GATEWAY_PORT=' .env 2>/dev/null | cut -d= -f2)
PORT=${PORT:-18789}
BIND=$(grep -E '^OPENCLAW_GATEWAY_BIND_ADDR=' .env 2>/dev/null | cut -d= -f2)
BIND=${BIND:-127.0.0.1}

SAVED_TOKEN=$(grep -E '^OPENCLAW_GATEWAY_TOKEN=' .env 2>/dev/null | cut -d= -f2)
echo -e "  Dashboard URL（帶 Token 直接登入）："
echo -e "  ${CYAN}http://${BIND}:${PORT}/#token=${SAVED_TOKEN}${NC}"
echo ""
echo -e "  或手動存取 ${CYAN}http://${BIND}:${PORT}${NC} 再貼上 Token"
echo ""
echo "常用指令："
echo "  docker compose logs -f          # 查看即時日誌"
echo "  docker compose ps               # 查看服務狀態"
echo "  docker compose down             # 停止服務"
echo "  docker compose up -d            # 重新啟動"
echo "  docker compose pull && docker compose up -d  # 更新版本"
echo ""
echo "  docker compose --profile cli run --rm openclaw-cli onboard    # 重新設定"
echo "  docker compose --profile cli run --rm openclaw-cli channels add telegram --token YOUR_TOKEN"
echo ""

# 等待 healthcheck
info "等待 Gateway 啟動..."
for i in $(seq 1 30); do
    if curl -sf "http://127.0.0.1:${PORT}/healthz" &>/dev/null; then
        ok "Gateway 健康檢查通過！"
        exit 0
    fi
    sleep 2
done

warn "Gateway 尚未通過健康檢查，請執行 docker compose logs -f 查看狀態。"
