# Cloud Foundry Deployment Reference

This reference covers deploying the LangGraph A2A agent to SAP BTP Cloud Foundry.

## Table of Contents

1. [manifest.yml](#1-manifestyml)
2. [requirements.txt](#2-requirementstxt)
3. [Procfile](#3-procfile)
4. [runtime.txt](#4-runtimetxt)
5. [.env.example](#5-envexample)
6. [Deployment Steps](#6-deployment-steps)
7. [BTP Destination Configuration](#7-btp-destination-configuration)
8. [Service Bindings](#8-service-bindings)
9. [Troubleshooting](#9-troubleshooting)

---

## 1. manifest.yml

The Cloud Foundry deployment descriptor. Customize the application name, memory, and service bindings.

```yaml
---
applications:
  - name: my-a2a-agent
    memory: 512M
    disk_quota: 1G
    instances: 1
    buildpacks:
      - python_buildpack
    command: python -m app
    env:
      MODEL_NAME: gpt-4.1
      AICORE_RESOURCE_GROUP: default
    services:
      - aicore  # TODO: replace with your AI Core service instance name (cf services | grep aicore)
    routes:
      - route: my-a2a-agent.cfapps.<landscape>.hana.ondemand.com
```

### Manifest variables to customize:

| Variable | Description | Example |
|----------|-------------|---------|
| `name` | CF app name (must be unique in the space) | `currency-agent` |
| `memory` | RAM allocation (512M usually sufficient) | `512M` or `1G` |
| `instances` | Number of running instances | `1` for dev, `2+` for prod |
| `command` | Start command | `python -m app` |
| `services` | Bound service instances | AI Core, Destination, XSUAA |
| `route` | App URL | Depends on CF landscape |

### Common CF landscapes:

| Landscape | API Endpoint | Route Domain |
|-----------|-------------|--------------|
| US10 | `https://api.cf.us10.hana.ondemand.com` | `cfapps.us10.hana.ondemand.com` |
| EU10 | `https://api.cf.eu10.hana.ondemand.com` | `cfapps.eu10.hana.ondemand.com` |
| US20 | `https://api.cf.us20.hana.ondemand.com` | `cfapps.us20.hana.ondemand.com` |
| EU20 | `https://api.cf.eu20.hana.ondemand.com` | `cfapps.eu20.hana.ondemand.com` |
| AP10 | `https://api.cf.ap10.hana.ondemand.com` | `cfapps.ap10.hana.ondemand.com` |

---

## 2. requirements.txt

```
langchain>=0.3.0,<2.0.0
langchain-core>=0.3.0,<2.0.0
langchain-openai>=0.3.0
langgraph>=0.2.0
a2a-sdk>=0.2.7
httpx>=0.27.0
uvicorn>=0.30.0
pydantic>=2.11.3
starlette
sse-starlette
fastapi>=0.95.0
```

> **Note:** Do NOT use `generative-ai-hub-sdk` — it pins `pydantic==2.10.6` which conflicts with `a2a-sdk`'s requirement of `pydantic>=2.11.3`. Use `langchain-openai` with direct AI Core credential extraction instead.

---

## 3. Procfile

```
web: python -m app
```

---

## 4. runtime.txt

```
python-3.12.x
```

---

## 5. .env.example

```bash
# SAP GenAI Hub model (must be deployed on your AI Core instance)
MODEL_NAME=gpt-4.1

# AI Core resource group (default is usually correct)
AICORE_RESOURCE_GROUP=default

# For local development — paste your AI Core service key JSON:
# AICORE_SERVICE_KEY={"serviceurls":{"AI_API_URL":"https://..."},"clientid":"...","clientsecret":"...","url":"https://..."}

# Server
HOST=0.0.0.0
PORT=8080
```

---

## 6. Deployment Steps

### Prerequisites

1. **CF CLI installed**: `cf version` should work
2. **Logged in to CF**: `cf login -a <api-endpoint>`
3. **AI Core service instance** created (if using SAP GenAI Hub)

### Deploy

```bash
# 1. Navigate to your agent project directory
cd my-a2a-agent

# 2. (First time) Create AI Core service instance
cf create-service aicore extended aicore

# 3. Push the application
cf push

# 4. Verify it's running
cf apps
cf logs my-a2a-agent --recent

# 5. Test the agent card endpoint
curl https://my-a2a-agent.cfapps.<landscape>.hana.ondemand.com/.well-known/agent.json
```

### Update an existing deployment

```bash
# After code changes, just push again
cf push

# To scale
cf scale my-a2a-agent -i 2 -m 1G
```

---

## 7. BTP Destination Configuration

After deploying the agent, create a BTP Destination so Joule can reach it.

### Steps:

1. Go to **BTP Cockpit** → your subaccount → **Connectivity** → **Destinations**
2. Click **New Destination**
3. Configure:

| Property | Value |
|----------|-------|
| Name | `MyAgent_A2A` (this name goes in your Joule capability YAML) |
| Type | HTTP |
| URL | `https://my-a2a-agent.cfapps.<landscape>.hana.ondemand.com` |
| Proxy Type | Internet |
| Authentication | NoAuthentication (or OAuth2ClientCredentials if secured) |

4. Add additional property:
   - `HTML5.DynamicDestination` = `true`

### For secured agents (OAuth2):

| Property | Value |
|----------|-------|
| Authentication | OAuth2ClientCredentials |
| Client ID | Your XSUAA client ID |
| Client Secret | Your XSUAA client secret |
| Token Service URL | `https://<subdomain>.authentication.<landscape>.hana.ondemand.com/oauth/token` |

---

## 8. Service Bindings

### AI Core (for SAP GenAI Hub)

```bash
# Create service instance
cf create-service aicore extended aicore

# Bind to your app (already in manifest.yml under services)
cf bind-service my-a2a-agent aicore

# Restage to pick up new bindings
cf restage my-a2a-agent
```

### XSUAA (if you want to secure your agent)

```bash
# Create with a security descriptor
cf create-service xsuaa application my-xsuaa-instance -c xs-security.json

# xs-security.json example:
# {
#   "xsappname": "my-a2a-agent",
#   "tenant-mode": "dedicated",
#   "scopes": [{"name": "$XSAPPNAME.agent.invoke"}],
#   "role-templates": [{"name": "AgentInvoker", "scope-references": ["$XSAPPNAME.agent.invoke"]}]
# }
```

---

## 9. Troubleshooting

### Agent card not accessible

```bash
# Check app status
cf app my-a2a-agent

# Check recent logs
cf logs my-a2a-agent --recent

# Verify route
cf routes
```

### App crashes on startup

- Check `requirements.txt` for missing dependencies
- Verify Python version in `runtime.txt` matches what the buildpack supports
- Check if `VCAP_SERVICES` is populated (for SAP GenAI Hub)

### Destination issues

- Verify the destination URL matches the CF app route exactly
- Check that the destination is accessible from Joule's subaccount
- For cross-subaccount: ensure proper trust/connectivity is set up

### Memory issues

- LangGraph + LLM SDK can use significant memory. Start with 512M, increase to 1G if you see OOM errors.
- Check: `cf app my-a2a-agent` shows memory usage

### pydantic version conflict

If you see errors like `pydantic version mismatch` or `generative-ai-hub-sdk` failing:
- **Do NOT use `generative-ai-hub-sdk`** — it pins `pydantic==2.10.6` which conflicts with `a2a-sdk`'s `pydantic>=2.11.3`
- Instead, use `langchain-openai` with direct AI Core credential extraction (see `agent.py` `get_llm()`)
- Ensure `requirements.txt` has `pydantic>=2.11.3` (not `pydantic>=2.0.0`)

### a2a-sdk import errors

The `a2a-sdk` 0.3.x changed many import paths from 0.2.x:
- `a2a.server.request_handler` → `a2a.server.request_handlers`
- `a2a.server.apps` → `a2a.server.apps.jsonrpc.starlette_app`
- `a2a.server.tasks` → `a2a.server.tasks.inmemory_task_store`
- `a2a.server.events` → `a2a.server.events.event_queue`
- `AgentAuthentication` was removed from `a2a.types`
- `AgentExecutor.on_message_send`/`on_message_stream` → `execute`/`cancel` with `RequestContext`

### AI Core service binding not found

If you see "No AI Core service binding found":
- Verify the service name in `manifest.yml` matches your actual service instance: `cf services | grep aicore`
- Check VCAP_SERVICES has the binding: `cf env my-a2a-agent | grep -A 5 aicore`
- For local dev, set `AICORE_SERVICE_KEY` env var with your AI Core service key JSON
