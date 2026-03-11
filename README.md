**English** | [中文](docs/zh/README.md)

# OpenClaw Docker Compose — Security-First + Local LLM

> Security-hardened OpenClaw Docker deployment with built-in security checks, Local LLM integration, and one-click setup.

## Highlights

### Security Hardening (Out of the Box)

Multi-layer security protection enabled by default, no manual configuration needed:

| Protection | Setting | Effect |
|------------|---------|--------|
| Capability removal | `cap_drop: ALL` | Drop all Linux capabilities |
| Privilege escalation | `no-new-privileges` | Prevent in-container privilege escalation |
| Read-only filesystem | `read_only: true` | Root filesystem is read-only |
| Execution restriction | `tmpfs /tmp (noexec)` | /tmp is non-executable |
| Sandbox | `SANDBOX_MODE=non-main` | Non-main sessions are sandboxed |
| File access | `WORKSPACEONLY=true` | Agent can only access workspace |
| Fork bomb protection | `PIDS_LIMIT=256` | Limit PID count |
| Network binding | `127.0.0.1` | Localhost-only by default |

### Local LLM Support

Multiple Local LLM options supported — configure in `.env`:

| Provider | Use Case | VRAM Requirement |
|----------|----------|------------------|
| **Ollama** | Personal dev, no GPU / small GPU | CPU capable |
| **vLLM** | Production, high throughput | 8GB+ |
| **LM Studio** | Windows/macOS GUI | Model dependent |
| **OpenAI / Anthropic / OpenRouter** | Cloud API | None |

---

## Quick Start

```bash
# One-click deployment
chmod +x setup.sh && ./setup.sh
```

The script automatically: checks Docker → generates `.env` (with random Token) → pulls image → initializes config → starts Gateway → runs health check.

### Manual Deployment

```bash
cp .env.example .env
# Edit .env, set OPENCLAW_GATEWAY_TOKEN (run: openssl rand -hex 32)
docker compose pull && docker compose up -d
```

---

## Configure LLM

Uncomment and fill in the corresponding API Key in `.env`:

```bash
# Cloud API (choose one)
ANTHROPIC_API_KEY=sk-ant-xxxxx
OPENAI_API_KEY=sk-xxxxx
OPENROUTER_API_KEY=sk-or-xxxxx

# Local LLM
VLLM_API_KEY=token-abc123        # vLLM (http://host.docker.internal:8000/v1)
OLLAMA_API_KEY=                   # Ollama (http://host.docker.internal:11434)
```

Configure the provider in OpenClaw:

```bash
# Restart to apply .env changes
docker compose up -d

# Set vLLM provider
docker compose exec openclaw-gateway node dist/index.js config set \
  models.providers.vllm '{"baseUrl":"http://host.docker.internal:8000/v1","api":"openai-completions","apiKey":"VLLM_API_KEY","models":[{"id":"YOUR_MODEL","contextWindow":128000,"maxTokens":8192,"reasoning":false,"input":["text"],"cost":{"input":0,"output":0}}]}'

# Set default model
docker compose exec openclaw-gateway node dist/index.js config set \
  agents.defaults.model "vllm/YOUR_MODEL"

docker compose restart openclaw-gateway
```

> For detailed LLM setup (Ollama, vLLM Docker Compose integration, quantized models, etc.), see [USER_GUIDE.md](docs/zh/USER_GUIDE.md)

---

## Verify Service Status

```bash
# Container status (should show "healthy")
docker compose ps

# Health check API
curl http://127.0.0.1:18789/healthz
# Response: {"ok":true,"status":"live"}

# Version check
docker compose exec openclaw-gateway node dist/index.js --version
```

---

## Login to Control UI

```bash
# View Token
grep OPENCLAW_GATEWAY_TOKEN .env

# Login with Token URL (recommended)
# http://localhost:18789/#token=YOUR_TOKEN
```

First-time login requires device pairing:

```bash
# View pending pairing requests
docker compose exec openclaw-gateway node dist/index.js devices list

# Approve pairing
docker compose exec openclaw-gateway node dist/index.js devices approve <REQUEST_ID>
```

---

## Common Commands

```bash
docker compose up -d                    # Start
docker compose down                     # Stop
docker compose logs -f                  # Logs
docker compose restart                  # Restart
docker compose pull && docker compose up -d  # Update

# CLI tools
docker compose --profile cli run --rm openclaw-cli configure
docker compose --profile cli run --rm openclaw-cli onboard
```

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `unauthorized: gateway token missing` | Use Token URL: `http://localhost:18789/#token=TOKEN` |
| `pairing required` | Run `devices list` → `devices approve <ID>` |
| `Missing config` | Run `./setup.sh` to re-initialize |
| `EACCES: permission denied` | Fix volume permissions: `docker run --rm --user root -v VOLUME:/mnt ghcr.io/openclaw/openclaw:latest sh -c 'chown -R node:node /mnt'` |
| Health check fails | Check logs: `docker compose logs openclaw-gateway` |
| Full reset | `docker compose down -v && rm .env && ./setup.sh` |

---

## File Structure

```
├── docker-compose.yml   # Docker Compose (with security hardening)
├── .env.example         # Environment variable template
├── .env                 # Actual environment variables (git ignored)
├── setup.sh             # One-click deployment script
├── Caddyfile            # HTTPS reverse proxy (optional)
├── docs/zh/             # Chinese documentation
│   ├── README.md        # Chinese README
│   ├── USER_GUIDE.md    # Full user guide
│   └── TODOLIST.md      # Deployment notes & troubleshooting log
└── .gitignore           # Exclude sensitive files
```

---

## Documentation

For the full user guide, see **[USER_GUIDE.md](docs/zh/USER_GUIDE.md)**, covering:

- LLM configuration (Ollama / vLLM / LM Studio / Cloud API)
- vLLM Docker Compose integration, multi-GPU, quantized inference
- Integration security assessment (Telegram / WhatsApp / Webhook)
- Known CVE vulnerabilities and patches
- HTTPS reverse proxy (Caddy) setup
- Complete troubleshooting guide

---
