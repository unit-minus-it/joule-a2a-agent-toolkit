# Joule A2A Agent — Known Issues and Fixes

This file documents issues encountered during real end-to-end development of a Python A2A agent on SAP BTP Cloud Foundry with a2a-sdk 1.0.3. Read this before generating Python agent code or debugging a deployment.

---

## a2a-sdk 1.0.3 — Breaking changes from 0.x

The scaffold templates in this toolkit were written for a2a-sdk 0.3.x. If you are using a2a-sdk 1.0.3 (current latest), every item below must be changed manually.

### `A2AStarletteApplication` removed

```python
# WRONG (0.x)
from a2a.server.apps import A2AStarletteApplication
app = A2AStarletteApplication(agent_executor=..., http_handler=...)

# CORRECT (1.0.3)
from starlette.applications import Starlette
from a2a.server.routes.jsonrpc_routes import create_jsonrpc_routes
from a2a.server.routes.agent_card_routes import create_agent_card_routes

request_handler = DefaultRequestHandler(
    agent_executor=agent_executor,
    task_store=InMemoryTaskStore(),
    agent_card=agent_card,          # required — was not in 0.x
)
app = Starlette(routes=[
    *create_agent_card_routes(agent_card),
    *create_jsonrpc_routes(request_handler, rpc_url="/"),
])
```

### Agent card endpoint changed

- 0.x served at `/.well-known/agent.json`
- 1.0.3 serves at `/.well-known/agent-card.json`

### `TextPart` removed — use `Part(text=...)`

```python
# WRONG (0.x)
from a2a.types import TextPart
parts = [TextPart(text="hello")]

# CORRECT (1.0.3)
from a2a.types import Part
parts = [Part(text="hello")]
```

### `TaskState` enum values renamed (SCREAMING_SNAKE_CASE)

```python
# WRONG (0.x)
TaskState.submitted / TaskState.working / TaskState.completed

# CORRECT (1.0.3)
TaskState.TASK_STATE_SUBMITTED
TaskState.TASK_STATE_WORKING
TaskState.TASK_STATE_COMPLETED
TaskState.TASK_STATE_INPUT_REQUIRED
```

### `Role` enum renamed

```python
Role.agent  →  Role.ROLE_AGENT
Role.user   →  Role.ROLE_USER
```

### `AgentCard` fields renamed (camelCase → snake_case)

```python
# WRONG (0.x)
AgentCard(
    url="https://...",
    defaultInputModes=["text/plain"],
    defaultOutputModes=["text/plain"],
)

# CORRECT (1.0.3)
from a2a.types import AgentCard, AgentInterface
AgentCard(
    supported_interfaces=[AgentInterface(url="https://...")],
    default_input_modes=["text/plain"],
    default_output_modes=["text/plain"],
)
```

### `AgentCapabilities` fields renamed

```python
pushNotifications=False  →  push_notifications=False
```

### `enqueue_event` is now async — use `TaskUpdater`

```python
# WRONG (0.x) — enqueue_event was synchronous
event_queue.enqueue_event(artifact)

# CORRECT (1.0.3) — use TaskUpdater, all methods are async
from a2a.server.tasks.task_updater import TaskUpdater

async def execute(self, context, event_queue):
    updater = TaskUpdater(event_queue, task_id, context_id)
    # Do NOT call update_status before add_artifact — see bug below
    response = agent.invoke(...)
    await updater.add_artifact(parts=parts)
    await updater.update_status(TaskState.TASK_STATE_COMPLETED)
```

### `enable_v0_3_compat=True` required for Joule

Joule sends `message/send` (A2A v0.3 method name). a2a-sdk 1.0.3 renamed its internal RPC methods to gRPC style (`SendMessage`). Without the compat flag, every Joule request returns `-32601 Method not found`.

```python
# WRONG — Joule's message/send is not found
*create_jsonrpc_routes(request_handler, rpc_url="/"),

# CORRECT
*create_jsonrpc_routes(request_handler, rpc_url="/", enable_v0_3_compat=True),
```

---

## Bug: `InvalidAgentResponseError: Agent should enqueue Task before TaskStatusUpdateEvent`

**Symptom:** Every request fails with this error in the logs.

**Cause:** In a2a-sdk 1.0.3, `active_task.py` blocks `TaskStatusUpdateEvent` until the task has been registered via a `TaskArtifactUpdateEvent` first. Calling `update_status()` before `add_artifact()` triggers the guard.

