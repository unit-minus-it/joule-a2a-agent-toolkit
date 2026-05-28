# Developer Environment Setup Guide

Everything you need to go from zero to a deployed, working Joule A2A agent. Read this before starting development.

---

## 1. Prerequisites — tools to install

### All frameworks

| Tool | Install | Verify |
|------|---------|--------|
| CF CLI (v8) | [Download](https://github.com/cloudfoundry/cli/releases) | `cf version` or `cf8 version` |
| Joule CLI | `npm install -g @sap/joule-studio-cli` | `joule --version` or `npx joule --version` |
| Node.js v20+ | [nodejs.org](https://nodejs.org) | `node --version` |

> **CF CLI alias:** Depending on how the CF CLI was installed, the binary may be `cf` or `cf8`. Run both and use whichever works. Commands in this guide use `cf` — substitute `cf8` if needed.

> **Joule CLI PATH:** After installing globally, `joule` may not be on PATH in all shells. If `joule --version` fails, use `npx joule` instead — it always works via Node's npx runner.

### Python agents only

| Tool | Install | Verify |
|------|---------|--------|
| Python 3.12+ | [python.org](https://python.org) | `python --version` |
| pip | bundled with Python | `pip --version` |

> **Avoid global Python conflicts:** Global Python environments often have packages that pin incompatible versions (e.g. `litellm` requires `httpx<0.28.0` but `a2a-sdk` requires `httpx>=0.28.1`). Always use a virtual environment — see section 3.

### TypeScript CAP agents only (in addition to "All frameworks")

| Tool | Install | Verify |
|------|---------|--------|
| MTA Build Tool | `npm install -g mbt` | `mbt --version` |
| CF multiapps plugin | `cf install-plugin multiapps` | `cf plugins` |

---

## 2. Where to get credentials

### Cloud Foundry login

You need the **CF API endpoint** and your BTP credentials. Find both in the BTP cockpit:

1. Go to **BTP Cockpit** → your global account → subaccount
2. Click **Cloud Foundry** in the left menu → **Spaces**
3. The CF API endpoint is shown as **API Endpoint**, e.g.: `https://api.cf.eu20.hana.ondemand.com`
4. Your login is your BTP/SAP ID (the email you use to log in to the cockpit)

> **SSO environments:** Most enterprise BTP accounts use SSO. Use `cf login --sso` — it prints a URL, you open it in a browser, get a one-time passcode, paste it back. No username/password needed.

### Joule CLI login

The Joule CLI authenticates via your BTP IAS identity. You need the **Joule auth URL**:

1. Go to **BTP Cockpit** → subaccount → **Instances and Subscriptions**
2. Find the **Joule** service instance → click it → **Service Keys** (or check `.env` for `JOULE_AUTH_URL`)
3. Alternatively just run `npx joule login` — it opens a browser for interactive SSO authentication. This always works and is the most reliable method.

**Required roles** (ask your BTP admin to assign these before trying to deploy):
- `extensibility_developer`
- `capabilityadmin`

### AICORE_SERVICE_KEY

The AI Core service key is the JSON credential blob your agent uses to call SAP GenAI Hub. It contains the AI API URL, client ID, client secret, and XSUAA token endpoint.

**Option A — BTP Cockpit (easiest):**
1. Go to **BTP Cockpit** → subaccount → **Instances and Subscriptions**
2. Find your **AI Core** service instance → click **···** → **Create Service Key**
3. Name it (e.g. `local-dev-key`), click **Create**
4. Click the key name to view it → copy the entire JSON

**Option B — CF CLI:**
```bash
# List service instances to find your AI Core instance name
cf services

# Create a service key (if one doesn't exist yet)
cf create-service-key <aicore-instance-name> local-dev-key

# Read the key
cf service-key <aicore-instance-name> local-dev-key
# Copy the entire JSON block that's printed
```

The key looks like this — you need the whole thing:
```json
{
  "serviceurls": {
    "AI_API_URL": "https://api.ai.prod-eu20.westeurope.azure.ml.hana.ondemand.com"
  },
  "clientid": "sb-...",
  "clientsecret": "...",
  "url": "https://<subaccount>.authentication.<region>.hana.ondemand.com"
}
```

On Cloud Foundry this key is injected automatically via the `ai_core_ext` or `aicore` service binding — you do not need to set it manually. It is only needed for local development.

---

## 3. First-time dev environment setup

### Python agent

```bash
# 1. Navigate to your project directory
cd my-a2a-agent

# 2. Create a virtual environment
python -m venv .venv

# 3. Activate it
# macOS / Linux:
source .venv/bin/activate
# Windows PowerShell:
.\.venv\Scripts\Activate.ps1
# Windows CMD:
.\.venv\Scripts\activate.bat

# 4. Install dependencies
pip install -r requirements.txt

# 5. Create your .env file
cp .env.example .env
# Then fill in the values — see section 4
```

**Why `.venv` is mandatory:** If your global Python has packages like `litellm`, `generative-ai-hub-sdk`, or older `pydantic`, they pin `httpx` or `pydantic` to versions incompatible with `a2a-sdk`. The virtual environment isolates your project completely.

**Make sure `.venv` is in `.cfignore`** so it doesn't get uploaded to CF (the buildpack installs dependencies fresh from `requirements.txt`):
```
# .cfignore
.venv
__pycache__
*.pyc
.env
.git
```

Without `.cfignore`, pushing uploads hundreds of megabytes of local packages that CF discards anyway.

### TypeScript Express agent

```bash
cd my-a2a-agent

npm install

# Compile TypeScript (required before cf push)
npm run build

# Run locally
npm start
```

Node.js v20+ is required. Check with `node --version`. If you are on an older version, use [nvm](https://github.com/nvm-sh/nvm) to switch: `nvm use 20`.

### TypeScript CAP agent

```bash
cd my-a2a-agent

npm install

# Run locally (CAP dev server with hot reload)
cds watch
# or
npm run watch

# Build for CF deployment (creates mta_archives/<name>.mtar)
mbt build

# Deploy to CF
cf deploy mta_archives/<name>_1.0.0.mtar
```

CAP requires the multiapps CF plugin. Install it once:
```bash
cf install-plugin multiapps
```

---

## 4. Local .env file

Create `.env` in your project root from `.env.example`. Never commit this file — add it to `.gitignore` and `.cfignore`.

```bash
# The GenAI Hub model to use (must be deployed on your AI Core instance)
MODEL_NAME=gpt-4.1

# AI Core resource group — use "default" unless an admin has set up another
AICORE_RESOURCE_GROUP=default

# For local development only: paste your full AI Core service key JSON
# On CF this is injected automatically via the service binding
AICORE_SERVICE_KEY={
  "serviceurls": {
    "AI_API_URL": "https://api.ai.prod-eu20.westeurope.azure.ml.hana.ondemand.com"
  },
  "clientid": "sb-...",
  "clientsecret": "...",
  "url": "https://<subaccount>.authentication.<region>.hana.ondemand.com"
}

# Server (usually don't need to change)
HOST=0.0.0.0
PORT=8080
```

> **How to find the correct MODEL_NAME:** Go to **AI Core** in BTP cockpit → **ML Operations** → **Deployments**. Click your deployment to see the model name (e.g. `gpt-4.1`, `gpt-4o-mini`). The `MODEL_NAME` env var must match exactly what's deployed.

> **How to find AICORE_RESOURCE_GROUP:** On the same Deployments page — each deployment belongs to a resource group shown in the list. It is almost always `default`. If you use a named resource group, the `ai_core_ext` service binding must have RBAC access to it (ask your BTP admin).

---

## 5. Logging in — how and when

Both the CF CLI and Joule CLI use short-lived tokens. You need to re-login whenever your session expires (typically every 12–24 hours for CF, varies for Joule).

### CF CLI

```bash
# Standard login (interactive — prompts for API endpoint, email, password)
cf login -a https://api.cf.<landscape>.hana.ondemand.com

# SSO login (recommended for enterprise/SAP accounts)
cf login --sso
# → prints a URL, open it in your browser, get a one-time passcode, paste it back

# Check current target (org, space, user)
cf target

# Switch space/org without re-entering credentials
cf target -o "<org-name>" -s "<space-name>"
```

**When you need to re-login:**
- Token expired (`cf apps` returns "Not logged in")
- After a long break (overnight, weekend)
- After switching to a different BTP subaccount

### Joule CLI

```bash
# Interactive SSO login (opens browser — recommended)
npx joule login

# Check login status and see which tenant you're targeting
npx joule status

# List deployed capabilities (good way to confirm you're logged in)
npx joule list
```

**When you need to re-login:**
- `npx joule status` shows "not authenticated" or "token expired"
- `npx joule deploy` fails with an authentication error
- After a long break

> **Important:** CF login and Joule CLI login are independent — you need both active when deploying. CF login is needed for `cf push`. Joule CLI login is needed for `npx joule deploy`. Check both before starting a deploy session.

---

## 6. Deployment flow

### Python / TypeScript Express

```bash
# 1. Make sure you're logged in to CF
cf target   # shows current org/space, or re-login if expired

# 2. Push the app
cf push

# 3. Check it started
cf app my-a2a-agent

# 4. Verify the agent card is accessible
curl https://my-a2a-agent.cfapps.<landscape>.hana.ondemand.com/.well-known/agent-card.json
# (a2a-sdk 1.0.3 uses /agent-card.json; 0.3.x uses /agent.json)
```

### TypeScript CAP

```bash
# 1. Build the MTA archive
mbt build

# 2. Deploy
cf deploy mta_archives/my-a2a-agent_1.0.0.mtar

# 3. Monitor
cf app my-a2a-agent-srv
```

### Joule capability

```bash
# 1. Make sure you're logged in to Joule CLI
npx joule status   # re-login if needed

# 2. Navigate to the capability directory
cd joule-capability

# 3. Compile and deploy in one step
npx joule deploy ./da.sapdas.yaml --compile -n "My_Agent"

# Assistant name rules:
# - Must start and end with a letter or digit
# - Only underscores between words (no spaces, no hyphens)
# - "My Agent" will fail; "My_Agent" works
```

---

## 7. Getting logs and debugging

### Live and recent logs

```bash
# Tail live logs (Ctrl+C to stop)
cf logs my-a2a-agent

# Last N lines (most useful when debugging a failed request)
cf logs my-a2a-agent --recent

# Show app details (memory, instances, status, crash count)
cf app my-a2a-agent

# Environment variables as seen by the running app (useful to check VCAP_SERVICES)
cf env my-a2a-agent
```

### What to look for in logs

CF logs prefix each line with the source: `[APP/PROC/WEB/0]` is your app, `[RTR]` is the router, `[API]` is CF platform events.

**Startup issues:** Look for `[APP/PROC/WEB/0] ERR` lines immediately after the app starts. Common: missing dependency, import error, failed VCAP_SERVICES parsing.

**Request failures:** After sending a message in Joule, look for:
- `[RTR]` lines showing the incoming HTTP POST — includes status code and response time
- `[APP/PROC/WEB/0] ERR` lines — Python tracebacks and error messages appear here (uvicorn and logging output both go to stderr → ERR)
- `[APP/PROC/WEB/0] OUT` lines — stdout, e.g. explicit `print()` calls

**Checking VCAP_SERVICES is populated:**
```bash
cf env my-a2a-agent | grep -A 3 "VCAP_SERVICES"
# Should show aicore binding. If empty, the service isn't bound properly.
```

**Checking a specific binding:**
```bash
cf env my-a2a-agent
# Look for the service name under "System-Provided" → VCAP_SERVICES
```

### Add logging to your agent

The single most effective debugging tool is `logger.error()` in your tool functions:

```python
import logging
logger = logging.getLogger(__name__)

try:
    resp = client.get(url, params=params)
    resp.raise_for_status()
except httpx.HTTPStatusError as e:
    logger.error("API error %s: %s", e.response.status_code, e.response.text)
    return {"error": str(e)}
```

This sends errors to CF logs. Without it, a failed API call is invisible — the LLM just says "I couldn't retrieve that information."

---

## 8. Common mistakes and quick checks

| Problem | Quick check | Fix |
|---------|-------------|-----|
| `cf push` fails — "not logged in" | `cf target` | `cf login --sso` |
| `npx joule deploy` fails — auth error | `npx joule status` | `npx joule login` |
| App crashes on startup | `cf logs myapp --recent` | Check for import errors, missing env vars |
| Agent card returns 404 | `curl <url>/.well-known/agent-card.json` | Check app is started: `cf app myapp` |
| Joule shows blank response | CF logs — did the agent complete? | Check `call_agent.yaml` uses `artifacts[0]` path (see `troubleshooting.md`) |
| 2nd Joule message fails | CF logs — TaskNotFoundError or terminal state | Add `JouleFriendlyRequestHandler` (see `troubleshooting.md`) |
| VCAP_SERVICES empty | `cf env myapp` | Check service is bound in `manifest.yml` and app was restaged |
| Pydantic version conflict | `pip list \| grep pydantic` (in venv) | Do not use `generative-ai-hub-sdk`; use `langchain-openai` instead |
| S/4HANA 400 on `$select` | CF logs — read exact error | Drop `$select`, discover available fields, add back only confirmed ones |
| `joule` command not found | `which joule` | Use `npx joule` instead |
| `cf` command not found | `which cf8` | Use `cf8` instead of `cf` |
