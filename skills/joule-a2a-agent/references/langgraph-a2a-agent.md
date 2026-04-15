# LangGraph A2A Agent — Code Templates

This reference contains the complete Python code templates for building a LangGraph agent with A2A protocol support. When generating a project, adapt these templates to the user's specific requirements.

## Table of Contents

1. [Project Entry Point (`__main__.py`)](#1-project-entry-point)
2. [Agent Implementation (`agent.py`)](#2-agent-implementation)
3. [A2A Protocol Bridge (`agent_executor.py`)](#3-a2a-protocol-bridge)
4. [Agent Card (`agent_card.py`)](#4-agent-card)
5. [Tools (`tools.py`)](#5-tools)
6. [SAP GenAI Hub Integration](#6-sap-genai-hub-integration)
7. [Alternative LLM Providers](#7-alternative-llm-providers)

---

## 1. Project Entry Point

`app/__main__.py` — starts the A2A server with uvicorn.

```python
import uvicorn
import os
import json
from app.agent_card import get_agent_card
from app.agent_executor import MyAgentExecutor
from a2a.server.request_handlers import DefaultRequestHandler
from a2a.server.apps.jsonrpc.starlette_app import A2AStarletteApplication
from a2a.server.tasks.inmemory_task_store import InMemoryTaskStore


def get_app_url() -> str:
    """Get the app URL from CF environment or fall back to localhost."""
    vcap = json.loads(os.getenv("VCAP_APPLICATION", "{}"))
    uris = vcap.get("application_uris", [])
    if uris:
        return f"https://{uris[0]}"
    host = os.getenv("HOST", "0.0.0.0")
    port = os.getenv("PORT", "8080")
    return f"http://{host}:{port}"


def main():
    host = os.getenv("HOST", "0.0.0.0")
    port = int(os.getenv("PORT", 8080))

    app_url = get_app_url()
    agent_card = get_agent_card(app_url)
    agent_executor = MyAgentExecutor()

    request_handler = DefaultRequestHandler(
        agent_executor=agent_executor,
        task_store=InMemoryTaskStore(),
    )

    app = A2AStarletteApplication(
        agent_card=agent_card,
        http_handler=request_handler,
    )

    uvicorn.run(app.build(), host=host, port=port)

if __name__ == "__main__":
    main()
```

`app/__init__.py` — empty, makes `app` a package.

---

## 2. Agent Implementation

`app/agent.py` — the LangGraph ReAct agent. This is the core intelligence.

### With SAP GenAI Hub (default)

Uses `langchain-openai` pointed at AI Core's OpenAI-compatible endpoint. This avoids the `generative-ai-hub-sdk` pydantic version conflict with `a2a-sdk`.

```python
from langchain_core.runnables import RunnableConfig
from langchain_core.messages import AIMessage, ToolMessage
from langgraph.prebuilt import create_react_agent
from langgraph.checkpoint.memory import MemorySaver
from pydantic import BaseModel
from typing import Any, AsyncIterable, Literal
import os
import json

from app.tools import get_tools


# --- Response format for structured output ---
class ResponseFormat(BaseModel):
    """Respond to the user in this format."""
    status: Literal["input_required", "completed", "error"] = "input_required"
    message: str


# --- LLM initialization ---
def get_llm():
    """Initialize LLM via AI Core service binding (VCAP_SERVICES or AICORE_SERVICE_KEY).

    Uses langchain-openai ChatOpenAI pointed at AI Core's OpenAI-compatible endpoint.
    This avoids the generative-ai-hub-sdk pydantic version conflict with a2a-sdk.
    """
    import httpx
    from langchain_openai import ChatOpenAI

    # Extract AI Core credentials from AICORE_SERVICE_KEY (local) or VCAP_SERVICES (CF)
    aicore_key = os.getenv("AICORE_SERVICE_KEY")
    if aicore_key:
        creds = json.loads(aicore_key)
    else:
        vcap = json.loads(os.getenv("VCAP_SERVICES", "{}"))
        aicore_bindings = vcap.get("aicore", [])
        if not aicore_bindings:
            raise RuntimeError(
                "No AI Core service binding found. "
                "Set AICORE_SERVICE_KEY env var or bind an aicore service instance."
            )
        creds = aicore_bindings[0]["credentials"]

    # Get OAuth2 token from AI Core
    auth_url = creds["url"] + "/oauth/token"
    token_resp = httpx.post(
        auth_url,
        data={"grant_type": "client_credentials"},
        auth=(creds["clientid"], creds["clientsecret"]),
        timeout=30,
    )
    token_resp.raise_for_status()
    access_token = token_resp.json()["access_token"]

    # Point ChatOpenAI at AI Core's inference endpoint
    api_url = creds["serviceurls"]["AI_API_URL"]
    resource_group = os.getenv("AICORE_RESOURCE_GROUP", "default")
    base_url = f"{api_url}/v2/inference/deployments"

    return ChatOpenAI(
        model=os.getenv("MODEL_NAME", "gpt-4.1"),
        base_url=base_url,
        api_key=access_token,
        max_tokens=4096,
        default_headers={"AI-Resource-Group": resource_group},
    )


# --- System instruction ---
SYSTEM_INSTRUCTION = """You are a helpful assistant.
When you have completed the user's request, set status to "completed".
When you need more information from the user, set status to "input_required" and ask your question.
If an error occurs, set status to "error" and explain what went wrong.
"""

RESPONSE_FORMAT_INSTRUCTION = """Always respond using the ResponseFormat schema.
Set 'status' to indicate the task state and 'message' for your response text."""

# --- Memory ---
memory = MemorySaver()


class MyAgent:
    """LangGraph ReAct agent with A2A-compatible response format."""

    SUPPORTED_CONTENT_TYPES = ["text/plain"]

    def __init__(self):
        self.model = get_llm()
        self.tools = get_tools()
        self.graph = create_react_agent(
            self.model,
            tools=self.tools,
            checkpointer=memory,
            prompt=SYSTEM_INSTRUCTION,
            response_format=(RESPONSE_FORMAT_INSTRUCTION, ResponseFormat),
        )

    def invoke(self, query: str, session_id: str) -> dict[str, Any]:
        """Synchronous invocation."""
        config: RunnableConfig = {"configurable": {"thread_id": session_id}}
        self.graph.invoke({"messages": [("user", query)]}, config)
        return self._get_response(config)

    async def stream(self, query: str, session_id: str) -> AsyncIterable[dict[str, Any]]:
        """Streaming invocation with intermediate status updates."""
        config: RunnableConfig = {"configurable": {"thread_id": session_id}}
        inputs = {"messages": [("user", query)]}

        for item in self.graph.stream(inputs, config, stream_mode="values"):
            message = item["messages"][-1]
            if isinstance(message, AIMessage) and message.tool_calls:
                yield {
                    "is_task_complete": False,
                    "require_user_input": False,
                    "content": "Processing your request...",
                }
            elif isinstance(message, ToolMessage):
                yield {
                    "is_task_complete": False,
                    "require_user_input": False,
                    "content": "Analyzing results...",
                }

        yield self._get_response(config)

    def _get_response(self, config: RunnableConfig) -> dict[str, Any]:
        """Extract structured response from agent state."""
        state = self.graph.get_state(config)
        messages = state.values.get("messages", [])
        structured = state.values.get("structured_response")

        if structured and isinstance(structured, ResponseFormat):
            if structured.status == "input_required":
                return {
                    "is_task_complete": False,
                    "require_user_input": True,
                    "content": structured.message,
                }
            elif structured.status == "error":
                return {
                    "is_task_complete": False,
                    "require_user_input": True,
                    "content": structured.message,
                }
            else:
                return {
                    "is_task_complete": True,
                    "require_user_input": False,
                    "content": structured.message,
                }

        # Fallback: use last AI message
        if messages:
            last = messages[-1]
            if hasattr(last, "content"):
                return {
                    "is_task_complete": True,
                    "require_user_input": False,
                    "content": str(last.content),
                }

        return {
            "is_task_complete": False,
            "require_user_input": True,
            "content": "I couldn't process your request. Could you rephrase?",
        }
```

---

## 3. A2A Protocol Bridge

`app/agent_executor.py` — bridges the LangGraph agent to the A2A protocol. Uses the `execute`/`cancel` interface from `a2a-sdk` 0.3.x with `RequestContext`.

```python
from uuid import uuid4
from datetime import datetime

from a2a.server.agent_execution import AgentExecutor
from a2a.server.agent_execution.context import RequestContext
from a2a.server.events.event_queue import EventQueue
from a2a.types import (
    Artifact,
    Message,
    Part,
    Role,
    Task,
    TaskArtifactUpdateEvent,
    TaskState,
    TaskStatus,
    TaskStatusUpdateEvent,
    TextPart,
)

from app.agent import MyAgent


class MyAgentExecutor(AgentExecutor):
    """Bridges the LangGraph agent to the A2A protocol."""

    def __init__(self):
        self.agent = MyAgent()

    async def execute(
        self,
        context: RequestContext,
        event_queue: EventQueue,
    ) -> None:
        """Handle incoming A2A requests (both send and stream)."""
        user_input = context.get_user_input()
        task = context.current_task

        if not task:
            task = Task(
                id=context.task_id or str(uuid4()),
                contextId=context.context_id or str(uuid4()),
                status=TaskStatus(
                    state=TaskState.submitted,
                    timestamp=datetime.now().isoformat(),
                ),
            )
            event_queue.enqueue_event(task)

        response = self.agent.invoke(user_input, task.contextId)
        parts = [Part(TextPart(text=response["content"]))]
        task.status.timestamp = datetime.now().isoformat()

        if response["require_user_input"]:
            task.status.state = TaskState.input_required
            msg = Message(messageId=str(uuid4()), role=Role.agent, parts=parts)
            task.status.message = msg
            task.history = (task.history or []) + [msg]
        else:
            task.status.state = TaskState.completed
            task.status.message = None
            task.artifacts = (task.artifacts or []) + [
                Artifact(parts=parts, artifactId=str(uuid4()))
            ]

        event_queue.enqueue_event(task)

    async def cancel(
        self,
        context: RequestContext,
        event_queue: EventQueue,
    ) -> None:
        """Handle task cancellation."""
        task = context.current_task
        if task:
            task.status = TaskStatus(
                state=TaskState.canceled,
                timestamp=datetime.now().isoformat(),
            )
            event_queue.enqueue_event(task)
```

---

## 4. Agent Card

`app/agent_card.py` — defines the agent's identity and capabilities for A2A discovery.

```python
from a2a.types import (
    AgentCard,
    AgentCapabilities,
    AgentSkill,
)


def get_agent_card(base_url: str) -> AgentCard:
    """Build the Agent Card for this agent.

    Customize:
    - name: your agent's name
    - description: what your agent does (Joule uses this for routing)
    - skills: list of AgentSkill objects, one per tool/capability
    """
    capabilities = AgentCapabilities(streaming=True, pushNotifications=False)

    # Define one skill per tool your agent offers.
    # Joule and other A2A clients use these to understand what your agent can do.
    skill_1 = AgentSkill(
        id="example_skill",
        name="Example Skill",
        description="Describe what this skill does — be specific so Joule routes correctly",
        tags=["example", "template"],
        examples=["Show me an example of what this agent can do"],
    )

    return AgentCard(
        name="My Agent",
        description="A helpful agent that does X, Y, Z",
        url=f"{base_url}/",
        version="1.0.0",
        defaultInputModes=["text/plain"],
        defaultOutputModes=["text/plain"],
        capabilities=capabilities,
        skills=[skill_1],
    )
```

**Important**: When deployed to Cloud Foundry, the `url` in the agent card should be the actual app URL (e.g., `https://my-agent.cfapps.us10.hana.ondemand.com/`). The `get_app_url()` function in `__main__.py` reads this from `VCAP_APPLICATION` at runtime and passes it to `get_agent_card()`.

---

## 5. Tools

`app/tools.py` — the agent's tools. This is the main file to customize.

### Template (customize for user's use case)

```python
from langchain_core.tools import tool
import httpx
import os


@tool
def example_api_call(param1: str, param2: str = "default") -> dict:
    """Describe what this tool does. The LLM reads this docstring to decide when to call it.

    Args:
        param1: Description of param1
        param2: Description of param2
    """
    try:
        response = httpx.get(
            f"https://api.example.com/endpoint",
            params={"key": param1, "option": param2},
            timeout=30,
        )
        response.raise_for_status()
        return response.json()
    except httpx.HTTPError as e:
        return {"error": f"API request failed: {str(e)}"}


def get_tools() -> list:
    """Return all tools available to the agent."""
    return [example_api_call]
```

### Example: SAP API Tool (using destination)

When calling SAP APIs from Cloud Foundry, you typically use BTP destinations:

```python
@tool
def get_sales_orders(customer_id: str) -> dict:
    """Retrieve sales orders for a specific customer from SAP S/4HANA.

    Args:
        customer_id: The SAP customer ID (e.g., "1000001")
    """
    # In CF, the destination service provides the URL and auth
    dest_url = os.getenv("SAP_DESTINATION_URL", "https://my-s4.example.com")

    try:
        response = httpx.get(
            f"{dest_url}/sap/opu/odata/sap/API_SALES_ORDER_SRV/A_SalesOrder",
            params={
                "$filter": f"SoldToParty eq '{customer_id}'",
                "$top": 10,
                "$format": "json",
            },
            headers={"Accept": "application/json"},
            timeout=30,
        )
        response.raise_for_status()
        data = response.json()
        return data.get("d", {}).get("results", [])
    except httpx.HTTPError as e:
        return {"error": f"Failed to fetch sales orders: {str(e)}"}
```

---

## 6. SAP GenAI Hub Integration

When using SAP GenAI Hub as the LLM provider, the agent reads credentials from the AI Core service binding in Cloud Foundry (`VCAP_SERVICES`) or from the `AICORE_SERVICE_KEY` environment variable for local development.

### Why `langchain-openai` instead of `generative-ai-hub-sdk`?

The `generative-ai-hub-sdk` pins `pydantic==2.10.6`, but `a2a-sdk` >=0.2.7 requires `pydantic>=2.11.3`. This creates an unsolvable dependency conflict. The solution is to use `langchain-openai`'s `ChatOpenAI` pointed directly at AI Core's OpenAI-compatible inference endpoint, with OAuth2 credentials extracted manually from the service binding.

### Setup

1. **Create an AI Core service instance** in your BTP subaccount
2. **Deploy a model** (e.g., GPT-4.1) in AI Core
3. **Bind the service** to your CF app (in `manifest.yml`)

### Additional requirements in `requirements.txt`:
```
langchain-openai>=0.3.0
httpx>=0.27.0
```

### Environment variables (for local development):
```bash
# Paste your AI Core service key JSON:
AICORE_SERVICE_KEY='{"serviceurls":{"AI_API_URL":"https://..."},"clientid":"...","clientsecret":"...","url":"https://..."}'
AICORE_RESOURCE_GROUP=default
MODEL_NAME=gpt-4.1
```

---

## 7. Changing the GenAI Hub Model

To use a different model deployed on your AI Core instance, update the `MODEL_NAME` environment variable:

```bash
# .env
MODEL_NAME=gpt-4.1
# Or any model deployed on your AI Core instance:
# MODEL_NAME=gpt-4o
# MODEL_NAME=gemini-2.5-pro
```

In Cloud Foundry, set it in `manifest.yml` under `env:` or via `cf set-env`.