**Fix:** Always call `add_artifact()` before `update_status()`. Drop all intermediate `SUBMITTED`/`WORKING` status calls — they are not required and break new tasks.

```python
# WRONG
await updater.update_status(TaskState.TASK_STATE_SUBMITTED)  # crashes
response = agent.invoke(...)
await updater.add_artifact(parts=parts)
await updater.update_status(TaskState.TASK_STATE_COMPLETED)

# CORRECT
response = agent.invoke(...)
await updater.add_artifact(parts=parts)
await updater.update_status(TaskState.TASK_STATE_COMPLETED)
```

---

## Bug: `TaskNotFoundError` / `Task in terminal state` — multi-turn conversations stop working after first message

**Symptom:** The first Joule message in a conversation works. Every follow-up message fails. The error differs by SDK and state:

```
# Python (a2a-sdk 1.0.3) — task still in store but completed:
InvalidParamsError: Task ea811b38-... is in terminal state: 3

# Python — after app restart, store empty:
TaskNotFoundError: Task dcc85776-... not found

# TypeScript (@a2a-js/sdk 0.3.10):
TaskNotFoundError: Task not found  (JSON-RPC code -32001)
```

**Root cause (both SDKs):** Joule preserves `contextId` and `taskId` across conversation turns and re-sends the completed task's ID on every follow-up. The SDK looks up that `taskId` in the task store and raises immediately because a completed task cannot be reopened.

The `contextId` is separate — it is the conversation thread identifier used for LangGraph memory. It must be preserved. Only `taskId` must be cleared.

---

### Fix — Python (`a2a-sdk 1.0.3`)

In `DefaultRequestHandlerV2._setup_active_task()`, the store lookup happens at lines 190–196 **before** any `RequestContextBuilder` is called (line 199). Clearing `task_id` inside a `RequestContextBuilder` does **not** work — the error has already been raised.

Subclass `DefaultRequestHandlerV2` and clear `task_id` before `super()`:

```python
from a2a.server.request_handlers.default_request_handler_v2 import DefaultRequestHandlerV2

class JouleFriendlyRequestHandler(DefaultRequestHandlerV2):
    async def _setup_active_task(self, params, call_context):
        # Joule reuses taskId across turns. Setting task_id = "" causes
        # (params.message.task_id or None) to evaluate to None, skipping
        # the store lookup. context_id is untouched — memory is preserved.
        params.message.task_id = ""
        return await super()._setup_active_task(params, call_context)

request_handler = JouleFriendlyRequestHandler(
    agent_executor=agent_executor,
    task_store=InMemoryTaskStore(),
    agent_card=agent_card,
)
```

---

### Fix — TypeScript (`@a2a-js/sdk 0.3.10`)

`DefaultRequestHandler.sendMessage()` and `sendMessageStream()` are public overridable methods. Override both and set `params.message.taskId = undefined` before delegating to `super()`:

```typescript
import {
  DefaultRequestHandler,
  InMemoryTaskStore,
  ServerCallContext,
} from "@a2a-js/sdk/server";

class JouleFriendlyRequestHandler extends DefaultRequestHandler {
  override async sendMessage(
    params: Parameters<DefaultRequestHandler["sendMessage"]>[0],
    context?: ServerCallContext
  ) {
    // Joule reuses taskId across turns, causing TaskNotFoundError (-32001)
    // when DefaultRequestHandler looks up the previous completed task.
    // Clearing it here forces a new task per turn while preserving contextId,
    // which LangGraph uses as thread_id for cross-turn memory.
    params.message.taskId = undefined;
    return super.sendMessage(params, context);
  }

  override async *sendMessageStream(
    params: Parameters<DefaultRequestHandler["sendMessageStream"]>[0],
    context?: ServerCallContext
  ) {
    params.message.taskId = undefined;
    yield* super.sendMessageStream(params, context);
  }
}

const requestHandler = new JouleFriendlyRequestHandler(
  agentCard,
  taskStore,
  agentExecutor
);
```

> **Both `sendMessage` and `sendMessageStream` must be overridden.** Joule uses `sendMessage` when `streaming: false` in the Agent Card and `sendMessageStream` when `streaming: true`. Overriding only one leaves the other broken.

---

## Bug: Joule shows blank response after successful agent run

**Symptom:** CF logs show the agent completed and produced a response. Joule shows a blank message or nothing.

