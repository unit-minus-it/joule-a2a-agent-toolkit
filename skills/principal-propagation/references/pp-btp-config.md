# Principal Propagation — BTP Configuration Reference

All BTP-side configuration required for S/4HANA principal propagation.

## Overview

| What | Why |
|------|-----|
| XSUAA service instance | Provides `user_token` grant — lets BTP exchange the Joule user's JWT |
| Destination service instance | Lets Cloud SDK resolve `OAuth2SAMLBearerAssertion` at runtime with the user JWT |
| `OAuth2UserTokenExchange` destination | Joule → CF agent — Joule exchanges user token before calling the agent |
| `OAuth2SAMLBearerAssertion` destination | CF agent → S/4HANA — converts user JWT to SAML assertion, then to S/4HANA OAuth token |

---

## Step 1: Create XSUAA Service Instance

From the agent project directory (where `xs-security.json` lives):

```bash
cf create-service xsuaa application <agent-name>-xsuaa -c xs-security.json
```

After creation, get the `clientid` and token URL from the service key — you will need these for the Joule-side destination:

```bash
cf create-service-key <agent-name>-xsuaa temp-key
cf service-key <agent-name>-xsuaa temp-key
# Note down: clientid, clientsecret, url (token endpoint base)
cf delete-service-key <agent-name>-xsuaa temp-key
```

The `clientid` looks like `sb-<agent-name>!t<number>`. The token URL is `<url>/oauth/token`.

---

## Step 2: Create Destination Service Instance

```bash
cf create-service destination lite <agent-name>-destination
```

> **Note:** If a destination service instance already exists in your space, you can reuse it — do not create duplicates. Check with `cf services`.

---

## Step 3: Bind Services and Push

Add both service names to `manifest.yml` services list (see `pp-code.md` section 7), then push:

```bash
npm run build
cf push
```

Verify the app started and both services appear as bound in `cf env <agent-name>`.

---

## Step 4: OAuth2UserTokenExchange Destination (Joule → CF Agent)

This destination replaces the standard `NoAuthentication` destination. Joule uses it to exchange the user's session token before calling the CF agent, so the agent receives a user-scoped JWT instead of an anonymous call.

Create in BTP Cockpit → <subaccount> → Connectivity → Destinations → **New Destination**:

| Property | Value |
|----------|-------|
| Name | `<AgentName>_A2A` — must exactly match `system_aliases.<AliasName>.destination` in `capability.sapdas.yaml` |
| Type | `HTTP` |
| URL | `https://<agent-name>.cfapps.<landscape>.hana.ondemand.com` |
| Proxy Type | `Internet` |
| Authentication | `OAuth2UserTokenExchange` |
| Client ID | `sb-<agent-name>!t<number>` (from XSUAA service key `clientid`) |
| Client Secret | from XSUAA service key `clientsecret` |
| Token Service URL | `https://<xsuaa-subdomain>.authentication.<region>.hana.ondemand.com/oauth/token` (from service key `url` field + `/oauth/token`) |

**Additional Properties:**

| Property | Value |
|----------|-------|
| `HTML5.DynamicDestination` | `true` |

> The `OAuth2UserTokenExchange` grant type is the key difference from a standard A2A destination. It tells BTP to exchange the authenticated user's token before forwarding the request. Without it, the CF agent receives no user identity.

---

## Step 5: OAuth2SAMLBearerAssertion Destination (CF Agent → S/4HANA)

This is the destination your tools reference in `destOptions(DESTINATION)`. The Destination Service generates a SAML 2.0 assertion from the user JWT, signs it with the BTP certificate, and exchanges it for an S/4HANA OAuth token.

Create in BTP Cockpit → <subaccount> → Connectivity → Destinations → **New Destination**:

