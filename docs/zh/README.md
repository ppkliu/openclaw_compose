[English](../../README.md) | **中文**

# OpenClaw Docker Compose — Security-First + Local LLM

> 安全強化的 OpenClaw Docker 部署方案，內建自動安全檢查、Local LLM 整合、一鍵部署。

## 本專案重點

### 自動安全強化

開箱即用的多層安全防護，無需手動設定：

| 防護項目 | 設定 | 效果 |
|----------|------|------|
| 權限移除 | `cap_drop: ALL` | 移除所有 Linux capabilities |
| 提權防護 | `no-new-privileges` | 禁止容器內提權 |
| 唯讀系統 | `read_only: true` | 根檔案系統唯讀 |
| 執行限制 | `tmpfs /tmp (noexec)` | /tmp 不可執行 |
| Sandbox | `SANDBOX_MODE=non-main` | 非主會話強制隔離 |
| 檔案限制 | `WORKSPACEONLY=true` | Agent 僅能存取 workspace |
| Fork bomb | `PIDS_LIMIT=256` | 限制 PID 數量 |
| 網路綁定 | `127.0.0.1` | 預設僅本機存取 |

### Local LLM 支援

支援多種 Local LLM 方案，在 `.env` 設定即可使用：

| Provider | 適用情境 | VRAM 需求 |
|----------|----------|-----------|
| **Ollama** | 個人開發、無 GPU / 小 GPU | 可 CPU 運行 |
| **vLLM** | 生產環境、高吞吐 | 8GB+ |
| **LM Studio** | Windows/macOS 圖形介面 | 依模型 |
| **OpenAI / Anthropic / OpenRouter** | 雲端 API | 無 |

---

## 快速開始

```bash
# 一鍵部署
chmod +x setup.sh && ./setup.sh
```

腳本自動完成：檢查 Docker → 生成 `.env`（含隨機 Token）→ 拉取映像 → 初始化 → 啟動 → 健康檢查

### 手動部署

```bash
cp .env.example .env
# 編輯 .env 設定 OPENCLAW_GATEWAY_TOKEN（openssl rand -hex 32）
docker compose pull && docker compose up -d
```

---

## 設定 LLM

在 `.env` 中取消註解並填入對應 API Key：

```bash
# Cloud API（擇一）
ANTHROPIC_API_KEY=sk-ant-xxxxx
OPENAI_API_KEY=sk-xxxxx
OPENROUTER_API_KEY=sk-or-xxxxx

# Local LLM
VLLM_API_KEY=token-abc123        # vLLM（http://host.docker.internal:8000/v1）
OLLAMA_API_KEY=                   # Ollama（http://host.docker.internal:11434）
```

設定 Provider 到 OpenClaw config：

```bash
# 重啟套用 .env
docker compose up -d

# 設定 vLLM provider
docker compose exec openclaw-gateway node dist/index.js config set \
  models.providers.vllm '{"baseUrl":"http://host.docker.internal:8000/v1","api":"openai-completions","apiKey":"VLLM_API_KEY","models":[{"id":"YOUR_MODEL","contextWindow":128000,"maxTokens":8192,"reasoning":false,"input":["text"],"cost":{"input":0,"output":0}}]}'

# 設定預設 model
docker compose exec openclaw-gateway node dist/index.js config set \
  agents.defaults.model "vllm/YOUR_MODEL"

docker compose restart openclaw-gateway
```

> 詳細 LLM 設定（Ollama、vLLM Docker Compose 整合、量化模型等）請參考 [USER_GUIDE.md](USER_GUIDE.md#設定-local-端-llmollama--localai--lm-studio)

---

## 確認服務狀態

```bash
# 容器狀態（應顯示 healthy）
docker compose ps

# 健康檢查 API
curl http://127.0.0.1:18789/healthz
# 回應：{"ok":true,"status":"live"}

# 版本確認
docker compose exec openclaw-gateway node dist/index.js --version
```

---

## 登入 Control UI

```bash
# 查看 Token
grep OPENCLAW_GATEWAY_TOKEN .env

# 帶 Token URL 直接登入（推薦）
# http://localhost:18789/#token=YOUR_TOKEN
```

首次登入需裝置配對：

```bash
# 查看 Pending 請求
docker compose exec openclaw-gateway node dist/index.js devices list

# 批准配對
docker compose exec openclaw-gateway node dist/index.js devices approve <REQUEST_ID>
```

---

## 常用指令

```bash
docker compose up -d                    # 啟動
docker compose down                     # 停止
docker compose logs -f                  # 日誌
docker compose restart                  # 重啟
docker compose pull && docker compose up -d  # 更新

# CLI 工具
docker compose --profile cli run --rm openclaw-cli configure
docker compose --profile cli run --rm openclaw-cli onboard
```

---

## 疑難排解

| 問題 | 解法 |
|------|------|
| `unauthorized: gateway token missing` | 使用帶 Token URL：`http://localhost:18789/#token=TOKEN` |
| `pairing required` | 執行 `devices list` → `devices approve <ID>` |
| `Missing config` | 執行 `./setup.sh` 重新初始化 |
| `EACCES: permission denied` | 修正 volume 權限：`docker run --rm --user root -v VOLUME:/mnt ghcr.io/openclaw/openclaw:latest sh -c 'chown -R node:node /mnt'` |
| 健康檢查失敗 | `docker compose logs openclaw-gateway` 查看錯誤 |
| 完全重置 | `docker compose down -v && rm .env && ./setup.sh` |

---

## 檔案結構

```
├── docker-compose.yml   # Docker Compose（含安全強化）
├── .env.example         # 環境變數範例
├── .env                 # 實際環境變數（git ignored）
├── setup.sh             # 一鍵部署腳本
├── Caddyfile            # HTTPS 反向代理（可選）
├── docs/zh/             # 中文文件
│   ├── README.md        # 中文版 README
│   ├── USER_GUIDE.md    # 完整使用指南
│   └── TODOLIST.md      # 部署踩坑記錄
└── .gitignore           # 排除敏感檔案
```

---

## 詳細文件

完整使用指南請參考 **[USER_GUIDE.md](USER_GUIDE.md)**，包含：

- 各種 LLM 設定方式（Ollama / vLLM / LM Studio / Cloud API）
- vLLM Docker Compose 整合、多 GPU、量化推理
- 串接系統安全性評估（Telegram / WhatsApp / Webhook）
- 已知 CVE 漏洞與修補建議
- HTTPS 反向代理（Caddy）設定
- 完整疑難排解指南

---