**Cause:** The `call_agent.yaml` reference in this toolkit uses:
```yaml
content: "<? result.body.status.message.parts[0].text ?>"
```
This was correct for a2a-sdk 0.3.x. In 1.0.3, `TaskUpdater.add_artifact()` places the response in `task.artifacts`. When `update_status(TASK_STATE_COMPLETED)` is called, `task.status.message` is not set — it is null.

**Fix:** Change the response extraction path in `joule-capability/functions/call_agent.yaml`:

```yaml
- type: message
  message:
    type: text
    content: "<? result.body.artifacts[0].parts[0].text ?>"
    markdown: true
```

**Rule:** Match the path to your executor's pattern:
- `TaskUpdater.add_artifact(parts=...)` → `result.body.artifacts[0].parts[0].text`
- `updater.update_status(state, message=Message(...))` → `result.body.status.message.parts[0].text`

After changing `call_agent.yaml`, redeploy the Joule capability.

---

## Bug: LLM must be initialized lazily on Cloud Foundry

**Symptom:** App fails to start on CF. `VCAP_SERVICES` access or credentials resolution fails at import time.

**Cause:** On CF, `VCAP_SERVICES` is injected as an environment variable when the container starts, not at build time. If `get_llm()` is called at module level or at `__init__` time, it runs before the environment is ready.

**Fix:** Use lazy initialization — only call `get_llm()` on the first actual request:

```python
class MyAgent:
    def __init__(self):
        self._graph = None
        self.tools = get_tools()

    def _get_graph(self):
        if self._graph is None:
            self._graph = create_react_agent(get_llm(), self.tools, ...)
        return self._graph

    def invoke(self, query, session_id):
        return self._get_graph().invoke(...)
```

---

## Bug: AI Core `Deployment not found` / RBAC errors

**`openai.NotFoundError: Deployment not found`**

`AICORE_RESOURCE_GROUP` in `manifest.yml` does not match the resource group where the AI Core deployment actually lives. Read the resource group from AI Core console → ML Operations → Deployments. Never guess.

**`404` + response header `ai-external-failure: true`**

Occurs with `foundation-models` scenario deployments when the Azure OpenAI backend doesn't have the requested model available. Switch to an `orchestration` scenario deployment. These use a different API format (see next item).

**`RBAC: access denied`**

The `ai_core_ext` service binding only has inference permissions for the `default` resource group. Named resource groups require explicit RBAC grants configured by a BTP admin. Always use `AICORE_RESOURCE_GROUP: default` unless an admin has granted access to another group.

---

## Bug: `ChatOpenAI` incompatible with SAP AI Core orchestration endpoint

**Cause:** `ChatOpenAI` sends OpenAI-format requests to `/chat/completions`. The AI Core orchestration deployment expects requests to `/completion` with a completely different payload structure (`orchestration_config`, `messages_history`, etc.).

**Fix:** Replace `ChatOpenAI` with a custom `BaseChatModel` subclass (`OrchestrationChatModel`) that speaks the orchestration API directly. Key implementation points:
- Fetch a fresh OAuth token per call (client credentials) — cached tokens cause intermittent auth failures
- Convert `SystemMessage` → `template[]`, all other messages → `messages_history[]`
- Override `bind_tools()` to format tools into `model_params.tools`
- Use `model_copy(update={"bound_tools": formatted})` (Pydantic v2 pattern) when returning a new model instance with tools bound

This only applies to orchestration-scenario deployments. If your AI Core has a working foundation-models deployment that speaks the OpenAI protocol, standard `ChatOpenAI` works fine.

---

## Bug: `create-destination.sh` script fails

**Root cause 1 — CF CLI alias:** The script calls `cf` but in some environments the CF CLI is only available as `cf8`. The check fails immediately.

**Root cause 2 — Flat credential structure:** The script extracts `credentials.uaa.clientid` from the destination service key. Some destination service instances return a flat structure with no `uaa` nesting — credentials are at `credentials.clientid` directly.

**Fix:** Use manual curl steps instead of the script:

```bash
# 1. Get service key
cf create-service-key <destination-service-instance> temp-key
cf service-key <destination-service-instance> temp-key
# Note whether credentials are flat or nested under "uaa"

# 2. Get OAuth token
curl -X POST "<url>/oauth/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "client_id=<clientid>" \
  --data-urlencode "client_secret=<clientsecret>"

# 3. Create destination
curl -X POST "<uri>/destination-configuration/v1/subaccountDestinations" \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{
    "Name": "<DESTINATION_NAME>",
    "Type": "HTTP",
    "URL": "https://<agent-app>.cfapps.<landscape>.hana.ondemand.com",
    "ProxyType": "Internet",
    "Authentication": "NoAuthentication",
    "HTML5.DynamicDestination": "true"
  }'
```

