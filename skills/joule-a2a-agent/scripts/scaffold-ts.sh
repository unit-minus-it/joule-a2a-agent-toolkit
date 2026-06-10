#!/usr/bin/env bash
# ============================================================================
# scaffold-ts.sh
#
# Scaffolds a complete TypeScript LangGraph A2A agent project for SAP Joule.
# Supports both Express (lightweight) and CAP (enterprise) frameworks.
#
# Usage:
#   ./scaffold-ts.sh --name my-agent --framework express --landscape eu10
#   ./scaffold-ts.sh --name my-agent --framework cap --namespace mycompany
# ============================================================================

set -euo pipefail

# ---------- defaults ----------
NAME=""
FRAMEWORK="express"
NAMESPACE="joule.ext"  # IMPORTANT: Joule deployment only works with namespace "joule.ext"
OUTPUT="."
DESCRIPTION="A helpful AI agent"
LANDSCAPE="us10"
WITH_PP="false"  # --with-principal-propagation: adds S/4HANA Public Cloud PP support

# ---------- parse args ----------
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Required:
  --name NAME              Agent name (kebab-case, e.g. po-assistant)

Optional:
  --framework TYPE             "express" (default) or "cap"
  --namespace NS               Capability namespace (default: joule.ext)
  --output DIR                 Output directory (default: .)
  --description DESC           Agent description
  --landscape LAND             CF landscape (default: us10)
  --with-principal-propagation Add S/4HANA Public Cloud principal propagation (Express only)

Examples:
  $(basename "$0") --name po-assistant --framework express --landscape eu10
  $(basename "$0") --name po-assistant --framework express --landscape eu20 --with-principal-propagation
  $(basename "$0") --name po-assistant --framework cap --namespace com.sap.paa
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)                       NAME="$2";        shift 2 ;;
    --framework)                  FRAMEWORK="$2";   shift 2 ;;
    --namespace)                  NAMESPACE="$2";   shift 2 ;;
    --output)                     OUTPUT="$2";      shift 2 ;;
    --description)                DESCRIPTION="$2"; shift 2 ;;
    --landscape)                  LANDSCAPE="$2";   shift 2 ;;
    --with-principal-propagation) WITH_PP="true";   shift 1 ;;
    -h|--help)     usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

if [[ -z "$NAME" ]]; then
  echo "Error: --name is required."
  usage
fi

if [[ "$FRAMEWORK" != "express" && "$FRAMEWORK" != "cap" ]]; then
  echo "Error: --framework must be 'express' or 'cap'."
  exit 1
fi

if [[ "$WITH_PP" == "true" && "$FRAMEWORK" != "express" ]]; then
  echo "Warning: --with-principal-propagation is only supported for the Express framework. Ignoring for CAP."
  WITH_PP="false"
fi

# ---------- derived values ----------
BASE="${OUTPUT}/${NAME}"
SAFE_NAME="${NAME//-/_}"
ROUTE_DOMAIN="cfapps.${LANDSCAPE}.hana.ondemand.com"
APP_ROUTE="${NAME}.${ROUTE_DOMAIN}"
# PascalCase + _A2A for destination name
DEST_NAME="$(echo "${SAFE_NAME}" | perl -pe 's/(^|_)(.)/uc($2)/ge')_A2A"
CAP_ID="ext.${NAMESPACE}.${SAFE_NAME}"
ALIAS_NAME="$(echo "${SAFE_NAME}" | perl -pe 's/(^|_)(.)/uc($2)/ge')"
# Principal propagation destination name (CF agent → S/4HANA)
PP_S4_DEST="S4_$(echo "${SAFE_NAME}" | tr '[:lower:]' '[:upper:]')_PP"

create_file() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path"
  echo "  Created: $path"
}

echo "============================================"
echo " Scaffolding TypeScript ${FRAMEWORK} agent: ${NAME}"
echo "============================================"
echo ""

# ====================================================================
# JOULE CAPABILITY (shared by both frameworks)
# ====================================================================
create_joule_capability() {
  local joule="${BASE}/joule-capability"

  create_file "${joule}/capability.sapdas.yaml" <<EOF
schema_version: 3.28.0

metadata:
  namespace: ${NAMESPACE}
  name: ${SAFE_NAME}_a2a
  version: 1.0.0
  display_name: "${NAME}"
  description: ${DESCRIPTION}

system_aliases:
  ${ALIAS_NAME}:
    destination: ${DEST_NAME}
EOF

  create_file "${joule}/da.sapdas.yaml" <<EOF
schema_version: 1.4.0
name: ${SAFE_NAME}_a2a
capabilities:
  - type: local
    name: ${SAFE_NAME}_a2a
    folder: ./
EOF

  mkdir -p "${joule}/functions" "${joule}/scenarios"

  create_file "${joule}/capability_context.yaml" <<'EOF'
variables:
  - name: contextId
  - name: taskId
EOF

  create_file "${joule}/functions/call_agent.yaml" <<'FUNCEOF'
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
FUNCEOF
  # Append system_alias and rest (needs variable interpolation for alias)
  cat >> "${joule}/functions/call_agent.yaml" <<EOF
        system_alias: ${ALIAS_NAME}
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
EOF

  create_file "${joule}/scenarios/invoke_agent.yaml" <<'EOF'
description: >
  TODO: Describe when Joule should invoke this agent.
  Be specific about user intents and include example phrases.

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
EOF
}

