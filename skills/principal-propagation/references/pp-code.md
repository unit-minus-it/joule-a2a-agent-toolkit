# Principal Propagation — Code Changes Reference

All code changes required to add S/4HANA principal propagation to a TypeScript Express agent.

## Overview of Changes

| File | Change |
|------|--------|
| `src/context.ts` | New — AsyncLocalStorage for per-request JWT |
| `src/destination.ts` | New — `destOptions()` + `fetchCsrfToken()` helpers |
| `src/index.ts` | Add JWT extraction middleware |
| `src/tools.ts` | Use `destOptions()` + `fetchCsrfToken()` instead of plain `fetch` |
| `package.json` | Add `@sap-cloud-sdk/http-client` |
| `manifest.yml` | Add XSUAA and destination service bindings |
| `xs-security.json` | New — XSUAA app descriptor |

---

## 1. `src/context.ts` (new file)

AsyncLocalStorage propagates the user JWT through async call chains without threading it through every function argument.

```typescript
import { AsyncLocalStorage } from "node:async_hooks";

// Stores the incoming Bearer JWT per request.
// Set in Express middleware before jsonRpcHandler; read in tool calls via destOptions().
export const userJwtStorage = new AsyncLocalStorage<string | undefined>();
```

---

## 2. `src/destination.ts` (new file)

Centralises the two PP helpers so every tool can import them without duplicating logic.

```typescript
import { executeHttpRequest } from "@sap-cloud-sdk/http-client";
import { userJwtStorage } from "./context.js";

/**
 * Returns destination options for Cloud SDK executeHttpRequest.
 * Passes the user JWT so the Destination Service resolves OAuth2SAMLBearerAssertion
 * on behalf of the individual user rather than the technical service account.
 */
export function destOptions(destinationName: string) {
  return { destinationName, jwt: userJwtStorage.getStore() };
}

/**
 * Fetches a CSRF token and session cookie from an OData v2 service.
 * Both must be forwarded to any mutating request (POST / PUT / DELETE).
 *
 * OData v2 CSRF tokens are bound to a session cookie. If you send the token
 * without the session cookie, S/4HANA returns HTTP 403 "CSRF token validation failed".
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
```

---

## 3. `src/index.ts` — add JWT middleware

Add `Request`, `Response`, `NextFunction` to the express import and import `userJwtStorage`.
Insert the middleware **after** `app.use(express.json())` and **before** the agent card handler.

```typescript
import express, { Request, Response, NextFunction } from "express";
import {
  jsonRpcHandler,
  agentCardHandler,
  UserBuilder,
} from "@a2a-js/sdk/server/express";
import {
  InMemoryTaskStore,
  ServerCallContext,
} from "@a2a-js/sdk/server";
import { DefaultRequestHandler } from "@a2a-js/sdk/server";
import { agentCard } from "./agentCard.js";
import { MyAgentExecutor } from "./executor.js";
import { userJwtStorage } from "./context.js";   // ← ADD

// JouleFriendlyRequestHandler — prevents TaskNotFoundError on multi-turn conversations
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

// ── Principal Propagation ────────────────────────────────────────────────────
// Extract the Bearer JWT from every incoming request and store it in
// AsyncLocalStorage. Tools read it via destOptions() in src/destination.ts.
app.use((req: Request, _res: Response, next: NextFunction) => {
  const authHeader = req.headers.authorization;
  const jwt = authHeader?.startsWith("Bearer ") ? authHeader.slice(7) : undefined;
  userJwtStorage.run(jwt, next);
});
// ────────────────────────────────────────────────────────────────────────────

app.use("/.well-known/agent.json", agentCardHandler({ agentCardProvider: async () => agentCard }));
app.use("/", jsonRpcHandler({ requestHandler, userBuilder: UserBuilder.noAuthentication }));

app.listen(PORT, () => {
  console.log(`A2A agent running at http://localhost:${PORT}`);
});
```

---

## 4. `src/tools.ts` — use destOptions and fetchCsrfToken

Replace `fetch()` calls with `executeHttpRequest()` using `destOptions()`.
For OData v2 read operations use `destOptions` only.
For OData v2 mutations (POST/PUT/DELETE) always fetch the CSRF token first.

```typescript
import { tool } from "@langchain/core/tools";
import { z } from "zod";
import { executeHttpRequest } from "@sap-cloud-sdk/http-client";
import { destOptions, fetchCsrfToken } from "./destination.js";

// ── Configuration ─────────────────────────────────────────────────────────────
// Set these to match your S/4HANA destination and OData service.
const DESTINATION = "S4_MY_AGENT_PP";          // name of the OAuth2SAMLBearerAssertion destination in BTP
const ODATA_BASE  = "/sap/opu/odata/sap/API_MY_SERVICE_SRV";  // OData v2 service base path
// ─────────────────────────────────────────────────────────────────────────────