---

## Bug: S/4HANA OData v4 field names differ from OData v2

**Symptom:** S/4HANA returns HTTP 400:
```
Property 'TotalNetAmount' not found in type 'PurchaseOrder'
Property 'OrderQuantityUnit' not found in type 'PurchaseOrderItem'
```

**Cause:** OData v4 (`srvd_a2x` services) exposes different field names than OData v2. Fields from SAP API Business Hub documentation, tutorials, or v2 experience may not exist in v4. The error always names the exact invalid field.

**Fix:**
1. Never assume `$select` field names without testing against the live endpoint
2. Drop `$select` on first pass — let the API return everything, inspect the actual field names in the response
3. Add `logger.error("error %s: %s", e.response.status_code, e.response.text)` to every `except httpx.HTTPStatusError` block so errors are visible in CF logs (`cf logs <app> --recent`)
4. Only add `$select` once you've confirmed the field names from a live response

---

---

## Bug: HTTP 403 — CSRF token validation failed (OData v2 mutations)

**Symptom:** POST / PUT / DELETE to an S/4HANA OData v2 service returns:
```
HTTP 403
"CSRFToken validation failed"
```

**Cause:** OData v2 CSRF tokens are session-bound. S/4HANA issues a session cookie (`sap-usercontext`) alongside the CSRF token in the `Fetch` response. The subsequent mutating request must include **both** the token (`x-csrf-token` header) **and** the session cookie (`Cookie` header). The Cloud SDK's `executeHttpRequest` does not carry cookies between separate calls, so a plain `x-csrf-token` fetch followed by a POST without the cookie will always fail.

**Fix:** Capture the `set-cookie` header from the CSRF fetch and include it in the POST:

```typescript
async function fetchCsrfToken(destinationName: string, odataBasePath: string) {
  const response = await executeHttpRequest(destOptions(destinationName), {
    method: "GET",
    url: `${odataBasePath}/`,
    headers: { "x-csrf-token": "Fetch", Accept: "application/json" },
  });
  const token = response.headers["x-csrf-token"];
  if (!token || token === "Required") throw new Error("Failed to retrieve CSRF token");
  const raw = response.headers["set-cookie"];
  const cookie = Array.isArray(raw) ? raw.join("; ") : raw;
  return { token: token as string, cookie };
}

// In the mutating tool:
const { token, cookie } = await fetchCsrfToken(DESTINATION, ODATA_BASE);
await executeHttpRequest(destOptions(DESTINATION), {
  method: "POST",
  url: `${ODATA_BASE}/EntitySet`,
  data: payload,
  headers: {
    "Content-Type": "application/json",
    "x-csrf-token": token,
    ...(cookie ? { Cookie: cookie } : {}),
  },
});
```

This pattern is included in the generated `src/destination.ts` when using `--with-principal-propagation`.

---

## Bug: `invalid_grant` — "Error in ST program SAML2_ASSERTION when importing XML data" (S/4HANA PP)

**Symptom:** The OAuth2SAMLBearerAssertion token exchange fails with:
```json
{ "error": "invalid_grant", "error_description": "Provided authorization grant is invalid. Exception was Error in ST program SAML2_ASSERTION when importing XML data." }
```

**Cause:** S/4HANA's ABAP Simple Transformation program `SAML2_ASSERTION` failed to deserialize the SAML assertion XML. This is almost always caused by the **wrong signing certificate** uploaded to the S/4HANA Communication System's OAuth 2.0 Identity Provider.

The most common mistake: downloading the SAML metadata XML from BTP Trust Configuration and trying to upload it to S/4HANA. S/4HANA's ABAP XML parser cannot handle the full metadata XML structure.

**Fix:** Upload only the raw X.509 certificate:
- Source: **BTP Cockpit → Connectivity → Destination Trust → Active Trust Certificate → Export**
- This exports a plain `.pem` file
- Upload this certificate in the S/4HANA Communication System → OAuth 2.0 Identity Provider → Signing Certificate

After uploading the correct certificate, re-trigger the flow. The `invalid_grant` error should resolve.

---

## Bug: `invalid_client` — SAML Issuer mismatch (S/4HANA PP)

**Symptom:**
```json
{ "error": "invalid_client", "error_description": "The supplied OAuth 2.0 client credentials are invalid." }
```

**Cause:** The SAML Issuer configured in S/4HANA's Communication System does not match the entity ID used by BTP Destination Service to sign the assertion.

