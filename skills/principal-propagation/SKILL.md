---
name: principal-propagation
description: |
  Add S/4HANA Public Cloud principal propagation to a Joule A2A agent. This skill enables the agent to call S/4HANA as the authenticated Joule user rather than as a technical service account, creating an auditable identity trail. Use this skill when the user mentions: principal propagation, user identity forwarding, OAuth2SAMLBearerAssertion to S/4HANA, calling S/4HANA as the logged-in user, propagating the Joule user to S/4HANA, or "the S/4HANA call should use the user's identity".
---

# Principal Propagation — S/4HANA Public Cloud

> **Scope:** This skill covers S/4HANA Public Cloud only. On-premise and Private Cloud setup is different and not yet documented in this toolkit.

This skill adds principal propagation to an existing (or new) Joule A2A agent. The user's identity flows from Joule through BTP Cloud Foundry to S/4HANA, so every S/4HANA call is auditable to the individual user rather than a shared service account.

## How It Works

```
Joule user
  → <AgentName>_A2A destination  (OAuth2UserTokenExchange — exchanges user token)
  → CF agent                      (extracts JWT, passes to Cloud SDK)
  → S4_<AGENT>_PP destination     (OAuth2SAMLBearerAssertion — converts JWT → SAML → S/4HANA token)
  → S/4HANA Public Cloud          (receives call as the Joule user)
```

Three layers must be configured:
1. **Code** — three changes to the CF agent
2. **BTP** — two service instances + two destinations
3. **S/4HANA** — Communication System, Communication User, Communication Arrangement

## Workflow

### Step 1: Apply Code Changes

Read `references/pp-code.md` for all code changes.

If scaffolding a new agent, use:
```bash
bash <skill-path>/../joule-a2a-agent/scripts/scaffold-ts.sh \
  --name <agent-name> \
  --with-principal-propagation \
  --landscape <cf-landscape>
```

If adding PP to an existing agent:
1. Create `src/context.ts` (AsyncLocalStorage for JWT)
2. Create `src/destination.ts` (destOptions + fetchCsrfToken helpers)
3. Add JWT extraction middleware to `src/index.ts`
4. Add `@sap-cloud-sdk/http-client` to `package.json`
5. Add XSUAA and destination service bindings to `manifest.yml`
6. Add `xs-security.json`

### Step 2: Configure BTP

Read `references/pp-btp-config.md` for all BTP configuration steps.

1. Create XSUAA service instance: `cf create-service xsuaa application <agent-name>-xsuaa -c xs-security.json`
2. Create destination service instance: `cf create-service destination lite <agent-name>-destination`
3. Bind both in `manifest.yml` and push the CF app
4. Create the `OAuth2UserTokenExchange` destination (Joule → CF agent)
5. Create the `OAuth2SAMLBearerAssertion` destination (CF agent → S/4HANA)

### Step 3: Configure S/4HANA Public Cloud

Read `references/pp-s4hana-setup.md` for all S/4HANA configuration steps.

1. Create Communication System with OAuth 2.0 Identity Provider
2. Upload the BTP Destination Service signing certificate
3. Create Communication User
4. Create Communication Arrangement for the target API
5. Verify the Joule user exists as a Business User in S/4HANA

### Step 4: Update the Joule Capability Destination

The capability's `system_aliases` destination must use `OAuth2UserTokenExchange` (not `NoAuthentication`). If the capability was created before adding PP, update `capability.sapdas.yaml` and redeploy:
```bash
cd joule-capability
joule deploy ./da.sapdas.yaml --compile -n "<assistant_name>"
```

### Step 5: Test

Deploy and test via Joule. If something fails, check `references/pp-btp-config.md` for the httpbin intercept diagnostic technique and consult `../joule-a2a-agent/references/troubleshooting.md` for the SAML/CSRF error entries.

## Reference Files

- `references/pp-code.md` — all code changes with complete templates
- `references/pp-btp-config.md` — BTP service instances, both destinations, SAML entity ID discovery
- `references/pp-s4hana-setup.md` — S/4HANA manual setup steps (draft — verify with your system)
