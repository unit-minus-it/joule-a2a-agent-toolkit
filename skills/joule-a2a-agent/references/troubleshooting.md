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

## Bug: `InvalidParamsError: Task <id> is in terminal state: 3` / `TaskNotFoundError: Task <id> not found` — multi-turn conversations stop working after first message

**Symptom:** The first Joule message in a conversation works. Every follow-up message fails with one of:

```
# Same app instance (task is in store but completed):
InvalidParamsError: Task ea811b38-... is in terminal state: 3

# After app restart (task store is empty, Joule sends stale taskId):
TaskNotFoundError: Task dcc85776-... not found
```

Both errors are the same root cause — different symptom depending on whether the store is empty.

**Cause:** Joule preserves `contextId` and `taskId` across conversation turns and re-sends the same `taskId` on every follow-up. In `DefaultRequestHandlerV2._setup_active_task()`, the SDK reads `params.message.task_id` and looks it up in the task store (lines 190–196) **before** calling any `RequestContextBuilder`. If the task is completed or not found, it raises immediately.

**Wrong first attempt — `RequestContextBuilder`:** Trying to clear the task_id inside a custom `RequestContextBuilder.build()` does NOT work. The builder is called at line 199, after the error at lines 193–196 has already been raised. You will see `TaskNotFoundError` instead of `InvalidParamsError` but the bug is not fixed.

**Correct fix:** Subclass `DefaultRequestHandlerV2` and override `_setup_active_task` to clear the task_id *before* `super()` reads it:

```python
from a2a.server.request_handlers.default_request_handler_v2 import DefaultRequestHandlerV2

class JouleFriendlyRequestHandler(DefaultRequestHandlerV2):
    async def _setup_active_task(self, params, call_context):
        # Joule reuses taskId across turns. Setting task_id = "" here causes
        # (params.message.task_id or None) to evaluate to None, skipping the
        # store lookup. context_id is untouched — conversation memory is preserved.
        params.message.task_id = ""
        return await super()._setup_active_task(params, call_context)
```

Use this as the request handler instead of `DefaultRequestHandler`:

```python
request_handler = JouleFriendlyRequestHandler(
    agent_executor=agent_executor,
    task_store=InMemoryTaskStore(),
    agent_card=agent_card,
)
```

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

## Summary table

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Method not found` (-32601) | Joule calls v0.3 method names; SDK 1.0.3 renamed them | `enable_v0_3_compat=True` in `create_jsonrpc_routes` |
| `InvalidAgentResponseError` | `update_status()` called before `add_artifact()` | Always call `add_artifact()` first |
| `Task in terminal state: 3` or `TaskNotFoundError` on 2nd+ message | Joule reuses `taskId`; SDK looks up task before builder can clear it | `JouleFriendlyRequestHandler` — override `_setup_active_task`, set `params.message.task_id = ""` |
| Blank response in Joule | `call_agent.yaml` reads `status.message`; SDK 1.0.3 puts response in `artifacts` | Use `result.body.artifacts[0].parts[0].text` |
| App crashes on CF startup | LLM initialized eagerly before `VCAP_SERVICES` is ready | Lazy init — call `get_llm()` only on first request |
| `Deployment not found` | `AICORE_RESOURCE_GROUP` mismatch | Match to deployment's actual resource group in AI Core console |
| `404` + `ai-external-failure: true` | `foundation-models` deployment; Azure backend missing model | Switch to `orchestration` scenario deployment |
| `ChatOpenAI` errors on orchestration endpoint | OpenAI protocol ≠ orchestration protocol | Custom `OrchestrationChatModel` subclassing `BaseChatModel` |
| `RBAC: access denied` | Named resource group not authorized | Use `default` resource group only |
| `create-destination.sh` fails | CF CLI alias + flat credential structure | Use manual curl steps |
| `400: Property 'X' not found` from S/4HANA | OData v4 field names differ from v2 | Drop `$select`, inspect live response, confirm field names |