// ── Read operation ────────────────────────────────────────────────────────────
const getRecords = tool(
  async ({ maxResults }) => {
    try {
      const response = await executeHttpRequest(destOptions(DESTINATION), {
        method: "GET",
        url: `${ODATA_BASE}/EntitySet`,
        params: { $format: "json", $top: String(maxResults ?? 10) },
        headers: { Accept: "application/json" },
      });
      const results: unknown[] = response.data?.d?.results ?? [];
      if (!results.length) return "No records found.";
      return JSON.stringify({ count: results.length, results }, null, 2);
    } catch (error) {
      const e = error as { response?: { status?: number; data?: unknown }; message?: string };
      return `Error: HTTP ${e.response?.status ?? "unknown"} — ${JSON.stringify(e.response?.data ?? e.message)}`;
    }
  },
  {
    name: "get_records",
    description: "Read records from S/4HANA. Replace with your actual entity set and fields.",
    schema: z.object({
      maxResults: z.number().optional().describe("Maximum records to return (default: 10)"),
    }),
  }
);

// ── Mutating operation (POST) — always include CSRF token + session cookie ───
const createRecord = tool(
  async ({ field1, field2 }) => {
    try {
      const { token, cookie } = await fetchCsrfToken(DESTINATION, ODATA_BASE);

      const response = await executeHttpRequest(destOptions(DESTINATION), {
        method: "POST",
        url: `${ODATA_BASE}/EntitySet`,
        data: { Field1: field1, Field2: field2 },
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
      return `Error: HTTP ${e.response?.status ?? "unknown"} — ${JSON.stringify(e.response?.data ?? e.message)}`;
    }
  },
  {
    name: "create_record",
    description: "Create a record in S/4HANA. Replace with your actual entity set and fields.",
    schema: z.object({
      field1: z.string().describe("First field value"),
      field2: z.string().describe("Second field value"),
    }),
  }
);

export function getTools() {
  return [getRecords, createRecord];
}
```

### Important: OData v2 field names

OData v2 field names are case-sensitive and must match the S/4HANA API exactly. If you get `HTTP 400: Property 'X' is invalid`, drop all `$select` filters on the first call, inspect the actual field names in the response, then add them back. Do not assume field names from documentation — always verify against a live response.

---

## 5. `package.json` — add Cloud SDK dependency

```json
"dependencies": {
  "@a2a-js/sdk": "0.3.10",
  "@langchain/core": "^1.1.32",
  "@langchain/langgraph": "^1.2.2",
  "@sap-ai-sdk/langchain": "^2.8.0",
  "@sap-ai-sdk/orchestration": "^2.8.0",
  "@sap-cloud-sdk/http-client": "^4.0.0",
  "express": "^4.21.0",
  "uuid": "^10.0.0",
  "zod": "^3.25.2"
}
```

---

## 6. `xs-security.json` (new file, in project root)

The XSUAA app descriptor that enables OAuth2UserTokenExchange (user token forwarding).

```json
{
  "xsappname": "<agent-name>",
  "tenant-mode": "dedicated",
  "scopes": [],
  "role-templates": [],
  "oauth2-configuration": {
    "token-validity": 43200,
    "redirect-uris": [
      "https://<agent-name>.cfapps.<landscape>.hana.ondemand.com/**"
    ]
  }
}
```

Replace `<agent-name>` and `<landscape>` with your actual values.

---

## 7. `manifest.yml` — add service bindings

Two additional services are required:

```yaml
---
applications:
  - name: <agent-name>
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
      - <aicore-service>          # AI Core for GenAI Hub
      - <agent-name>-xsuaa        # XSUAA for OAuth2UserTokenExchange
      - <agent-name>-destination  # Destination Service for runtime OAuth2SAMLBearerAssertion resolution
    routes:
      - route: <agent-name>.cfapps.<landscape>.hana.ondemand.com
```

The XSUAA service provides the `user_token` grant type that lets BTP exchange the incoming Joule user JWT.
The destination service lets the Cloud SDK (`executeHttpRequest`) resolve the `OAuth2SAMLBearerAssertion` destination at runtime with the user JWT attached.

---

## Notes

- `context.ts` uses Node.js `AsyncLocalStorage` which is available in Node 16+. No extra package needed.
- `@sap-cloud-sdk/http-client` auto-reads service bindings from `VCAP_SERVICES` when deployed to CF. For local development, set `destinations` in a local `.env` file.
- The Cloud SDK's `executeHttpRequest` with `jwt` in the destination options tells the Destination Service to resolve the destination on behalf of that user. Without `jwt`, it falls back to the technical service account (client credentials).
