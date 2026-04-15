# Joule Capability with A2A Action — Reference

This reference covers creating a Joule capability that connects to your external agent via the A2A protocol using the multi-file DTA format.

## Table of Contents

1. [File Structure](#1-file-structure)
2. [capability.sapdas.yaml](#2-capabilitysampdasyaml)
3. [da.sapdas.yaml](#3-dasampdasyaml)
4. [Functions (call_agent.yaml)](#4-functions)
5. [Scenarios (invoke_agent.yaml)](#5-scenarios)
6. [Capability Context (capability_context.yaml)](#6-capability-context)
7. [Multi-Turn Conversations](#7-multi-turn-conversations)
8. [Joule CLI Commands](#8-joule-cli-commands)
9. [Destination Setup for Joule](#9-destination-setup-for-joule)
10. [Prerequisites and Roles](#10-prerequisites-and-roles)
11. [End-to-End Example](#11-end-to-end-example)

---

## 1. File Structure

A Joule capability for A2A agent integration uses multiple YAML files organized in a directory:

```
joule-capability/
├── capability.sapdas.yaml       # Capability metadata + system aliases
├── capability_context.yaml      # Variable declarations for multi-turn (contextId, taskId)
├── da.sapdas.yaml               # Digital assistant deployment descriptor (at parent or same level)
├── functions/
│   └── call_agent.yaml          # A2A agent invocation function
└── scenarios/
    └── invoke_agent.yaml        # User intent → function mapping
```

The `da.sapdas.yaml` is the top-level descriptor that points to the capability folder. It can be at the parent level or same level depending on your project structure.

---

## 2. capability.sapdas.yaml

Defines the capability metadata and the BTP destination alias.

```yaml
schema_version: 3.28.0

metadata:
  namespace: <company-namespace>
  name: <agent_name_a2a>
  version: 1.0.0
  display_name: "<Agent Display Name>"
  description: <What this agent does — used for Joule's intent matching>

system_aliases:
  <AliasName>:
    destination: <DESTINATION_NAME>
```

### Key fields:

- **`schema_version`**: Must be `3.28.0` for A2A agent-request support
- **`metadata.namespace`**: Your company namespace (e.g., `com.sap.paa`, `com.mycompany`)
- **`metadata.name`**: Unique name, underscore-separated (e.g., `my_agent_a2a`)
- **`system_aliases`**: Maps an alias name to a BTP destination. The alias is used in `call_agent.yaml`
- **`system_aliases.<AliasName>.destination`**: Must match the exact BTP destination name

### Example:

```yaml
schema_version: 3.28.0

metadata:
  namespace: com.sap.paa
  name: sales_optimization_agent_a2a
  version: 1.0.0
  display_name: "Sales Optimization Agent A2A Connector"
  description: Connects the Sales Optimization Agent to Joule for recommending adjustments to sales inquiries.

system_aliases:
  SalesOptimizationAgent:
    destination: SALES_OPTIMIZATION_AGENT_A2A
```

---

## 3. da.sapdas.yaml

The digital assistant deployment descriptor. This is the entry point for `joule compile` and `joule deploy`.

```yaml
schema_version: 1.4.0
name: <agent_name_a2a>
capabilities:
  - type: local
    name: <agent_name_a2a>
    folder: ./<capability-subfolder>
```

### Key fields:

- **`schema_version`**: `1.4.0` for the DA descriptor (different from the capability schema version)
- **`name`**: Must match the capability's `metadata.name`
- **`capabilities[0].folder`**: Path to the directory containing `capability.sapdas.yaml` (relative to `da.sapdas.yaml`)

> **Note:** Do NOT include `enable_native_agenticness` or `conversational_search` fields — these require schema version 1.5.0-beta and will cause deploy errors with schema 1.4.0.

### Example:

```yaml
schema_version: 1.4.0
name: sales_optimization_agent_a2a
capabilities:
  - type: local
    name: sales_optimization_agent_a2a
    folder: ./
```

---

## 4. Functions

`functions/call_agent.yaml` — defines the A2A agent invocation with multi-turn support.

```yaml
parameters:
  - name: contextId
    optional: true
  - name: taskId
    optional: true

action_groups:
  - actions:
      - type: status-update
        message: <? "Invoking Agent" ?>

      - type: agent-request
        agent_type: remote
        system_alias: <AliasName>
        body: >
          <? (contextId == null || contextId.isEmpty()) && (taskId == null || taskId.isEmpty())
             ? null
             : '{ "contextId": "' + contextId + '", "taskId": "' + taskId + '" }' ?>
        result_variable: result

      - type: set-variables
        variables:
          - name: contextId
            value: <? result.body.contextId ?>
          - name: taskId
            value: <? result.body.id ?>

      - type: message
        message:
          type: text
          content: "<? result.body.status.message.parts[0].text ?>"
          markdown: true

result:
  contextId: "<? contextId ?>"
  taskId: "<? taskId ?>"
```

### Key elements:

- **`agent-request` action**: The core A2A action type that triggers communication with your agent
  - `agent_type: remote` indicates this is a BYOA (Bring Your Own Agent) call
  - `system_alias` must match an alias from `capability.sapdas.yaml`
  - `body` passes contextId/taskId for multi-turn conversations (null on first call)
  - `result_variable` captures the A2A response

- **`status-update` action**: Shows a message in Joule while the agent processes

- **`set-variables` action**: Captures contextId and taskId from the response for subsequent turns

- **`message` action**: Displays the agent's response text to the user with markdown rendering

- **`result` block**: Returns contextId/taskId to the scenario for capability_context persistence

---

## 5. Scenarios

`scenarios/invoke_agent.yaml` — maps user intent to the function.

```yaml
description: >
  <Describe when Joule should invoke this agent. Be specific about user intents
  and include example phrases. This description is critical for Joule's routing.>

target:
  type: function
  name: call_agent
  parameters:
    - name: contextId
      value: $capability_context.contextId
    - name: taskId
      value: $capability_context.taskId

capability_context:
  - name: contextId
    value: $target_result.contextId
  - name: taskId
    value: $target_result.taskId
```

### Key elements:

- **`description`**: Critical for Joule's intent matching. Be specific and include example phrases.
- **`target.type: function`**: Points to a function file in `functions/`
- **`target.parameters`**: Passes persisted context (contextId/taskId) from `capability_context` to the function
- **`capability_context`**: Persists values from the function result across conversation turns

### Example:

```yaml
description: >
  Everything related to sales inquiries and orders. Call this whenever the user
  asks for optimizing any sales inquiry or order from any customer. For example,
  "Optimize the latest sales inquiry from customer Altinova",
  "Create a sales quotation for the order".

target:
  type: function
  name: call_agent
  parameters:
    - name: contextId
      value: $capability_context.contextId
    - name: taskId
      value: $capability_context.taskId

capability_context:
  - name: contextId
    value: $target_result.contextId
  - name: taskId
    value: $target_result.taskId
```

---

## 6. Capability Context (`capability_context.yaml`)

`capability_context.yaml` — declares variables that persist across conversation turns. **Required** when using `$capability_context` references in scenarios.

```yaml
variables:
  - name: contextId
  - name: taskId
```

This file must exist at the root of the capability directory (alongside `capability.sapdas.yaml`). Without it, the Joule compiler will fail with:
> *"contextId" / "taskId" must be declared within capability_context.yaml as variable name*

---

## 7. Multi-Turn Conversations

The multi-turn pattern works as follows:

1. **First turn**: User sends a prompt → Joule routes to `invoke_agent` → `call_agent` is called with `contextId=null, taskId=null` → agent creates a new task → response includes `contextId` and `taskId` → stored in `capability_context`

2. **Subsequent turns**: User sends follow-up → Joule routes to same scenario → `call_agent` receives persisted `contextId` and `taskId` from `capability_context` → agent resumes the existing task → response updates `capability_context`

This flow is fully handled by the `body` expression in `call_agent.yaml`:
- On first call: body is `null` (agent creates new context)
- On follow-up: body contains `{ "contextId": "...", "taskId": "..." }` (agent resumes)

---

## 8. Joule CLI Commands

### Installation

```bash
npm install -g @sap/joule-cli
```

### Authentication

```bash
# Option A: Interactive SSO (opens browser)
joule login 

# Option B: From .env file (recommended for automation)
# Requires JOULE_AUTH_URL + JOULE_USERNAME/JOULE_PASSWORD in .env
joule login --use-env

# Option C: Explicit credentials (CI/CD)
joule login --authurl <AUTH_URL> --clientid <ID> --clientsecret <SECRET> --username <USER> --password <PASS>
```

### Compile + Deploy

```bash
# Navigate to the directory containing da.sapdas.yaml
cd joule-capability

# Compile + deploy in a single step (recommended)
joule deploy ./da.sapdas.yaml --compile -n "<assistant_name>"

# Or compile and deploy separately:
joule compile ./                      # compiles → .daar
joule deploy ./da.sapdas.yaml         # deploys the .daar
```

### Other commands

```bash
joule list              # List deployed capabilities
joule status            # Check login status
joule --version         # Check CLI version
```

---

## 9. Destination Setup for Joule

The BTP destination is the bridge between Joule and your Cloud Foundry agent.

### Requirements:

- Destination must be in the **same BTP subaccount** where Joule is provisioned
- Destination name must **exactly match** `system_aliases.<AliasName>.destination` in `capability.sapdas.yaml`
- Destination URL must point to the **base URL** of your agent (without `/.well-known/agent.json`)

### Configuration:

| Property | Value |
|----------|-------|
| Name | `MyAgent_A2A` |
| Type | HTTP |
| URL | `https://<agent-app>.cfapps.<landscape>.hana.ondemand.com` |
| Proxy Type | Internet |
| Authentication | NoAuthentication |

### Additional properties:

| Property | Value |
|----------|-------|
| `HTML5.DynamicDestination` | `true` |
| `WebIDEEnabled` | `true` |

---

## 10. Prerequisites and Roles

### BTP Subaccount Requirements:

1. **Joule service** provisioned and configured
2. **Cloud Foundry Runtime** enabled
3. **AI Core service** (if using SAP GenAI Hub)
4. **Destination service** (for BTP destinations)
5. **IAS trust** configured (for Joule CLI authentication)

### Required Roles:

- **`capabilityadmin`** — deploy capabilities to Joule
- **`extensibility_developer`** — create/modify extension capabilities

### Joule CLI Prerequisites:

- Node.js 20+ installed
- `@sap/joule-cli` package installed globally
- Joule DTA schema **3.28.0+** on your tenant for `agent-request` support

---

## 11. End-to-End Example

### Complete file set for a currency exchange agent:

**`capability.sapdas.yaml`:**
```yaml
schema_version: 3.28.0

metadata:
  namespace: com.mycompany
  name: currency_exchange_agent_a2a
  version: 1.0.0
  display_name: "Currency Exchange Agent"
  description: An A2A agent that provides real-time currency exchange rates and conversions.

system_aliases:
  CurrencyAgent:
    destination: CURRENCY_AGENT_A2A
```

**`da.sapdas.yaml`:**
```yaml
schema_version: 1.4.0
name: currency_exchange_agent_a2a
capabilities:
  - type: local
    name: currency_exchange_agent_a2a
    folder: ./
```

**`capability_context.yaml`:**
```yaml
variables:
  - name: contextId
  - name: taskId
```

**`functions/call_agent.yaml`:**
```yaml
parameters:
  - name: contextId
    optional: true
  - name: taskId
    optional: true

action_groups:
  - actions:
      - type: status-update
        message: <? "Checking exchange rates..." ?>

      - type: agent-request
        agent_type: remote
        system_alias: CurrencyAgent
        body: >
          <? (contextId == null || contextId.isEmpty()) && (taskId == null || taskId.isEmpty())
             ? null
             : '{ "contextId": "' + contextId + '", "taskId": "' + taskId + '" }' ?>
        result_variable: result

      - type: set-variables
        variables:
          - name: contextId
            value: <? result.body.contextId ?>
          - name: taskId
            value: <? result.body.id ?>

      - type: message
        message:
          type: text
          content: "<? result.body.status.message.parts[0].text ?>"
          markdown: true

result:
  contextId: "<? contextId ?>"
  taskId: "<? taskId ?>"
```

**`scenarios/invoke_agent.yaml`:**
```yaml
description: >
  Invoke this agent when the user asks about currency exchange rates,
  currency conversions, or wants to know how much a certain amount of
  money is worth in another currency. Examples: "What is 100 USD in EUR?",
  "Show me the exchange rate between GBP and JPY",
  "Convert currencies for me".

target:
  type: function
  name: call_agent
  parameters:
    - name: contextId
      value: $capability_context.contextId
    - name: taskId
      value: $capability_context.taskId

capability_context:
  - name: contextId
    value: $target_result.contextId
  - name: taskId
    value: $target_result.taskId
```

### Deployment checklist:

1. Agent deployed to CF and agent card accessible at `/.well-known/agent.json`
2. BTP destination `CURRENCY_AGENT_A2A` created pointing to the agent URL
3. Joule CLI installed and logged in
4. All YAML files saved in `joule-capability/` directory
5. Run `joule deploy ./da.sapdas.yaml --compile -n "currency_exchange_agent_a2a"`
6. Test in Joule by asking a currency question
