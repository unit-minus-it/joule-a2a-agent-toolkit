# LangGraph A2A Agent — CAP TypeScript Templates

This reference contains complete TypeScript code templates for building a LangGraph.js agent on SAP CAP (Cloud Application Programming Model) with A2A protocol support using `@a2a-js/sdk` v0.3.10 and `@sap/cds`.

## Table of Contents

1. [CAP Bootstrap (`srv/server.ts`)](#1-cap-bootstrap)
2. [Agent Executor (`srv/agent-executor.ts`)](#2-agent-executor)
3. [CDS Service Definition (`srv/service.cds`)](#3-cds-service-definition)
4. [Tools (`srv/tools/tools.ts`)](#4-tools)
5. [Utilities](#5-utilities)
6. [Agent Card Configuration](#6-agent-card-configuration)
7. [Configuration Files](#7-configuration-files)
8. [package.json](#8-packagejson)

---

## 1. CAP Bootstrap

`srv/server.ts` — registers A2A Express endpoints on the CAP server during bootstrap.

```typescript
import cds from "@sap/cds";
import { Express, Request, Response } from "express";
import type { AgentCard } from "@a2a-js/sdk";
import {
    AgentExecutor,
    InMemoryTaskStore,
    DefaultRequestHandler,
} from "@a2a-js/sdk/server";
import { jsonRpcHandler, UserBuilder } from "@a2a-js/sdk/server/express";

import { LangGraphAgentExecutor } from "./agent-executor";

const VCAP = process.env.VCAP_APPLICATION;
const getA2aServerUrl = (): string =>
    VCAP ? `https://${JSON.parse(VCAP).application_uris[0]}/` : "http://localhost:4004/";

// @ts-ignore
cds.on("bootstrap", (app: Express) => {
    console.log("[A2A] Registering A2A routes on bootstrap...");

    const taskStore = new InMemoryTaskStore();
    const agentExecutor: AgentExecutor = new LangGraphAgentExecutor();
    const requestHandler = new DefaultRequestHandler(agentCard, taskStore, agentExecutor);

    // Serve agent card as a plain GET handler (more reliable with CAP middleware)
    app.get("/.well-known/agent.json", (_req: Request, res: Response) => {
        res.json(agentCard);
    });

    // A2A JSON-RPC endpoint
    app.use("/", jsonRpcHandler({ requestHandler, userBuilder: UserBuilder.noAuthentication }));

    console.log("[A2A] Routes registered successfully");
});

const a2aServerUrl = getA2aServerUrl();

const agentCard: AgentCard = {
    name: "My Agent",
    description: "A helpful agent that does X, Y, Z",
    url: a2aServerUrl,
    provider: { organization: "My Company", url: "https://example.com" },
    version: "1.0.0",
    capabilities: {
        streaming: true,
        pushNotifications: false,
        stateTransitionHistory: false,
    },
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"],
    skills: [
        {
            id: "example-skill",
            name: "Example Skill",
            description: "Describe what this skill does — be specific so Joule routes correctly",
            tags: ["example"],
            examples: ["Show me an example of what this agent can do"],
            outputModes: ["text/plain"],
        },
    ],
    supportsAuthenticatedExtendedCard: false,
    protocolVersion: "0.3.0",
};
```

---

## 2. Agent Executor

`srv/agent-executor.ts` — the LangGraph agent orchestrator that bridges A2A protocol to LangGraph using `StateGraph`.

```typescript
import { v4 as uuidv4 } from "uuid";
import cds from "@sap/cds";

// A2A
import { Task, TaskStatusUpdateEvent, Message } from "@a2a-js/sdk";
import { AgentExecutor, RequestContext, ExecutionEventBus } from "@a2a-js/sdk/server";

// LangGraph + SAP GenAI Hub
import { OrchestrationClient } from "@sap-ai-sdk/langchain";
import { END, START, Command, MemorySaver, MessagesAnnotation, StateGraph } from "@langchain/langgraph";
import { ToolNode } from "@langchain/langgraph/prebuilt";
import type { BaseMessageLike } from "@langchain/core/messages";

import { a2aMessagesToLangChain } from "./utils/a2aToLangchain";
import { tools as agentTools } from "./tools/tools";
import { getSystemPrompt } from "./utils/prompts";
import { createInterruptUpdate, createMessage, createMessageUpdate, createNewTask } from "./utils/a2a-operations";

const logger = cds.log("agent");
const contexts = new Map<string, Message[]>();

type AgentGraphState = {
    messages: BaseMessageLike[];
};

function createAgentNode(modelWithTools: ReturnType<OrchestrationClient["bindTools"]>) {
    return async (state: AgentGraphState) => {
        const response = await modelWithTools.invoke([
            { role: "system", content: getSystemPrompt() },
            ...state.messages,
        ]);
        return { messages: [response] };
    };
}

export class LangGraphAgentExecutor implements AgentExecutor {
    private app: any;

    constructor() {
        const model = new OrchestrationClient({
            promptTemplating: {
                model: {
                    name: process.env.MODEL_NAME || "gpt-4.1",
                },
            },
        });
        const modelWithTools = model.bindTools(agentTools);
        const toolNode = new ToolNode(agentTools);
        const stateGraph = this.instantiateStateGraph(toolNode, createAgentNode(modelWithTools));
        const memorySaver = new MemorySaver();
        this.app = stateGraph.compile({ checkpointer: memorySaver });
    }

    private instantiateStateGraph = (
        toolNode: ToolNode,
        agentNode: (state: AgentGraphState) => Promise<{ messages: unknown[] }>
    ) => {
        return new StateGraph(MessagesAnnotation)
            .addNode("agent", agentNode)
            .addNode("tools", toolNode)
            .addEdge(START, "agent")
            .addConditionalEdges("agent", this.shouldContinue, ["tools", END])
            .addEdge("tools", "agent");
    };

    async execute(requestContext: RequestContext, eventBus: ExecutionEventBus): Promise<void> {
        const userMessage = requestContext.userMessage;
        const existingTask = requestContext.task;

        const taskId = existingTask?.id || requestContext.taskId || uuidv4();
        const contextId = userMessage.contextId || existingTask?.contextId || uuidv4();

        // 1. Publish initial Task event if new
        if (!existingTask) {
            const initialTask: Task = createNewTask(userMessage, { taskId, contextId });
            eventBus.publish(initialTask);
        }

        // 2. Publish "working" status
        const workingUpdate: TaskStatusUpdateEvent = createMessageUpdate(
            "Processing your request...",
            { taskId, contextId, final: false }
        );
        eventBus.publish(workingUpdate);

        // 3. Build conversation history
        const historyForAgent = contexts.get(contextId) || [];
        if (!historyForAgent.find((m) => m.messageId === userMessage.messageId)) {
            historyForAgent.push(userMessage);
        }
        contexts.set(contextId, historyForAgent);

        const messages = a2aMessagesToLangChain(historyForAgent);

        // 4. Invoke LangGraph (stream mode)
        let res;
        const textParts = userMessage.parts.filter((part) => part.kind === "text");
        const messageText = textParts.map((part) => part.text).join(" ");

        if (requestContext.task) {
            // Resuming an interrupted task
            res = await this.app.stream(
                new Command({ resume: messageText }),
                { configurable: { thread_id: requestContext.taskId } }
            );
        } else {
            res = await this.app.stream(
                { messages },
                { configurable: { thread_id: taskId } }
            );
        }

        // 5. Process stream chunks
        let finalRes = "";
        for await (const chunk of res) {
            if (!("__interrupt__" in chunk)) {
                const agentMessages = chunk.agent?.messages;
                if (Array.isArray(agentMessages)) {
                    const agentMessage = agentMessages[agentMessages.length - 1];
                    if (agentMessage instanceof Object && "content" in agentMessage) {
                        finalRes += agentMessage.content;
                    }
                }
                continue;
            }

            // Handle interrupt (human-in-the-loop)
            type InterruptChunk = { __interrupt__: Array<{ value: any }> };
            const interruptValue = (chunk as InterruptChunk).__interrupt__[0].value;
            const interruptUpdate: TaskStatusUpdateEvent = createInterruptUpdate(interruptValue, {
                taskId,
                contextId,
            });
            eventBus.publish(interruptUpdate);
            eventBus.finished();
            return;
        }

        // 6. Publish final response
        const finalMessage: Message = createMessage(finalRes, { taskId, contextId });
        historyForAgent.push(finalMessage);
        contexts.set(contextId, historyForAgent);

        const finalUpdate: TaskStatusUpdateEvent = createMessageUpdate(finalMessage, {
            taskId,
            contextId,
            final: true,
        });
        eventBus.publish(finalUpdate);
        eventBus.finished();

        logger.log(`Task ${taskId} completed`);
    }

    public cancelTask = async (taskId: string, eventBus: ExecutionEventBus): Promise<void> => {};

    private shouldContinue(state: AgentGraphState) {
        const messages = state.messages;
        const lastMessage = messages[messages.length - 1] as { tool_calls?: unknown[] } | undefined;
        if (lastMessage?.tool_calls?.length) {
            return "tools";
        }
        return END;
    }
}
```

---

## 3. CDS Service Definition

`srv/service.cds` — minimal CDS service definition:

```
@protocol: ['rest']
@path    : '/api'
service Service {
    action a2aAdapter(task: String) returns String;
}
```

---

## 4. Tools

`srv/tools/tools.ts` — the agent's tools. This is the main file to customize.

```typescript
import { tool } from "@langchain/core/tools";
import { z } from "zod";

// --- Example tool (replace with your implementation) ---
const exampleTool = tool(
    async ({ query }) => {
        return `Processed: ${query}`;
    },
    {
        name: "example_tool",
        description: "An example tool. Replace this with your actual tool implementation.",
        schema: z.object({
            query: z.string().describe("The input to process"),
        }),
    }
);

export const tools = [exampleTool];
```

### Example: SAP OData Tool

```typescript
const getSalesOrders = tool(
    async ({ customerId }) => {
        const destUrl = process.env.SAP_DESTINATION_URL || "https://my-s4.example.com";
        try {
            const response = await fetch(
                `${destUrl}/sap/opu/odata/sap/API_SALES_ORDER_SRV/A_SalesOrder?$filter=SoldToParty eq '${customerId}'&$top=10&$format=json`,
                { headers: { Accept: "application/json" } }
            );
            if (!response.ok) throw new Error(`HTTP ${response.status}`);
            const data = await response.json();
            return JSON.stringify(data.d?.results || []);
        } catch (error) {
            return JSON.stringify({
                error: `Failed: ${error instanceof Error ? error.message : "Unknown"}`,
            });
        }
    },
    {
        name: "get_sales_orders",
        description: "Retrieve sales orders for a specific customer from SAP S/4HANA",
        schema: z.object({
            customerId: z.string().describe('The SAP customer ID (e.g., "1000001")'),
        }),
    }
);
```

### Example: Human-in-the-Loop Tool (interrupt)

```typescript
import { interrupt } from "@langchain/langgraph";

const askExpert = tool(
    async ({ question }) => {
        const answer = interrupt(question);
        return `Expert answered: ${answer}`;
    },
    {
        name: "ask_expert",
        description: "Ask the user for information when you need clarification or are missing data.",
        schema: z.object({
            question: z.string().describe("The question to ask the user"),
        }),
    }
);
```

---

## 5. Utilities

### `srv/utils/prompts.ts`

```typescript
export const getSystemPrompt = (): string => {
    return `You are a helpful assistant.

When you have completed the user's request, provide your answer clearly.
When you need more information from the user, use the ask_expert tool.
If an error occurs, explain what went wrong.`;
};
```

### `srv/utils/a2aToLangchain.ts`

Converts A2A messages to LangChain format:

```typescript
import type { Message, TextPart } from "@a2a-js/sdk";
import {
    HumanMessage,
    AIMessage,
    SystemMessage,
    type BaseMessage,
} from "@langchain/core/messages";

function extractTextParts(m: Message): string {
    return (m.parts ?? [])
        .filter((p): p is TextPart => p.kind === "text" && typeof p.text === "string")
        .map((p) => p.text)
        .join("\n")
        .trim();
}

function toLangChainMessage(role: string, text: string): BaseMessage {
    switch (role) {
        case "user":
            return new HumanMessage(text);
        case "agent":
        case "assistant":
            return new AIMessage(text);
        case "system":
            return new SystemMessage(text);
        default:
            return new HumanMessage(text);
    }
}

export function a2aMessagesToLangChain(history: Message[]): BaseMessage[] {
    return history.map((m) => toLangChainMessage(m.role, extractTextParts(m)));
}
```

### `srv/utils/a2a-operations.ts`

A2A event creation helpers:

```typescript
import { Message, Task, TaskStatusUpdateEvent } from "@a2a-js/sdk";
import { v4 as uuidv4 } from "uuid";

export function createNewTask(
    message: Message,
    options: { taskId: string; contextId: string }
): Task {
    return {
        kind: "task",
        id: options.taskId,
        contextId: options.contextId,
        status: {
            state: "submitted",
            timestamp: new Date().toISOString(),
        },
        history: [message],
        metadata: message.metadata,
    };
}

export function createMessageUpdate(
    message: string | Message,
    options: { taskId: string; contextId: string; final: boolean }
): TaskStatusUpdateEvent {
    const statusMessage: Message =
        typeof message === "string"
            ? {
                  kind: "message",
                  messageId: uuidv4(),
                  role: "agent",
                  parts: [{ kind: "text", text: message }],
                  taskId: options.taskId,
                  contextId: options.contextId,
              }
            : message;
    return {
        kind: "status-update",
        taskId: options.taskId,
        contextId: options.contextId,
        status: {
            state: options.final ? "completed" : "working",
            message: statusMessage,
            timestamp: new Date().toISOString(),
        },
        final: false,
    };
}

export function createInterruptUpdate(
    message: string,
    options: { taskId: string; contextId: string }
): TaskStatusUpdateEvent {
    return {
        kind: "status-update",
        taskId: options.taskId,
        contextId: options.contextId,
        status: {
            state: "input-required",
            message: {
                kind: "message",
                role: "agent",
                messageId: uuidv4(),
                parts: [{ kind: "text", text: message }],
                taskId: options.taskId,
                contextId: options.contextId,
            },
            timestamp: new Date().toISOString(),
        },
        final: true,
    };
}

export function createMessage(
    message: string,
    options: { taskId: string; contextId: string }
): Message {
    return {
        kind: "message",
        messageId: uuidv4(),
        role: "agent",
        parts: [{ kind: "text", text: message }],
        taskId: options.taskId,
        contextId: options.contextId,
    };
}
```

### `srv/utils/helpers.ts`

```typescript
const VCAP = process.env.VCAP_APPLICATION;

export const getA2aServerUrl = (): string =>
    VCAP
        ? `https://${JSON.parse(VCAP).application_uris[0]}/`
        : "http://localhost:4004/";
```

---

## 6. Agent Card Configuration

The agent card in `srv/server.ts` should be customized for each agent:

- **`name`** and **`description`**: Agent identity
- **`skills`**: One entry per tool, with clear `description` for Joule routing
- **`protocolVersion`**: Must be `"0.3.0"`
- **`url`**: Auto-detected from `VCAP_APPLICATION` in CF

When deployed to Cloud Foundry, the URL is auto-detected via `VCAP_APPLICATION.application_uris[0]`.

---

## 7. Configuration Files

### `tsconfig.json`

```json
{
  "compilerOptions": {
    "target": "ESNext",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "esModuleInterop": true,
    "forceConsistentCasingInFileNames": true,
    "strict": true,
    "skipLibCheck": true,
    "sourceMap": true,
    "allowJs": true,
    "paths": {
      "#cds-models/*": ["./@cds-models/*"]
    }
  }
}
```

### `.cdsrc.sample.json`

For local development with dummy auth and AI Core credentials:

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

---

## 8. package.json

```json
{
  "name": "my-a2a-agent",
  "version": "1.0.0",
  "private": true,
  "dependencies": {
    "@a2a-js/sdk": "0.3.10",
    "@langchain/core": "^1.1.32",
    "@langchain/langgraph": "^1.2.2",
    "@sap-ai-sdk/langchain": "^2.8.0",
    "@sap-ai-sdk/orchestration": "^2.8.0",
    "@sap/cds": "^9.7.1",
    "@sap/xssec": "^4",
    "uuid": "^9.0.0",
    "zod": "^3.25.2"
  },
  "engines": {
    "node": "24.x"
  },
  "devDependencies": {
    "@cap-js/cds-typer": ">=0.1",
    "@cap-js/cds-types": "^0.16.0",
    "@cap-js/sqlite": "^2",
    "@sap/cds-dk": ">=9",
    "@types/express": "^5.0.6",
    "@types/node": "^22.18.10",
    "@types/uuid": "^10.0.0",
    "tsx": "^4",
    "typescript": "^5"
  },
  "scripts": {
    "start": "cds-serve",
    "watch": "cds-tsx watch --profile hybrid",
    "deploy": "mbt build && cf deploy mta_archives/${npm_package_name}_1.0.0.mtar"
  },
  "imports": {
    "#cds-models/*": "./@cds-models/*/index.js"
  },
  "cds": {
    "requires": {
      "auth": {
        "kind": "dummy"
      }
    }
  }
}
```
