# Cloud Foundry Deployment Reference — CAP TypeScript (MTA)

This reference covers deploying a CAP-based LangGraph A2A agent to SAP BTP Cloud Foundry using MTA (Multi-Target Application) deployment.

## Table of Contents

1. [Project Structure](#1-project-structure)
2. [mta.yaml](#2-mtayaml)
3. [xs-security.json](#3-xs-securityjson)
4. [Local Development](#4-local-development)
5. [Deployment Steps](#5-deployment-steps)
6. [BTP Destination Configuration](#6-btp-destination-configuration)
7. [Troubleshooting](#7-troubleshooting)

---

## 1. Project Structure

```
<agent-name>/
├── srv/
│   ├── server.ts              # CAP bootstrap + A2A Express endpoints
│   ├── agent-executor.ts      # LangGraph agent orchestrator
│   ├── service.cds            # CDS service definition
│   ├── tools/
│   │   └── tools.ts           # Agent tools (Zod schemas)
│   └── utils/
│       ├── prompts.ts         # System prompt
│       ├── a2aToLangchain.ts  # A2A → LangChain message converter
│       ├── a2a-operations.ts  # A2A event creation helpers
│       └── helpers.ts         # Config and URL helpers
├── joule-capability/
│   ├── capability.sapdas.yaml
│   ├── capability_context.yaml
│   ├── da.sapdas.yaml
│   ├── functions/
│   │   └── call_agent.yaml
│   └── scenarios/
│       └── invoke_agent.yaml
├── package.json
├── tsconfig.json
├── mta.yaml                   # MTA deployment descriptor
├── xs-security.json           # XSUAA config (can be empty)
├── .cdsrc.sample.json         # Local dev config template
├── .env.example
└── README.md
```

---

## 2. mta.yaml

```yaml
_schema-version: 3.3.0
ID: <agent-name>
version: 1.0.0
description: "A2A agent on CAP"
parameters:
  enable-parallel-deployments: true
build-parameters:
  before-all:
    - builder: custom
      commands:
        - npx cds build --production
modules:
  - name: <agent-name>-srv
    type: nodejs
    path: gen/srv
    parameters:
      instances: 1
      buildpack: nodejs_buildpack
    build-parameters:
      builder: custom
      commands:
        - npm ci --omit=dev
      ignore:
        - node_modules
    provides:
      - name: srv-api
        properties:
          srv-url: ${default-uri}
    requires:
      - name: generative-ai-hub
      - name: destination-service

resources:
  - name: generative-ai-hub
    type: org.cloudfoundry.managed-service
    parameters:
      service: aicore
      service-plan: extended
  - name: destination-service
    type: org.cloudfoundry.managed-service
    parameters:
      service: destination
      service-plan: lite
```

### Key MTA concepts:

- **`build-parameters.before-all`**: Runs `npx cds build --production` to compile CDS and TypeScript into `gen/srv/`
- **`modules[0].path`**: Points to `gen/srv` (the compiled output), not `srv/` (the source)
- **`modules[0].build-parameters.commands`**: Runs `npm ci --omit=dev` inside `gen/srv` during staging
- **`resources`**: Defines managed service instances (AI Core, Destination) that get bound to the module

---

## 3. xs-security.json

Minimal XSUAA configuration (can start empty for NoAuthentication agents):

```json
{
  "xsappname": "<agent-name>",
  "tenant-mode": "dedicated"
}
```

If you need OAuth2 authentication for the agent, add scopes and role templates here and add an `xsuaa` resource to `mta.yaml`.

---

## 4. Local Development

```bash
# 1. Copy and edit the config
cp .cdsrc.sample.json .cdsrc.json
# Edit .cdsrc.json with your AI Core service key for local GenAI Hub access

# 2. Install dependencies
npm install

# 3. Start in hybrid mode (local server, remote services)
npm run watch
# → http://localhost:4004

# 4. Test agent card
curl http://localhost:4004/.well-known/agent.json
```

### .cdsrc.sample.json

```json
{
  "cds": {
    "requires": {
      "auth": {
        "kind": "dummy"
      }
    }
  }
}
```

For local GenAI Hub access, set the `AICORE_SERVICE_KEY` environment variable with your AI Core service key JSON.

---

## 5. Deployment Steps

### Prerequisites

1. **CF CLI**: `cf version`
2. **MBT**: `mbt --version` (install: `npm install -g mbt`)
3. **CDS DK**: `npx cds --version` (install: `npm install -g @sap/cds-dk`)
4. **Node.js 24+**: `node --version`
5. **Logged in**: `cf login -a <api-endpoint>`

### Build & Deploy

```bash
# 1. Install dependencies
npm install

# 2. Build the MTA archive
mbt build

# 3. Deploy to Cloud Foundry
cf deploy mta_archives/<agent-name>_1.0.0.mtar

# 4. Verify
cf apps
cf logs <agent-name>-srv --recent

# 5. Test agent card
curl https://<agent-name>-srv.cfapps.<landscape>.hana.ondemand.com/.well-known/agent.json
```

### One-liner (from package.json)

```bash
npm run deploy
# Equivalent to: mbt build && cf deploy mta_archives/<agent-name>_1.0.0.mtar
```

---

## 6. BTP Destination Configuration

Identical to Express agents — the destination points to the CF app URL regardless of framework.

| Property | Value |
|----------|-------|
| Name | `MyAgent_A2A` |
| Type | HTTP |
| URL | `https://<agent-name>-srv.cfapps.<landscape>.hana.ondemand.com` |
| Proxy Type | Internet |
| Authentication | NoAuthentication |

Additional property: `HTML5.DynamicDestination` = `true`

Note: For MTA-deployed apps, the route is typically `<module-name>.cfapps.<landscape>.hana.ondemand.com` where `<module-name>` is the module name from `mta.yaml` (e.g., `<agent-name>-srv`).

---

## 7. Troubleshooting

### mbt not installed

```bash
npm install -g mbt
```

### CDS build fails

- Check that `@sap/cds-dk` is installed: `npm install -g @sap/cds-dk`
- Verify `service.cds` syntax: `npx cds compile srv/`
- Check TypeScript errors: `npx tsc --noEmit`

### Module not found after deploy

- The MTA build copies `gen/srv` to CF. Ensure `npx cds build --production` ran successfully
- Check the `gen/srv` directory exists locally after `mbt build`

### AI Core service binding issues

- Verify the AI Core service instance exists: `cf services | grep aicore`
- Check the service plan matches: `extended` (not `standard`)
- Review VCAP_SERVICES: `cf env <agent-name>-srv | grep -A 20 aicore`

### Memory issues

- CAP + LangGraph typically needs 512M–1G. Adjust in `mta.yaml`:
  ```yaml
  parameters:
    instances: 1
    buildpack: nodejs_buildpack
    memory: 1G
  ```

### App crashes with "Authentication kind jwt configured, but no XSUAA instance bound"

CAP defaults to JWT auth in production. For A2A agents using `NoAuthentication`, the `package.json` must include:

```json
{
  "cds": {
    "requires": {
      "auth": { "kind": "dummy" }
    }
  }
}
```

This tells CAP to skip JWT validation. The scaffold already includes this configuration.

### Agent card returns 404

The `agentCardHandler` from `@a2a-js/sdk/server/express` can conflict with CAP middleware. Use a plain `app.get()` handler instead of `agentCardHandler` in `srv/server.ts`:

```typescript
app.get("/.well-known/agent.json", (_req, res) => {
    res.json(agentCard);
});
```

The scaffold already uses this pattern.

### @a2a-js/sdk import issues

- The SDK uses subpath exports: import from `@a2a-js/sdk/server` for server classes
- Types come from `@a2a-js/sdk` directly
- If you encounter patch-related issues, the swiss-knife repo uses `patch-package` for SDK fixes
