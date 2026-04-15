#!/usr/bin/env python3
"""
Scaffold a new Joule A2A Agent project.

Usage:
    python scaffold.py --name my-agent --namespace mycompany --output ./output

This generates a complete project directory with all files needed to build,
deploy, and connect a LangGraph A2A agent to SAP Joule using SAP GenAI Hub.
"""

import argparse
import os
import textwrap


def create_file(path: str, content: str):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(content)
    print(f"  Created: {path}")


def scaffold(name: str, namespace: str, output: str,
             description: str = "A helpful AI agent",
             cf_landscape: str = "us10"):

    base = os.path.join(output, name)
    app = os.path.join(base, "app")
    joule = os.path.join(base, "joule-capability")
    route_domain = f"cfapps.{cf_landscape}.hana.ondemand.com"
    app_route = f"{name}.{route_domain}"
    dest_name = f"{name.replace('-', '_').title().replace('_', '')}_A2A"
    safe_name = name.replace("-", "_")
    cap_id = f"ext.{namespace}.{name.replace('-', '')}"

    # --- app/__init__.py ---
    create_file(os.path.join(app, "__init__.py"), "")

    # --- app/__main__.py ---
    create_file(os.path.join(app, "__main__.py"), textwrap.dedent(f"""\
        import uvicorn
        import os
        import json
        from app.agent_card import get_agent_card
        from app.agent_executor import MyAgentExecutor
        from a2a.server.request_handlers import DefaultRequestHandler
        from a2a.server.apps.jsonrpc.starlette_app import A2AStarletteApplication
        from a2a.server.tasks.inmemory_task_store import InMemoryTaskStore


        def get_app_url() -> str:
            \"\"\"Get the app URL from CF environment or fall back to localhost.\"\"\"
            vcap = json.loads(os.getenv("VCAP_APPLICATION", "{{}}"))
            uris = vcap.get("application_uris", [])
            if uris:
                return f"https://{{uris[0]}}"
            host = os.getenv("HOST", "0.0.0.0")
            port = os.getenv("PORT", "8080")
            return f"http://{{host}}:{{port}}"


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
    """))

    # --- app/agent.py ---
    create_file(os.path.join(app, "agent.py"), textwrap.dedent(f"""\
        from langchain_core.runnables import RunnableConfig
        from langchain_core.messages import AIMessage, ToolMessage
        from langgraph.prebuilt import create_react_agent
        from langgraph.checkpoint.memory import MemorySaver
        from pydantic import BaseModel
        from typing import Any, AsyncIterable, Literal
        import os
        import json

        from app.tools import get_tools


        class ResponseFormat(BaseModel):
            \"\"\"Structured response format for A2A compatibility.\"\"\"
            status: Literal["input_required", "completed", "error"] = "input_required"
            message: str


        def get_llm():
            \"\"\"Initialize LLM via AI Core service binding (VCAP_SERVICES or AICORE_SERVICE_KEY).

            Uses langchain-openai ChatOpenAI pointed at AI Core's OpenAI-compatible endpoint.
            This avoids the generative-ai-hub-sdk pydantic version conflict with a2a-sdk.
            \"\"\"
            import httpx
            from langchain_openai import ChatOpenAI

            # Extract AI Core credentials from AICORE_SERVICE_KEY (local) or VCAP_SERVICES (CF)
            aicore_key = os.getenv("AICORE_SERVICE_KEY")
            if aicore_key:
                creds = json.loads(aicore_key)
            else:
                vcap = json.loads(os.getenv("VCAP_SERVICES", "{{}}"))
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
                data={{"grant_type": "client_credentials"}},
                auth=(creds["clientid"], creds["clientsecret"]),
                timeout=30,
            )
            token_resp.raise_for_status()
            access_token = token_resp.json()["access_token"]

            # Point ChatOpenAI at AI Core's inference endpoint
            api_url = creds["serviceurls"]["AI_API_URL"]
            resource_group = os.getenv("AICORE_RESOURCE_GROUP", "default")
            base_url = f"{{api_url}}/v2/inference/deployments"

            return ChatOpenAI(
                model=os.getenv("MODEL_NAME", "gpt-4.1"),
                base_url=base_url,
                api_key=access_token,
                max_tokens=4096,
                default_headers={{"AI-Resource-Group": resource_group}},
            )


        SYSTEM_INSTRUCTION = \"\"\"{description}

        When you have completed the user's request, set status to "completed".
        When you need more information, set status to "input_required".
        If an error occurs, set status to "error".
        \"\"\"

        RESPONSE_FORMAT_INSTRUCTION = \"\"\"Always respond using the ResponseFormat schema.\"\"\"

        memory = MemorySaver()


        class MyAgent:
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
                config: RunnableConfig = {{"configurable": {{"thread_id": session_id}}}}
                self.graph.invoke({{"messages": [("user", query)]}}, config)
                return self._get_response(config)

            async def stream(self, query: str, session_id: str) -> AsyncIterable[dict[str, Any]]:
                config: RunnableConfig = {{"configurable": {{"thread_id": session_id}}}}
                inputs = {{"messages": [("user", query)]}}
                for item in self.graph.stream(inputs, config, stream_mode="values"):
                    message = item["messages"][-1]
                    if isinstance(message, AIMessage) and message.tool_calls:
                        yield {{"is_task_complete": False, "require_user_input": False, "content": "Processing..."}}
                    elif isinstance(message, ToolMessage):
                        yield {{"is_task_complete": False, "require_user_input": False, "content": "Analyzing results..."}}
                yield self._get_response(config)

            def _get_response(self, config: RunnableConfig) -> dict[str, Any]:
                state = self.graph.get_state(config)
                structured = state.values.get("structured_response")
                if structured and isinstance(structured, ResponseFormat):
                    return {{
                        "is_task_complete": structured.status == "completed",
                        "require_user_input": structured.status == "input_required",
                        "content": structured.message,
                    }}
                messages = state.values.get("messages", [])
                if messages and hasattr(messages[-1], "content"):
                    return {{"is_task_complete": True, "require_user_input": False, "content": str(messages[-1].content)}}
                return {{"is_task_complete": False, "require_user_input": True, "content": "Could you rephrase your request?"}}
    """))

    # --- app/agent_executor.py ---
    create_file(os.path.join(app, "agent_executor.py"), textwrap.dedent("""\
        from uuid import uuid4
        from datetime import datetime
        from a2a.server.agent_execution import AgentExecutor
        from a2a.server.agent_execution.context import RequestContext
        from a2a.server.events.event_queue import EventQueue
        from a2a.types import (
            Artifact, Message, Part, Role,
            Task, TaskArtifactUpdateEvent, TaskState, TaskStatus,
            TaskStatusUpdateEvent, TextPart,
        )
        from app.agent import MyAgent


        class MyAgentExecutor(AgentExecutor):

            def __init__(self):
                self.agent = MyAgent()

            async def execute(self, context: RequestContext, event_queue: EventQueue) -> None:
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

            async def cancel(self, context: RequestContext, event_queue: EventQueue) -> None:
                task = context.current_task
                if task:
                    task.status = TaskStatus(
                        state=TaskState.canceled,
                        timestamp=datetime.now().isoformat(),
                    )
                    event_queue.enqueue_event(task)
    """))

    # --- app/agent_card.py ---
    create_file(os.path.join(app, "agent_card.py"), textwrap.dedent(f"""\
        from a2a.types import AgentCard, AgentCapabilities, AgentSkill


        def get_agent_card(base_url: str) -> AgentCard:
            capabilities = AgentCapabilities(streaming=True, pushNotifications=False)

            # TODO: Add one AgentSkill per tool in tools.py
            skill_1 = AgentSkill(
                id="example_skill",
                name="Example Skill",
                description="{description}",
                tags=["example"],
                examples=["What can you do?"],
            )

            return AgentCard(
                name="{name}",
                description="{description}",
                url=f"{{base_url}}/",
                version="1.0.0",
                defaultInputModes=["text/plain"],
                defaultOutputModes=["text/plain"],
                capabilities=capabilities,
                skills=[skill_1],
            )
    """))

    # --- app/tools.py ---
    create_file(os.path.join(app, "tools.py"), textwrap.dedent("""\
        from langchain_core.tools import tool
        import httpx


        @tool
        def example_tool(query: str) -> str:
            \"\"\"An example tool. Replace this with your actual tool implementation.

            Args:
                query: The input to process
            \"\"\"
            return f"Processed: {query}"


        def get_tools() -> list:
            \"\"\"Return all tools available to the agent.\"\"\"
            return [example_tool]
    """))

    # --- requirements.txt ---
    create_file(os.path.join(base, "requirements.txt"), textwrap.dedent("""\
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
    """))

    # --- manifest.yml ---
    manifest = f"""---
applications:
  - name: {name}
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
      - route: {app_route}
"""
    create_file(os.path.join(base, "manifest.yml"), manifest)

    # --- Procfile ---
    create_file(os.path.join(base, "Procfile"), "web: python -m app\n")

    # --- runtime.txt ---
    create_file(os.path.join(base, "runtime.txt"), "python-3.12.x\n")

    # --- .env.example ---
    create_file(os.path.join(base, ".env.example"), textwrap.dedent("""\
        MODEL_NAME=gpt-4.1
        HOST=0.0.0.0
        PORT=8080
        AICORE_RESOURCE_GROUP=default
        # For local development — paste your AI Core service key JSON:
        # AICORE_SERVICE_KEY={"serviceurls":{"AI_API_URL":"https://..."},"clientid":"...","clientsecret":"...","url":"https://..."}
    """))

    # --- joule-capability/capability.sapdas.yaml ---
    create_file(os.path.join(joule, "capability.sapdas.yaml"), textwrap.dedent(f"""\
        schema_version: 3.28.0

        metadata:
          namespace: {namespace}
          name: {safe_name}_a2a
          version: 1.0.0
          display_name: "{name}"
          description: "{description}"

        system_aliases:
          {dest_name.replace('_A2A', '')}:
            destination: {dest_name}
    """))

    # --- joule-capability/capability_context.yaml ---
    create_file(os.path.join(joule, "capability_context.yaml"), textwrap.dedent("""\
        variables:
          - name: contextId
          - name: taskId
    """))

    # --- joule-capability/da.sapdas.yaml ---
    create_file(os.path.join(joule, "da.sapdas.yaml"), textwrap.dedent(f"""\
        schema_version: 1.4.0
        name: {safe_name}_a2a
        capabilities:
          - type: local
            name: {safe_name}_a2a
            folder: ./
    """))

    # --- joule-capability/functions/call_agent.yaml ---
    alias_name = dest_name.replace('_A2A', '')
    create_file(os.path.join(joule, "functions", "call_agent.yaml"), textwrap.dedent(f"""\
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
                system_alias: {alias_name}
                body: >
                  <? (contextId == null || contextId.isEmpty()) && (taskId == null || taskId.isEmpty())
                     ? null
                     : '{{"contextId": "' + contextId + '", "taskId": "' + taskId + '"}}' ?>
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
    """))

    # --- joule-capability/scenarios/invoke_agent.yaml ---
    create_file(os.path.join(joule, "scenarios", "invoke_agent.yaml"), textwrap.dedent(f"""\
        description: >
          TODO: Describe when Joule should invoke this agent.
          Be specific about user intents and include example phrases.
          Example: "Call this when the user asks about sales orders, inquiries,
          or quotations. For example: 'Show me recent sales orders for customer X'."

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
    """))

    # --- joule-capability/README.md ---
    create_file(os.path.join(joule, "README.md"), textwrap.dedent(f"""\
        # Joule Capability: {name}

        ## Prerequisites

        **Joule DTA schema 3.28.0+ required.** Code-based agents (BYOA) using the
        `agent-request` action type require Joule DTA schema 3.28.0 or higher.

        If deploy fails with "Schema version defined in config file is greater than the
        current schema version of Joule", your tenant needs a Joule service update.

        ## File Structure

        ```
        joule-capability/
        ├── capability.sapdas.yaml       # Capability metadata (schema 3.28.0)
        ├── capability_context.yaml      # Multi-turn context variables
        ├── da.sapdas.yaml               # DA deployment descriptor (schema 1.4.0)
        ├── functions/
        │   └── call_agent.yaml          # A2A agent-request function
        └── scenarios/
            └── invoke_agent.yaml        # User intent → function mapping
        ```

        ## Deploy to Joule

        1. Ensure the BTP destination `{dest_name}` exists and points to:
           `https://{app_route}`

        2. Install Joule CLI: `npm install -g @sap/joule-cli`

        3. Login: `joule login --use-env` (from .env) or `joule login ` (interactive)

        4. Compile + deploy: `joule deploy ./da.sapdas.yaml --compile -n "{safe_name}_a2a"`
    """))

    # --- README.md ---
    create_file(os.path.join(base, "README.md"), textwrap.dedent(f"""\
        # {name}

        A LangGraph A2A agent for SAP Joule on BTP Cloud Foundry, powered by SAP GenAI Hub.

        ## Quick Start

        ### Local Development

        ```bash
        pip install -r requirements.txt
        cp .env.example .env
        # Edit .env with your AI Core service key
        python -m app
        # Test: curl http://localhost:8080/.well-known/agent.json
        ```

        ### Deploy to Cloud Foundry

        ```bash
        cf login -a https://api.cf.{cf_landscape}.hana.ondemand.com
        cf push
        ```

        ### Connect to Joule

        1. Create BTP destination `{dest_name}` pointing to `https://{app_route}`
        2. Deploy the Joule capability:
           ```bash
           cd joule-capability
           joule login 
           joule deploy ./da.sapdas.yaml --compile -n "{safe_name}_a2a"
           ```

        ## Project Structure

        ```
        {name}/
        ├── app/
        │   ├── __main__.py          # Server entry point
        │   ├── agent.py             # LangGraph ReAct agent
        │   ├── agent_executor.py    # A2A protocol bridge
        │   ├── agent_card.py        # Agent Card (discovery)
        │   └── tools.py             # Your custom tools
        ├── joule-capability/
        │   ├── capability.sapdas.yaml       # Capability definition (schema 3.28.0)
        │   ├── capability_context.yaml      # Multi-turn context variables
        │   ├── da.sapdas.yaml               # DA descriptor (schema 1.4.0)
        │   ├── functions/
        │   │   └── call_agent.yaml          # A2A agent-request function
        │   └── scenarios/
        │       └── invoke_agent.yaml        # User intent mapping
        ├── manifest.yml             # CF deployment
        ├── requirements.txt
        ├── Procfile
        ├── runtime.txt
        └── .env.example
        ```

        ## Customization

        1. Edit `app/tools.py` to add your agent's tools
        2. Edit `app/agent.py` SYSTEM_INSTRUCTION for behavior
        3. Edit `app/agent_card.py` skills to match your tools
        4. Edit `joule-capability/capability.sapdas.yaml` scenario description
    """))

    print(f"\nProject scaffolded at: {base}")
    print(f"Next steps:")
    print(f"  1. Edit app/tools.py with your tools")
    print(f"  2. Edit app/agent.py system instruction")
    print(f"  3. pip install -r requirements.txt && python -m app")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Scaffold a Joule A2A Agent project")
    parser.add_argument("--name", required=True, help="Agent name (kebab-case)")
    parser.add_argument("--namespace", default="mycompany", help="Capability namespace")
    parser.add_argument("--output", default=".", help="Output directory")
    parser.add_argument("--description", default="A helpful AI agent", help="Agent description")
    parser.add_argument("--landscape", default="us10", help="CF landscape (us10, eu10, etc.)")

    args = parser.parse_args()
    scaffold(args.name, args.namespace, args.output,
             args.description, args.landscape)