# ====================================================================
# EXPRESS FRAMEWORK
# ====================================================================
scaffold_express() {
  local src="${BASE}/src"
  mkdir -p "$src"

  # PP-conditional package.json entries
  local PP_SDK_DEP=""
  local PP_SERVICES_MANIFEST=""
  if [[ "$WITH_PP" == "true" ]]; then
    PP_SDK_DEP='    "@sap-cloud-sdk/http-client": "^4.0.0",'
    PP_SERVICES_MANIFEST="      - ${NAME}-xsuaa        # XSUAA for OAuth2UserTokenExchange (cf create-service xsuaa application ${NAME}-xsuaa -c xs-security.json)
      - ${NAME}-destination  # Destination Service for runtime SAML Bearer resolution (cf create-service destination lite ${NAME}-destination)"
  fi

  # --- package.json ---
  create_file "${BASE}/package.json" <<EOF
{
  "name": "${NAME}",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "engines": {
    "node": ">=20.0.0"
  },
  "scripts": {
    "build": "tsc",
    "start": "node dist/index.js",
    "dev": "tsx src/index.ts"
  },
  "dependencies": {
    "@a2a-js/sdk": "0.3.10",
    "@langchain/core": "^1.1.32",
    "@langchain/langgraph": "^1.2.2",
    "@sap-ai-sdk/langchain": "^2.8.0",
    "@sap-ai-sdk/orchestration": "^2.8.0",
${PP_SDK_DEP}
    "express": "^4.21.0",
    "uuid": "^10.0.0",
    "zod": "^3.25.2"
  },
  "devDependencies": {
    "@types/express": "^4.17.0",
    "@types/node": "^22.0.0",
    "@types/uuid": "^10.0.0",
    "tsx": "^4.0.0",
    "typescript": "^5.6.0"
  }
}
EOF

  # --- tsconfig.json ---
  create_file "${BASE}/tsconfig.json" <<'EOF'
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
EOF

  # --- manifest.yml ---
  create_file "${BASE}/manifest.yml" <<EOF
---
applications:
  - name: ${NAME}
    memory: 512M
    disk_quota: 1G
    instances: 1
    buildpacks:
      - nodejs_buildpack
    command: npm start
    env:
      MODEL_NAME: gpt-4.1
      NODE_ENV: production
      AICORE_RESOURCE_GROUP: default
    services:
      - aicore  # TODO: Replace with your AI Core service instance name (run 'cf services' to find it)
${PP_SERVICES_MANIFEST}
    routes:
      - route: ${APP_ROUTE}
EOF

  # --- Procfile ---
  create_file "${BASE}/Procfile" <<'EOF'
web: npm start
EOF

  # --- .env.example ---
  create_file "${BASE}/.env.example" <<'EOF'
MODEL_NAME=gpt-4.1
PORT=8080
# For local development:
# AICORE_SERVICE_KEY={"serviceurls":{"AI_API_URL":"https://..."},"clientid":"...","clientsecret":"...","url":"https://..."}
EOF

  # --- src/index.ts --- (PP version includes JWT middleware for principal propagation)
  if [[ "$WITH_PP" == "true" ]]; then
    create_file "${src}/index.ts" <<'EOF'
import express, { Request, Response, NextFunction } from "express";
import {
  jsonRpcHandler,
  agentCardHandler,
  UserBuilder,
} from "@a2a-js/sdk/server/express";
import {
  DefaultRequestHandler,
  InMemoryTaskStore,
  ServerCallContext,
} from "@a2a-js/sdk/server";
import { agentCard } from "./agentCard.js";
import { MyAgentExecutor } from "./executor.js";
import { userJwtStorage } from "./context.js";

// Joule reuses taskId across conversation turns. Clear it each turn so a fresh
// task is created, while contextId (LangGraph thread_id) is preserved for memory.
class JouleFriendlyRequestHandler extends DefaultRequestHandler {
  override async sendMessage(
    params: Parameters<DefaultRequestHandler["sendMessage"]>[0],
    context?: ServerCallContext
  ) {
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

const PORT = parseInt(process.env.PORT || "8080", 10);
const taskStore = new InMemoryTaskStore();
const agentExecutor = new MyAgentExecutor();
const requestHandler = new JouleFriendlyRequestHandler(agentCard, taskStore, agentExecutor);

const app = express();
app.use(express.json());

// Principal propagation: extract the Bearer JWT from each incoming request and
// store it in AsyncLocalStorage. Tools read it via destOptions() in destination.ts
// to call S/4HANA as the authenticated Joule user instead of the service account.
app.use((req: Request, _res: Response, next: NextFunction) => {
  const authHeader = req.headers.authorization;
  const jwt = authHeader?.startsWith("Bearer ") ? authHeader.slice(7) : undefined;
  userJwtStorage.run(jwt, next);
});

app.use("/.well-known/agent.json", agentCardHandler({ agentCardProvider: async () => agentCard }));
app.use("/", jsonRpcHandler({ requestHandler, userBuilder: UserBuilder.noAuthentication }));

app.listen(PORT, () => {
  console.log(`A2A agent server running at http://localhost:${PORT}`);
  console.log(`Agent card: http://localhost:${PORT}/.well-known/agent.json`);
});
EOF
  else
    create_file "${src}/index.ts" <<'EOF'
import express from "express";
import {
  jsonRpcHandler,
  agentCardHandler,
  UserBuilder,
} from "@a2a-js/sdk/server/express";
import {
  DefaultRequestHandler,
  InMemoryTaskStore,
  ServerCallContext,
} from "@a2a-js/sdk/server";
import { agentCard } from "./agentCard.js";
import { MyAgentExecutor } from "./executor.js";

// Joule reuses taskId across conversation turns. Clear it each turn so a fresh
// task is created, while contextId (LangGraph thread_id) is preserved for memory.
class JouleFriendlyRequestHandler extends DefaultRequestHandler {
  override async sendMessage(
    params: Parameters<DefaultRequestHandler["sendMessage"]>[0],
    context?: ServerCallContext
  ) {
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

const PORT = parseInt(process.env.PORT || "8080", 10);
const taskStore = new InMemoryTaskStore();
const agentExecutor = new MyAgentExecutor();
const requestHandler = new JouleFriendlyRequestHandler(agentCard, taskStore, agentExecutor);

const app = express();
app.use(express.json());

app.use("/.well-known/agent.json", agentCardHandler({ agentCardProvider: async () => agentCard }));
app.use("/", jsonRpcHandler({ requestHandler, userBuilder: UserBuilder.noAuthentication }));

app.listen(PORT, () => {
  console.log(`A2A agent server running at http://localhost:${PORT}`);
  console.log(`Agent card: http://localhost:${PORT}/.well-known/agent.json`);
});
EOF
  fi

  # --- src/llm.ts ---
  create_file "${src}/llm.ts" <<'EOF'
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
EOF

  # --- src/tools.ts ---
  if [[ "$WITH_PP" == "true" ]]; then
    # PP-aware template: uses destOptions/fetchCsrfToken for S/4HANA calls
    create_file "${src}/tools.ts" <<EOF
import { tool } from "@langchain/core/tools";
import { z } from "zod";
import { executeHttpRequest } from "@sap-cloud-sdk/http-client";
import { destOptions, fetchCsrfToken } from "./destination.js";

// ── S/4HANA destination and OData service ────────────────────────────────────
// Set DESTINATION to the name of your OAuth2SAMLBearerAssertion destination in BTP.
// Set ODATA_BASE to the OData v2 service base path for the API you are using.
const DESTINATION = "${PP_S4_DEST}";
const ODATA_BASE  = "/sap/opu/odata/sap/TODO_SERVICE_SRV";
// ─────────────────────────────────────────────────────────────────────────────

// ── Read example ──────────────────────────────────────────────────────────────
// Replace EntitySet and field names with your actual S/4HANA entity.
// Drop \$select on first pass and inspect the real field names from a live response.
const getRecords = tool(
  async ({ maxResults }) => {
    try {
      const response = await executeHttpRequest(destOptions(DESTINATION), {
        method: "GET",
        url: \`\${ODATA_BASE}/EntitySet\`,
        params: { \$format: "json", \$top: String(maxResults ?? 10) },
        headers: { Accept: "application/json" },
      });
      const results: unknown[] = response.data?.d?.results ?? [];
      if (!results.length) return "No records found.";
      return JSON.stringify({ count: results.length, results }, null, 2);
    } catch (error) {
      const e = error as { response?: { status?: number; data?: unknown }; message?: string };
      return \`Error: HTTP \${e.response?.status ?? "unknown"} — \${JSON.stringify(e.response?.data ?? e.message)}\`;
    }
  },
  {
    name: "get_records",
    description: "Read records from S/4HANA as the authenticated Joule user.",
    schema: z.object({
      maxResults: z.number().optional().describe("Maximum records to return (default: 10)"),
    }),
  }
);

// ── Mutating example (POST) ───────────────────────────────────────────────────
// OData v2 mutations require a CSRF token AND the session cookie from the token fetch.
// fetchCsrfToken() returns both. Always include the Cookie header in the POST request.
const createRecord = tool(
  async ({ field1 }) => {
    try {
      const { token, cookie } = await fetchCsrfToken(DESTINATION, ODATA_BASE);
      const response = await executeHttpRequest(destOptions(DESTINATION), {
        method: "POST",
        url: \`\${ODATA_BASE}/EntitySet\`,
        data: { Field1: field1 },
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
          "x-csrf-token": token,
          ...(cookie ? { Cookie: cookie } : {}),
        },
      });
      return JSON.stringify(response.data?.d ?? { success: true });
    } catch (error) {
      const e = error as { response?: { status?: number; data?: unknown }; message?: string };
      return \`Error: HTTP \${e.response?.status ?? "unknown"} — \${JSON.stringify(e.response?.data ?? e.message)}\`;
    }
  },
  {
    name: "create_record",
    description: "Create a record in S/4HANA as the authenticated Joule user.",
    schema: z.object({
      field1: z.string().describe("Example field — replace with your actual fields"),
    }),
  }
);

export function getTools() {
  return [getRecords, createRecord];
}
EOF
  else
    create_file "${src}/tools.ts" <<'EOF'
import { tool } from "@langchain/core/tools";
import { z } from "zod";

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

export function getTools() {
  return [exampleTool];
}
EOF
  fi

  # --- PP-only files ---
  if [[ "$WITH_PP" == "true" ]]; then
    create_file "${src}/context.ts" <<'EOF'
import { AsyncLocalStorage } from "node:async_hooks";

// Stores the incoming Bearer JWT per request for principal propagation.
// Set in Express middleware (index.ts) before jsonRpcHandler; read via destOptions().
export const userJwtStorage = new AsyncLocalStorage<string | undefined>();
EOF

    create_file "${src}/destination.ts" <<'EOF'
import { executeHttpRequest } from "@sap-cloud-sdk/http-client";
import { userJwtStorage } from "./context.js";

/**
 * Returns destination options for Cloud SDK executeHttpRequest.
 * Passes the user JWT so BTP resolves OAuth2SAMLBearerAssertion on behalf of
 * the individual Joule user, not the technical service account.
 */
export function destOptions(destinationName: string) {
  return { destinationName, jwt: userJwtStorage.getStore() };
}

/**
 * Fetches a CSRF token and session cookie from an OData v2 service.
 * OData v2 CSRF tokens are session-bound: both the token and the session cookie
 * must be forwarded in every mutating request (POST/PUT/DELETE), otherwise
 * S/4HANA returns HTTP 403 "CSRF token validation failed".
 */
export async function fetchCsrfToken(
  destinationName: string,
  odataBasePath: string
): Promise<{ token: string; cookie: string | undefined }> {
  const response = await executeHttpRequest(destOptions(destinationName), {
    method: "GET",
    url: `${odataBasePath}/`,
    headers: { "x-csrf-token": "Fetch", Accept: "application/json" },
  });
  const token = response.headers["x-csrf-token"];
  if (!token || token === "Required") {
    throw new Error("Failed to retrieve CSRF token from S/4HANA");
  }
  const raw = response.headers["set-cookie"];
  const cookie = Array.isArray(raw) ? raw.join("; ") : raw;
  return { token: token as string, cookie };
}
EOF

    create_file "${BASE}/xs-security.json" <<EOF
{
  "xsappname": "${NAME}",
  "tenant-mode": "dedicated",
  "scopes": [],
  "role-templates": [],
  "oauth2-configuration": {
    "token-validity": 43200,
    "redirect-uris": [
      "https://${APP_ROUTE}/**"
    ]
  }
}
EOF

  fi

  # --- src/agent.ts ---
  create_file "${src}/agent.ts" <<'EOF'
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
    return { isTaskComplete: !isQuestion, requireUserInput: isQuestion, content };
  }

  async *stream(query: string, sessionId: string): AsyncGenerator<AgentResponse> {
    const config = { configurable: { thread_id: sessionId } };
    const stream = await this.graph.stream(
      { messages: [new HumanMessage(query)] },
      { ...config, streamMode: "values" }
    );
    let lastResponse: AgentResponse | null = null;
    for await (const chunk of stream) {
      const messages = chunk.messages;
      const lastMessage = messages[messages.length - 1];
      if (lastMessage._getType() === "ai" && (lastMessage as AIMessage).tool_calls?.length) {
        yield { isTaskComplete: false, requireUserInput: false, content: "Processing..." };
      } else if (lastMessage._getType() === "tool") {
        yield { isTaskComplete: false, requireUserInput: false, content: "Analyzing results..." };
      } else {
        const content = typeof lastMessage.content === "string"
          ? lastMessage.content : JSON.stringify(lastMessage.content);
        lastResponse = { isTaskComplete: true, requireUserInput: false, content };
      }
    }
    if (lastResponse) yield lastResponse;
  }
}
EOF

  # --- src/executor.ts ---
  create_file "${src}/executor.ts" <<'EOF'
import { v4 as uuidv4 } from "uuid";
import { AgentExecutor, RequestContext, ExecutionEventBus } from "@a2a-js/sdk/server";
import { Task, TaskStatusUpdateEvent, TaskArtifactUpdateEvent } from "@a2a-js/sdk";
import { MyAgent, AgentResponse } from "./agent.js";

export class MyAgentExecutor implements AgentExecutor {
  private agent: MyAgent;

  constructor() {
    this.agent = new MyAgent();
  }

  async cancelTask(taskId: string, eventBus: ExecutionEventBus): Promise<void> {}

  async execute(requestContext: RequestContext, eventBus: ExecutionEventBus): Promise<void> {
    const { userMessage, task: existingTask } = requestContext;
    const taskId = existingTask?.id || uuidv4();
    const contextId = userMessage.contextId || existingTask?.contextId || uuidv4();

    const firstPart = userMessage.parts[0];
    if (!firstPart || firstPart.kind !== "text") throw new Error("Only text parts supported");
    const query = firstPart.text;

    if (!existingTask) {
      eventBus.publish({
        kind: "task", id: taskId, contextId,
        status: { state: "submitted", timestamp: new Date().toISOString() },
        history: [userMessage], artifacts: [],
      } as Task);
    }

    eventBus.publish({
      kind: "status-update", taskId, contextId,
      status: { state: "working", timestamp: new Date().toISOString(),
        message: { kind: "message", role: "agent", messageId: uuidv4(),
          parts: [{ kind: "text", text: "Processing..." }], taskId, contextId } },
      final: false,
    } as TaskStatusUpdateEvent);

    try {
      for await (const response of this.agent.stream(query, contextId)) {
        if (response.isTaskComplete) {
          eventBus.publish({
            kind: "artifact-update", taskId, contextId,
            artifact: { artifactId: uuidv4(), parts: [{ kind: "text", text: response.content }] },
            append: false, lastChunk: true,
          } as TaskArtifactUpdateEvent);
          eventBus.publish({
            kind: "status-update", taskId, contextId,
            status: { state: "completed", timestamp: new Date().toISOString(),
              message: { kind: "message", role: "agent", messageId: uuidv4(),
                parts: [{ kind: "text", text: response.content }], taskId, contextId } },
            final: true,
          } as TaskStatusUpdateEvent);
        } else if (response.requireUserInput) {
          eventBus.publish({
            kind: "status-update", taskId, contextId,
            status: { state: "input-required", timestamp: new Date().toISOString(),
              message: { kind: "message", role: "agent", messageId: uuidv4(),
                parts: [{ kind: "text", text: response.content }], taskId, contextId } },
            final: true,
          } as TaskStatusUpdateEvent);
        }
      }
    } catch (error) {
      const msg = error instanceof Error ? error.message : "Unknown error";
      eventBus.publish({
        kind: "status-update", taskId, contextId,
        status: { state: "failed", timestamp: new Date().toISOString(),
          message: { kind: "message", role: "agent", messageId: uuidv4(),
            parts: [{ kind: "text", text: `Error: ${msg}` }], taskId, contextId } },
        final: true,
      } as TaskStatusUpdateEvent);
    }
    eventBus.finished();
  }
}
EOF

  # --- src/agentCard.ts ---
  cat > "${src}/agentCard.ts" <<EOF
import { AgentCard } from "@a2a-js/sdk";

const vcap = JSON.parse(process.env.VCAP_APPLICATION || "{}");
const appUris = vcap.application_uris || [];
const BASE_URL = appUris.length
  ? \`https://\${appUris[0]}\`
  : \`http://localhost:\${process.env.PORT || 8080}\`;

export const agentCard: AgentCard = {
  name: "${NAME}",
  description: "${DESCRIPTION}",
  url: \`\${BASE_URL}/\`,
  provider: { organization: "${NAMESPACE}", url: "https://example.com" },
  version: "1.0.0",
  capabilities: { streaming: true, pushNotifications: false, stateTransitionHistory: false },
  defaultInputModes: ["text/plain"],
  defaultOutputModes: ["text/plain"],
  skills: [
    {
      id: "example_skill",
      name: "Example Skill",
      description: "${DESCRIPTION}",
      tags: ["example"],
      examples: ["What can you do?"],
      inputModes: ["text/plain"],
      outputModes: ["text/plain"],
    },
  ],
  supportsAuthenticatedExtendedCard: false,
  protocolVersion: "0.3.0",
};
EOF
  echo "  Created: ${src}/agentCard.ts"
}

# ====================================================================
# CAP FRAMEWORK
# ====================================================================
scaffold_cap() {
  local srv="${BASE}/srv"
  local utils="${srv}/utils"
  local tools="${srv}/tools"
  mkdir -p "$utils" "$tools"

  # --- package.json ---
  create_file "${BASE}/package.json" <<EOF
{
  "name": "${NAME}",
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
  "engines": { "node": "24.x" },
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
    "deploy": "mbt build && cf deploy mta_archives/${NAME}_1.0.0.mtar"
  },
  "imports": { "#cds-models/*": "./@cds-models/*/index.js" },
  "cds": {
    "requires": {
      "auth": {
        "kind": "dummy"
      }
    }
  }
}
EOF

  # --- tsconfig.json ---
  create_file "${BASE}/tsconfig.json" <<'EOF'
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
    "paths": { "#cds-models/*": ["./@cds-models/*"] }
  }
}
EOF

  # --- mta.yaml ---
  create_file "${BASE}/mta.yaml" <<EOF
_schema-version: 3.3.0
ID: ${NAME}
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
  - name: ${NAME}-srv
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
          srv-url: \${default-uri}
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
EOF

  # --- .cdsrc.sample.json ---
  create_file "${BASE}/.cdsrc.sample.json" <<'EOF'
{
  "cds": {
    "requires": {
      "auth": { "kind": "dummy" }
    }
  }
}
EOF

  # --- .env.example ---
  create_file "${BASE}/.env.example" <<'EOF'
MODEL_NAME=gpt-4.1
# For local development:
# AICORE_SERVICE_KEY={"serviceurls":{"AI_API_URL":"https://..."},"clientid":"...","clientsecret":"...","url":"https://..."}
EOF

  # --- srv/service.cds ---
  create_file "${srv}/service.cds" <<'EOF'
@protocol: ['rest']
@path    : '/api'
service Service {
    action a2aAdapter(task: String) returns String;
}
EOF

  # --- srv/server.ts ---
  cat > "${srv}/server.ts" <<EOF
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
    VCAP ? \`https://\${JSON.parse(VCAP).application_uris[0]}/\` : "http://localhost:4004/";

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

const agentCard: AgentCard = {
    name: "${NAME}",
    description: "${DESCRIPTION}",
    url: getA2aServerUrl(),
    provider: { organization: "${NAMESPACE}", url: "https://example.com" },
    version: "1.0.0",
    capabilities: { streaming: true, pushNotifications: false, stateTransitionHistory: false },
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"],
    skills: [
        {
            id: "example-skill",
            name: "Example Skill",
            description: "${DESCRIPTION}",
            tags: ["example"],
            examples: ["What can you do?"],
            outputModes: ["text/plain"],
        },
    ],
    supportsAuthenticatedExtendedCard: false,
    protocolVersion: "0.3.0",
};
EOF
  echo "  Created: ${srv}/server.ts"

  # --- srv/agent-executor.ts ---
  create_file "${srv}/agent-executor.ts" <<'EOF'
import { v4 as uuidv4 } from "uuid";
import cds from "@sap/cds";
import { Task, TaskStatusUpdateEvent, Message } from "@a2a-js/sdk";
import { AgentExecutor, RequestContext, ExecutionEventBus } from "@a2a-js/sdk/server";
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

type AgentGraphState = { messages: BaseMessageLike[] };

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
            promptTemplating: { model: { name: process.env.MODEL_NAME || "gpt-4.1" } },
        });
        const modelWithTools = model.bindTools(agentTools);
        const toolNode = new ToolNode(agentTools);
        const stateGraph = new StateGraph(MessagesAnnotation)
            .addNode("agent", createAgentNode(modelWithTools))
            .addNode("tools", toolNode)
            .addEdge(START, "agent")
            .addConditionalEdges("agent", this.shouldContinue, ["tools", END])
            .addEdge("tools", "agent");
        this.app = stateGraph.compile({ checkpointer: new MemorySaver() });
    }

    async execute(requestContext: RequestContext, eventBus: ExecutionEventBus): Promise<void> {
        const userMessage = requestContext.userMessage;
        const existingTask = requestContext.task;
        const taskId = existingTask?.id || requestContext.taskId || uuidv4();
        const contextId = userMessage.contextId || existingTask?.contextId || uuidv4();

        if (!existingTask) {
            eventBus.publish(createNewTask(userMessage, { taskId, contextId }));
        }
        eventBus.publish(createMessageUpdate("Processing your request...", { taskId, contextId, final: false }));

        const historyForAgent = contexts.get(contextId) || [];
        if (!historyForAgent.find((m) => m.messageId === userMessage.messageId)) {
            historyForAgent.push(userMessage);
        }
        contexts.set(contextId, historyForAgent);

        const messages = a2aMessagesToLangChain(historyForAgent);
        const textParts = userMessage.parts.filter((part) => part.kind === "text");
        const messageText = textParts.map((part) => part.text).join(" ");

        let res;
        if (requestContext.task) {
            res = await this.app.stream(new Command({ resume: messageText }), { configurable: { thread_id: requestContext.taskId } });
        } else {
            res = await this.app.stream({ messages }, { configurable: { thread_id: taskId } });
        }

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
            type InterruptChunk = { __interrupt__: Array<{ value: any }> };
            const interruptValue = (chunk as InterruptChunk).__interrupt__[0].value;
            eventBus.publish(createInterruptUpdate(interruptValue, { taskId, contextId }));
            eventBus.finished();
            return;
        }

        const finalMessage: Message = createMessage(finalRes, { taskId, contextId });
        historyForAgent.push(finalMessage);
        contexts.set(contextId, historyForAgent);
        eventBus.publish(createMessageUpdate(finalMessage, { taskId, contextId, final: true }));
        eventBus.finished();
        logger.log(`Task ${taskId} completed`);
    }

    public cancelTask = async (taskId: string, eventBus: ExecutionEventBus): Promise<void> => {};

    private shouldContinue(state: AgentGraphState) {
        const messages = state.messages;
        const lastMessage = messages[messages.length - 1] as { tool_calls?: unknown[] } | undefined;
        return lastMessage?.tool_calls?.length ? "tools" : END;
    }
}
EOF

  # --- srv/tools/tools.ts ---
  create_file "${tools}/tools.ts" <<'EOF'
import { tool } from "@langchain/core/tools";
import { z } from "zod";

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
EOF

  # --- srv/utils/prompts.ts ---
  create_file "${utils}/prompts.ts" <<'EOF'
export const getSystemPrompt = (): string => {
    return `You are a helpful assistant.

When you have completed the user's request, provide your answer clearly.
When you need more information from the user, use the ask_expert tool.
If an error occurs, explain what went wrong.`;
};
EOF

  # --- srv/utils/a2aToLangchain.ts ---
  create_file "${utils}/a2aToLangchain.ts" <<'EOF'
import type { Message, TextPart } from "@a2a-js/sdk";
import { HumanMessage, AIMessage, SystemMessage, type BaseMessage } from "@langchain/core/messages";

function extractTextParts(m: Message): string {
    return (m.parts ?? [])
        .filter((p): p is TextPart => p.kind === "text" && typeof p.text === "string")
        .map((p) => p.text)
        .join("\n")
        .trim();
}

function toLangChainMessage(role: string, text: string): BaseMessage {
    switch (role) {
        case "user": return new HumanMessage(text);
        case "agent": case "assistant": return new AIMessage(text);
        case "system": return new SystemMessage(text);
        default: return new HumanMessage(text);
    }
}

export function a2aMessagesToLangChain(history: Message[]): BaseMessage[] {
    return history.map((m) => toLangChainMessage(m.role, extractTextParts(m)));
}
EOF

  # --- srv/utils/a2a-operations.ts ---
  create_file "${utils}/a2a-operations.ts" <<'EOF'
import { Message, Task, TaskStatusUpdateEvent } from "@a2a-js/sdk";
import { v4 as uuidv4 } from "uuid";

export function createNewTask(message: Message, options: { taskId: string; contextId: string }): Task {
    return {
        kind: "task", id: options.taskId, contextId: options.contextId,
        status: { state: "submitted", timestamp: new Date().toISOString() },
        history: [message], metadata: message.metadata,
    };
}

export function createMessageUpdate(message: string | Message, options: { taskId: string; contextId: string; final: boolean }): TaskStatusUpdateEvent {
    const statusMessage: Message = typeof message === "string"
        ? { kind: "message", messageId: uuidv4(), role: "agent", parts: [{ kind: "text", text: message }], taskId: options.taskId, contextId: options.contextId }
        : message;
    return {
        kind: "status-update", taskId: options.taskId, contextId: options.contextId,
        status: { state: options.final ? "completed" : "working", message: statusMessage, timestamp: new Date().toISOString() },
        final: false,
    };
}

export function createInterruptUpdate(message: string, options: { taskId: string; contextId: string }): TaskStatusUpdateEvent {
    return {
        kind: "status-update", taskId: options.taskId, contextId: options.contextId,
        status: {
            state: "input-required",
            message: { kind: "message", role: "agent", messageId: uuidv4(), parts: [{ kind: "text", text: message }], taskId: options.taskId, contextId: options.contextId },
            timestamp: new Date().toISOString(),
        },
        final: true,
    };
}

export function createMessage(message: string, options: { taskId: string; contextId: string }): Message {
    return { kind: "message", messageId: uuidv4(), role: "agent", parts: [{ kind: "text", text: message }], taskId: options.taskId, contextId: options.contextId };
}
EOF

  # --- srv/utils/helpers.ts ---
  create_file "${utils}/helpers.ts" <<'EOF'
const VCAP = process.env.VCAP_APPLICATION;

export const getA2aServerUrl = (): string =>
    VCAP ? `https://${JSON.parse(VCAP).application_uris[0]}/` : "http://localhost:4004/";
EOF
}

# ====================================================================
# COMMON README
# ====================================================================
create_readme() {
  if [[ "$FRAMEWORK" == "cap" ]]; then
    create_file "${BASE}/README.md" <<EOF
# ${NAME}

A LangGraph A2A agent on SAP CAP for Joule, powered by SAP GenAI Hub.

## Prerequisites

- \`mbt\` (MTA Build Tool): \`npm install -g mbt\`
- MTA CF CLI plugin: \`cf install-plugin multiapps\` (required for \`cf deploy\`)

## Local Development

\`\`\`bash
npm install
cp .cdsrc.sample.json .cdsrc.json
# Edit .cdsrc.json with your AI Core credentials
npm run watch
# Test: curl http://localhost:4004/.well-known/agent.json
\`\`\`

## Deploy to Cloud Foundry

\`\`\`bash
npm install
mbt build
cf deploy mta_archives/${NAME}_1.0.0.mtar
\`\`\`

> **Note:** If \`cf deploy\` fails with "unknown command", install the MTA plugin first: \`cf install-plugin multiapps\`

## Connect to Joule

1. Create BTP destination \`${DEST_NAME}\` pointing to the deployed agent URL
2. Deploy the Joule capability:
   \`\`\`bash
   cd joule-capability
   joule login
   joule deploy ./da.sapdas.yaml --compile -n "${SAFE_NAME}_a2a"
   \`\`\`

> **Note:** The capability namespace in \`joule-capability/capability.sapdas.yaml\` must be \`joule.ext\` — any other value will cause deployment to fail.

## Customization

1. Edit \`srv/tools/tools.ts\` — add your agent's tools
2. Edit \`srv/utils/prompts.ts\` — customize the system prompt
3. Edit \`srv/server.ts\` — update agent card skills
4. Edit \`joule-capability/scenarios/invoke_agent.yaml\` — set the scenario description
EOF
  else
    if [[ "$WITH_PP" == "true" ]]; then
      create_file "${BASE}/README.md" <<EOF
# ${NAME}

A LangGraph A2A agent on Express for Joule, with S/4HANA Public Cloud principal propagation.
The authenticated Joule user's identity flows through to S/4HANA — no shared service account.

## Prerequisites (Principal Propagation)

Before deploying, complete the BTP and S/4HANA configuration:

1. **BTP services** — create and bind:
   \`\`\`bash
   cf create-service xsuaa application ${NAME}-xsuaa -c xs-security.json
   cf create-service destination lite ${NAME}-destination
   \`\`\`
2. **BTP destinations** — see \`skills/principal-propagation/references/pp-btp-config.md\`
   - \`${DEST_NAME}\` (OAuth2UserTokenExchange — Joule → this agent)
   - \`${PP_S4_DEST}\` (OAuth2SAMLBearerAssertion — this agent → S/4HANA)
3. **S/4HANA setup** — see \`skills/principal-propagation/references/pp-s4hana-setup.md\`

## Local Development

\`\`\`bash
npm install
cp .env.example .env
# Edit .env with your AI Core credentials
npm run dev
# Test: curl http://localhost:8080/.well-known/agent.json
\`\`\`

## Deploy to Cloud Foundry

\`\`\`bash
cf login -a https://api.cf.${LANDSCAPE}.hana.ondemand.com
npm install
npm run build
cf push
\`\`\`

## Connect to Joule

The capability destination must use \`OAuth2UserTokenExchange\` (not \`NoAuthentication\`).
1. Verify destination \`${DEST_NAME}\` is created with \`OAuth2UserTokenExchange\`
2. Deploy the Joule capability:
   \`\`\`bash
   cd joule-capability
   joule login
   joule deploy ./da.sapdas.yaml --compile -n "${SAFE_NAME}_a2a"
   \`\`\`

## Customization

1. Edit \`src/tools.ts\` — replace placeholder entity/service with your S/4HANA API
2. Edit \`src/agent.ts\` — customize the system prompt
3. Edit \`src/agentCard.ts\` — update agent card skills
4. Edit \`joule-capability/scenarios/invoke_agent.yaml\` — set the scenario description
EOF
    else
      create_file "${BASE}/README.md" <<EOF
# ${NAME}

A LangGraph A2A agent on Express for Joule, powered by SAP GenAI Hub.

## Local Development

\`\`\`bash
npm install
cp .env.example .env
# Edit .env with your AI Core credentials
npm run dev
# Test: curl http://localhost:8080/.well-known/agent.json
\`\`\`

## Deploy to Cloud Foundry

\`\`\`bash
cf login -a https://api.cf.${LANDSCAPE}.hana.ondemand.com
npm install
npm run build
cf push
\`\`\`

## Connect to Joule

1. Create BTP destination \`${DEST_NAME}\` pointing to \`https://${APP_ROUTE}\`
2. Deploy the Joule capability:
   \`\`\`bash
   cd joule-capability
   joule login
   joule deploy ./da.sapdas.yaml --compile -n "${SAFE_NAME}_a2a"
   \`\`\`

## Customization

1. Edit \`src/tools.ts\` — add your agent's tools
2. Edit \`src/agent.ts\` — customize the system prompt
3. Edit \`src/agentCard.ts\` — update agent card skills
4. Edit \`joule-capability/scenarios/invoke_agent.yaml\` — set the scenario description
EOF
    fi
  fi
}

# ====================================================================
# MAIN
# ====================================================================

# Generate framework-specific files
if [[ "$FRAMEWORK" == "cap" ]]; then
  scaffold_cap
else
  scaffold_express
fi

# Generate shared Joule capability files
create_joule_capability

# Generate README
create_readme

echo ""
echo "============================================"
echo " Project scaffolded at: ${BASE}"
echo " Framework: ${FRAMEWORK}"
if [[ "$WITH_PP" == "true" ]]; then
echo " Principal propagation: ENABLED (S/4HANA Public Cloud)"
fi
echo "============================================"
echo ""
echo "Next steps:"
if [[ "$FRAMEWORK" == "cap" ]]; then
  echo "  1. cd ${BASE} && npm install"
  echo "  2. Edit srv/tools/tools.ts with your tools"
  echo "  3. Edit srv/utils/prompts.ts with your system prompt"
  echo "  4. Edit joule-capability/scenarios/invoke_agent.yaml description"
  echo "  5. npm run watch  (local dev)"
else
  echo "  1. cd ${BASE} && npm install"
  if [[ "$WITH_PP" == "true" ]]; then
  echo "  2. Set up BTP services and destinations (see skills/principal-propagation/references/pp-btp-config.md)"
  echo "  3. Set up S/4HANA (see skills/principal-propagation/references/pp-s4hana-setup.md)"
  echo "  4. Edit src/tools.ts — replace TODO_SERVICE_SRV and entity set names with your S/4HANA API"
  echo "  5. Edit src/agent.ts SYSTEM_PROMPT"
  echo "  6. Edit joule-capability/scenarios/invoke_agent.yaml description"
  echo "  7. npm run build && cf push"
  else
  echo "  2. Edit src/tools.ts with your tools"
  echo "  3. Edit src/agent.ts SYSTEM_PROMPT"
  echo "  4. Edit joule-capability/scenarios/invoke_agent.yaml description"
  echo "  5. npm run dev  (local dev)"
  fi
fi
