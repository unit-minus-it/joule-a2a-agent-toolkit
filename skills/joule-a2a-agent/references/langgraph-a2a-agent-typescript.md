# LangGraph A2A Agent — TypeScript Templates (Express)

This reference contains complete TypeScript code templates for building a LangGraph.js agent with A2A protocol support using `@a2a-js/sdk` v0.3.10 and Express.

## Table of Contents

1. [Project Entry Point (`src/index.ts`)](#1-project-entry-point)
2. [Agent Implementation (`src/agent.ts`)](#2-agent-implementation)
3. [A2A Protocol Bridge (`src/executor.ts`)](#3-a2a-protocol-bridge)
4. [Agent Card (`src/agentCard.ts`)](#4-agent-card)
5. [Tools (`src/tools.ts`)](#5-tools)
6. [SAP GenAI Hub Integration (`src/llm.ts`)](#6-sap-genai-hub-integration)
7. [TypeScript Configuration](#7-typescript-configuration)

---

## 1. Project Entry Point

`src/index.ts` — starts the A2A Express server.

```typescript
import express from "express";
import {
  jsonRpcHandler,
  agentCardHandler,
  UserBuilder,
} from "@a2a-js/sdk/server/express";
import {
  DefaultRequestHandler,
  InMemoryTaskStore,
} from "@a2a-js/sdk/server";
import { agentCard } from "./agentCard.js";
import { MyAgentExecutor } from "./executor.js";

const PORT = parseInt(process.env.PORT || "8080", 10);

const taskStore = new InMemoryTaskStore();
const agentExecutor = new MyAgentExecutor();

const requestHandler = new DefaultRequestHandler(
  agentCard,
  taskStore,
  agentExecutor
);

const app = express();
app.use(express.json());

// Agent card at /.well-known/agent.json (required by Joule)
app.use(
  "/.well-known/agent.json",
  agentCardHandler({ agentCardProvider: async () => agentCard })
);

// A2A JSON-RPC endpoint
app.use(
  "/",
  jsonRpcHandler({
    requestHandler,
    userBuilder: UserBuilder.noAuthentication,
  })
);

app.listen(PORT, () => {
  console.log(`A2A agent server running at http://localhost:${PORT}`);
  console.log(`Agent card: http://localhost:${PORT}/.well-known/agent.json`);
});
```

---

## 2. Agent Implementation

`src/agent.ts` — the LangGraph.js ReAct agent.

```typescript
import { createReactAgent } from "@langchain/langgraph/prebuilt";
import { MemorySaver } from "@langchain/langgraph";
import { HumanMessage, AIMessage } from "@langchain/core/messages";
import { getTools } from "./tools.js";
import { getLLM } from "./llm.js";

const SYSTEM_PROMPT = `You are a helpful assistant.
When you have completed the user's request, indicate completion clearly.
When you need more information from the user, ask your question.
If an error occurs, explain what went wrong.`;

const memory = new MemorySaver();

export interface AgentResponse {
  isTaskComplete: boolean;
  requireUserInput: boolean;
  content: string;
}

export class MyAgent {
  private graph;

  constructor() {
    const model = getLLM();
    const tools = getTools();

    this.graph = createReactAgent({
      llm: model,
      tools,
      checkpointSaver: memory,
      messageModifier: SYSTEM_PROMPT,
    });
  }

  async invoke(query: string, sessionId: string): Promise<AgentResponse> {
    const config = { configurable: { thread_id: sessionId } };

    const result = await this.graph.invoke(
      { messages: [new HumanMessage(query)] },
      config
    );

    const messages = result.messages;
    const lastMessage = messages[messages.length - 1];
    const content =
      typeof lastMessage.content === "string"
        ? lastMessage.content
        : JSON.stringify(lastMessage.content);

    const isQuestion = content.trim().endsWith("?");

    return {
      isTaskComplete: !isQuestion,
      requireUserInput: isQuestion,
      content,
    };
  }

  async *stream(
    query: string,
    sessionId: string
  ): AsyncGenerator<AgentResponse> {
    const config = { configurable: { thread_id: sessionId } };
    const inputs = { messages: [new HumanMessage(query)] };

    const stream = await this.graph.stream(inputs, {
      ...config,
      streamMode: "values",
    });

    let lastResponse: AgentResponse | null = null;

    for await (const chunk of stream) {
      const messages = chunk.messages;
      const lastMessage = messages[messages.length - 1];

      if (lastMessage._getType() === "ai" && (lastMessage as AIMessage).tool_calls?.length) {
        yield {
          isTaskComplete: false,
          requireUserInput: false,
          content: "Processing your request...",
        };
      } else if (lastMessage._getType() === "tool") {
        yield {
          isTaskComplete: false,
          requireUserInput: false,
          content: "Analyzing results...",
        };
      } else {
        const content =
          typeof lastMessage.content === "string"
            ? lastMessage.content
            : JSON.stringify(lastMessage.content);

        lastResponse = {
          isTaskComplete: true,
          requireUserInput: false,
          content,
        };
      }
    }

    if (lastResponse) {
      yield lastResponse;
    }
  }
}
```

---

## 3. A2A Protocol Bridge

`src/executor.ts` — bridges the LangGraph.js agent to the A2A protocol using `@a2a-js/sdk`.

```typescript
import { v4 as uuidv4 } from "uuid";
import {
  AgentExecutor,
  RequestContext,
  ExecutionEventBus,
} from "@a2a-js/sdk/server";
import {
  Task,
  TaskStatusUpdateEvent,
  TaskArtifactUpdateEvent,
} from "@a2a-js/sdk";
import { MyAgent, AgentResponse } from "./agent.js";

export class MyAgentExecutor implements AgentExecutor {
  private agent: MyAgent;
  private cancelledTasks = new Set<string>();

  constructor() {
    this.agent = new MyAgent();
  }

  async cancelTask(
    taskId: string,
    eventBus: ExecutionEventBus
  ): Promise<void> {
    this.cancelledTasks.add(taskId);
  }

  async execute(
    requestContext: RequestContext,
    eventBus: ExecutionEventBus
  ): Promise<void> {
    const { userMessage, task: existingTask } = requestContext;

    const taskId = existingTask?.id || uuidv4();
    const contextId =
      userMessage.contextId || existingTask?.contextId || uuidv4();

    const firstPart = userMessage.parts[0];
    if (!firstPart || firstPart.kind !== "text") {
      throw new Error("Only text parts are supported");
    }
    const query = firstPart.text;

    if (!existingTask) {
      const initialTask: Task = {
        kind: "task",
        id: taskId,
        contextId,
        status: {
          state: "submitted",
          timestamp: new Date().toISOString(),
        },
        history: [userMessage],
        artifacts: [],
      };
      eventBus.publish(initialTask);
    }

    eventBus.publish(this.createStatusUpdate(taskId, contextId, {
      state: "working",
      message: this.createAgentMessage(taskId, contextId, "Processing..."),
      final: false,
    }));

    try {
      for await (const response of this.agent.stream(query, contextId)) {
        if (this.cancelledTasks.has(taskId)) {
          eventBus.publish(this.createStatusUpdate(taskId, contextId, {
            state: "canceled",
            final: true,
          }));
          eventBus.finished();
          return;
        }

        if (response.isTaskComplete) {
          const artifactUpdate: TaskArtifactUpdateEvent = {
            kind: "artifact-update",
            taskId,
            contextId,
            artifact: {
              artifactId: uuidv4(),
              parts: [{ kind: "text", text: response.content }],
            },
            append: false,
            lastChunk: true,
          };
          eventBus.publish(artifactUpdate);

          eventBus.publish(this.createStatusUpdate(taskId, contextId, {
            state: "completed",
            message: this.createAgentMessage(taskId, contextId, response.content),
            final: true,
          }));
        } else if (response.requireUserInput) {
          eventBus.publish(this.createStatusUpdate(taskId, contextId, {
            state: "input-required",
            message: this.createAgentMessage(taskId, contextId, response.content),
            final: true,
          }));
        } else {
          eventBus.publish(this.createStatusUpdate(taskId, contextId, {
            state: "working",
            message: this.createAgentMessage(taskId, contextId, response.content),
            final: false,
          }));
        }
      }
    } catch (error) {
      const errorMsg = error instanceof Error ? error.message : "Unknown error";
      eventBus.publish(this.createStatusUpdate(taskId, contextId, {
        state: "failed",
        message: this.createAgentMessage(taskId, contextId, `Error: ${errorMsg}`),
        final: true,
      }));
    }

    eventBus.finished();
  }

  private createStatusUpdate(
    taskId: string,
    contextId: string,
    opts: { state: string; message?: any; final: boolean }
  ): TaskStatusUpdateEvent {
    return {
      kind: "status-update",
      taskId,
      contextId,
      status: {
        state: opts.state as any,
        message: opts.message,
        timestamp: new Date().toISOString(),
      },
      final: opts.final,
    };
  }

  private createAgentMessage(taskId: string, contextId: string, text: string) {
    return {
      kind: "message" as const,
      role: "agent" as const,
      messageId: uuidv4(),
      parts: [{ kind: "text" as const, text }],
      taskId,
      contextId,
    };
  }
}
```

---

## 4. Agent Card

`src/agentCard.ts` — defines the agent's identity and capabilities for A2A discovery.

```typescript
import { AgentCard } from "@a2a-js/sdk";

const vcap = JSON.parse(process.env.VCAP_APPLICATION || "{}");
const appUris = vcap.application_uris || [];
const BASE_URL = appUris.length
  ? `https://${appUris[0]}`
  : `http://localhost:${process.env.PORT || 8080}`;

export const agentCard: AgentCard = {
  name: "My Agent",
  description: "A helpful agent that does X, Y, Z",
  url: `${BASE_URL}/`,
  provider: {
    organization: "My Company",
    url: "https://example.com",
  },
  version: "1.0.0",
  capabilities: {
    streaming: true,
    pushNotifications: false,
    stateTransitionHistory: false,
  },
  defaultInputModes: ["text/plain"],
  defaultOutputModes: ["text/plain"],
  skills: [
    {
      id: "example_skill",
      name: "Example Skill",
      description:
        "Describe what this skill does — be specific so Joule routes correctly",
      tags: ["example"],
      examples: ["Show me an example of what this agent can do"],
      inputModes: ["text/plain"],
      outputModes: ["text/plain"],
    },
  ],
  supportsAuthenticatedExtendedCard: false,
  protocolVersion: "0.3.0",
};
```

---

## 5. Tools

`src/tools.ts` — the agent's tools. This is the main file to customize.

```typescript
import { tool } from "@langchain/core/tools";
import { z } from "zod";

const exampleTool = tool(
  async ({ query }) => {
    return `Processed: ${query}`;
  },
  {
    name: "example_tool",
    description:
      "An example tool. Replace this with your actual tool implementation.",
    schema: z.object({
      query: z.string().describe("The input to process"),
    }),
  }
);

export function getTools() {
  return [exampleTool];
}
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

---

## 6. SAP GenAI Hub Integration

`src/llm.ts` — LLM provider configuration using SAP AI SDK OrchestrationClient.

```typescript
import { OrchestrationClient } from "@sap-ai-sdk/langchain";

export function getLLM() {
  return new OrchestrationClient({
    promptTemplating: {
      model: {
        name: process.env.MODEL_NAME || "gpt-4.1",
      },
    },
  });
}
```

The `OrchestrationClient` auto-reads AI Core credentials from `VCAP_SERVICES` when deployed to Cloud Foundry. For local development, set the `AICORE_SERVICE_KEY` environment variable with your AI Core service key JSON.

To change the model, update the `MODEL_NAME` environment variable. The model must be deployed on your AI Core instance.

---

## 7. TypeScript Configuration

`tsconfig.json`:

```json
{
  "compilerOptions": {
    "target": "ESNext",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "lib": ["ESNext"],
    "outDir": "./dist",
    "rootDir": "./src",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true,
    "resolveJsonModule": true,
    "declaration": true,
    "sourceMap": true
  },
  "include": ["src/**/*"],
  "exclude": ["node_modules", "dist"]
}
```