| Property | Value |
|----------|-------|
| Name | Any name (e.g. `S4_<AGENTNAME>_PP`) — this is what you put in `DESTINATION` in `src/destination.ts` |
| Type | `HTTP` |
| URL | `https://<tenant>-api.s4hana.cloud.sap` |
| Proxy Type | `Internet` |
| Authentication | `OAuth2SAMLBearerAssertion` |
| Audience | `https://<tenant>.s4hana.cloud.sap` — ⚠️ without `-api` suffix |
| Client Key | `<communication-user>` (e.g. `BTP_PRINCPROP`) — the Communication User created in S/4HANA |
| Token Service URL | `https://<tenant>-api.s4hana.cloud.sap/sap/bc/sec/oauth2/token` — ⚠️ must use `-api` subdomain |
| Token Service User | `<communication-user>` |
| Token Service Password | password of the Communication User |
| Name ID Format | `urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress` |
| User ID Source | `email` |
| Authentication Context Class | `urn:oasis:names:tc:SAML:2.0:ac:classes:PreviousSession` |

> **Critical: two different subdomains**
> - `URL` and `tokenServiceURL` use `<tenant>-api.s4hana.cloud.sap`
> - `audience` uses `<tenant>.s4hana.cloud.sap` (no `-api`)
> Both are intentional. Using the wrong subdomain for either will cause `invalid_grant` errors.

> **Critical: Name ID Format**
> The default `urn:oasis:names:tc:SAML:2.0:assertion:subject-id:global-user-id` is not supported by S/4HANA Public Cloud's SAML Bearer flow. Always use `urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress` with `userIdSource: email`.

---

## Finding the SAML Issuer Entity ID

S/4HANA's OAuth 2.0 Identity Provider must be configured with the **Destination Service entity ID** — not the XSUAA entity ID. These are two different values even though they share the same signing certificate.

| | Value |
|--|--|
| **XSUAA entity** (wrong for PP) | `https://<xsuaa-subdomain>.authentication.<region>.hana.ondemand.com` |
| **Destination Service entity** (correct for PP) | `cfapps.<region>.hana.ondemand.com/<subaccount-guid>` |

To find your values:
- **Region**: visible in the CF API URL (e.g. `api.cf.eu20.hana.ondemand.com` → region is `eu20`). Note: use `eu20`, not `eu20-001` — the region in the entity ID never includes the `-001` suffix.
- **Subaccount GUID**: BTP Cockpit → your subaccount → Overview page → **Subaccount ID** field (UUID format)

**Example**: region `eu20`, subaccount GUID `4d0e92ba-d93b-42c2-80bc-6c63dd041cec` →
`cfapps.eu20.hana.ondemand.com/4d0e92ba-d93b-42c2-80bc-6c63dd041cec`

---

## Downloading the BTP Signing Certificate

S/4HANA must trust the BTP signing certificate to verify the SAML assertion.

**Exact path in BTP Cockpit:**
BTP Cockpit → your subaccount → **Connectivity** (left sidebar) → **Destination Trust** → **Active Trust Certificate** → **Export**

> ⚠️ **Do not use the SAML metadata XML** that you can download from Trust Configuration. That XML file has complex XML structure that S/4HANA's ABAP XML parser cannot handle. Export only the Active Trust Certificate from Destination Trust.

The exported file is a `.pem` file containing the raw X.509 certificate. Upload this in S/4HANA's Communication System → OAuth 2.0 Identity Provider → Signing Certificate field.

---

## Diagnostic: Intercepting the SAML Assertion (httpbin technique)

If you get `invalid_grant` errors and need to inspect the actual SAML assertion BTP is generating:

1. Temporarily change the destination's `tokenServiceURL` to `https://httpbin.org/anything`
2. Trigger the agent via Joule
3. Pull CF logs: `cf8 logs <agent-name> --recent`
4. Find the `POST` log line — the body contains the SAML assertion as a base64-encoded `assertion` form parameter
5. Decode: `echo "<base64value>" | base64 -d` (or use Python)
6. Inspect the XML: check `Issuer`, `NameID`, `Audience`, and the `ds:Signature` section

This technique was used to diagnose and fix the SAML issuer mismatch during initial development of this toolkit.

After diagnosing, restore `tokenServiceURL` to `https://<tenant>-api.s4hana.cloud.sap/sap/bc/sec/oauth2/token`.