BTP has **two different SAML entity IDs**:
- **XSUAA entity** (wrong for PP): `https://<subdomain>.authentication.<region>.hana.ondemand.com`
- **Destination Service entity** (correct for PP): `cfapps.<region>.hana.ondemand.com/<subaccount-guid>`

The Destination Service signs the SAML assertion with its own entity ID. S/4HANA must have that exact entity ID registered as the SAML Issuer.

**Fix:** In S/4HANA Communication System → OAuth 2.0 Identity Provider, set the SAML Issuer to:
```
cfapps.<region>.hana.ondemand.com/<subaccount-guid>
```

Find your values: region from the CF API URL (e.g. `eu20`, never `eu20-001`); subaccount GUID from BTP Cockpit → subaccount Overview.

---

## Bug: HTTP 400 — Wrong OData v2 field names for S/4HANA

**Symptom:**
```
HTTP 400: Property 'RequestedQuantity' is invalid
HTTP 400: Property 'OrderQuantityUnit' is invalid
```

**Cause:** OData v2 field names must exactly match the S/4HANA service definition. Common mismatches between what documentation shows, what v4 uses, and what v2 actually accepts:

| Wrong (assumed) | Correct (OData v2) |
|----------------|-------------------|
| `RequestedQuantity` | `OrderQuantity` |
| `OrderQuantityUnit` | `PurchaseOrderQuantityUnit` |
| `NetPriceCurrency` | not a field — currency inherited from header |

**Fix:** On first integration, drop `$select` and all field filters. Let the API return the full entity. Inspect the actual field names from the live response. Only then add specific fields to your payload or `$select` filter.

---

## Summary table

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Method not found` (-32601) | Joule calls v0.3 method names; SDK 1.0.3 renamed them | `enable_v0_3_compat=True` in `create_jsonrpc_routes` |
| `InvalidAgentResponseError` | `update_status()` called before `add_artifact()` | Always call `add_artifact()` first |
| `Task in terminal state: 3` or `TaskNotFoundError` on 2nd+ message (Python) | Joule reuses `taskId`; SDK looks up task before builder can clear it | `JouleFriendlyRequestHandler` — override `_setup_active_task`, set `params.message.task_id = ""` |
| `TaskNotFoundError: Task not found` (-32001) on 2nd+ message (TypeScript) | Same root cause; `@a2a-js/sdk` `DefaultRequestHandler` looks up completed task by `taskId` | `JouleFriendlyRequestHandler` — override `sendMessage` + `sendMessageStream`, set `params.message.taskId = undefined` |
| Blank response in Joule | `call_agent.yaml` reads `status.message`; SDK 1.0.3 puts response in `artifacts` | Use `result.body.artifacts[0].parts[0].text` |
| App crashes on CF startup | LLM initialized eagerly before `VCAP_SERVICES` is ready | Lazy init — call `get_llm()` only on first request |
| `Deployment not found` | `AICORE_RESOURCE_GROUP` mismatch | Match to deployment's actual resource group in AI Core console |
| `404` + `ai-external-failure: true` | `foundation-models` deployment; Azure backend missing model | Switch to `orchestration` scenario deployment |
| `ChatOpenAI` errors on orchestration endpoint | OpenAI protocol ≠ orchestration protocol | Custom `OrchestrationChatModel` subclassing `BaseChatModel` |
| `RBAC: access denied` | Named resource group not authorized | Use `default` resource group only |
| `create-destination.sh` fails | CF CLI alias + flat credential structure | Use manual curl steps |
| `400: Property 'X' not found` from S/4HANA (v4) | OData v4 field names differ from v2 | Drop `$select`, inspect live response, confirm field names |
| HTTP 403 CSRF token validation failed (OData v2) | Session cookie from CSRF fetch not included in POST | Capture `set-cookie` from CSRF fetch, add as `Cookie` header in POST |
| `invalid_grant` — ST program SAML2_ASSERTION error | Wrong signing certificate uploaded to S/4HANA | Export Active Trust Certificate from BTP Connectivity → Destination Trust; upload raw PEM only |
| `invalid_client` (PP) | SAML Issuer mismatch — XSUAA entity used instead of Destination Service entity | Set SAML Issuer to `cfapps.<region>.hana.ondemand.com/<subaccount-guid>` |
| HTTP 400 — field name invalid (OData v2 POST) | Field name mismatch between docs/v4 and actual OData v2 | Drop all field filters, inspect live response, confirm names |
