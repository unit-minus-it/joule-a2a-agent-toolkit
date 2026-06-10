# Principal Propagation — S/4HANA Public Cloud Setup

> **Scope:** S/4HANA Public Cloud only. On-premise and Private Cloud have different setup paths.

## Prerequisites

Before starting:
- Access to S/4HANA Fiori Launchpad with admin rights (Communication Management apps)
- Your BTP subaccount GUID and region (see `pp-btp-config.md` — Finding the SAML Issuer Entity ID)
- The Active Trust Certificate exported from BTP (see `pp-btp-config.md` — Downloading the BTP Signing Certificate)

---

## Step 1: Create the Communication User

The Communication User is the technical account the BTP Destination Service authenticates as (via Basic auth) when requesting the SAML Bearer token exchange at S/4HANA's OAuth endpoint.

**Navigation:** Fiori Launchpad → Search `Maintain Communication Users` → Open

1. Click **New** (or identify an existing user you will reuse)
2. Fill in:
   - **User Name**: a descriptive identifier, e.g. `BTP_PRINCPROP`
     — this is what you set as `tokenServiceUser` in the BTP `OAuth2SAMLBearerAssertion` destination
   - **Description**: e.g. `BTP Principal Propagation`
   - **Password**: set a clean alphanumeric password
     - 20+ characters recommended
     - **No special characters** (`!`, `$`, `@`, etc.) — special characters in passwords have caused authentication failures when BTP sends Basic auth headers to S/4HANA's token endpoint
3. Note down the User Name and Password — you will need both when creating the BTP destination

---

## Step 2: Create the Communication System

The Communication System represents your BTP subaccount in S/4HANA and hosts the OAuth 2.0 Identity Provider configuration.

**Navigation:** Fiori Launchpad → Search `Communication Systems` → Open → Click **New**

### Section: General

**Sub-section: General Data**

| Field | Value | Notes |
|-------|-------|-------|
| System ID | e.g. `BTP_CF_SUBACCOUNT` | Any unique identifier; use something that identifies your BTP subaccount |
| System Name | same as System ID | |

**Sub-section: Technical Data → General**

| Field | Value | Notes |
|-------|-------|-------|
| Host Name | `<subdomain>.authentication.<region>.hana.ondemand.com` | The authentication endpoint of your BTP subaccount. Find it in BTP Cockpit → subaccount → Overview, or from any XSUAA service key's `url` field (remove `https://`) |
| Logical System | e.g. `BTPCLNT100` | Technically optional but must be set — S/4HANA throws an error on save if left blank. Use any meaningful identifier in the format `<PREFIX>CLNT<NUMBER>` |
| Business System | e.g. `BTP_CF_SPACE` | Technically optional but must be set — same reason. Use a name that identifies your BTP CF space or subaccount |

**Sub-section: Technical Data → OAuth 2.0 Settings**

- Enable this section using the **toggle switch** — this reveals the Identity Provider sub-section below

### Sub-section: Identity Provider

| Field | Value | Notes |
|-------|-------|-------|
| User ID Mapping Mode | `Global User ID` | S/4HANA uses the SAML NameID value to look up the Business User |
| OAuth 2.0 SAML Issuer | `cfapps.<region>.hana.ondemand.com/<subaccount-guid>` | The entity ID of the BTP Destination Service — **not** the XSUAA entity. See note below on how to derive this value. |
| Upload Signing Certificate | Upload the `.pem` file from BTP | Source: BTP Cockpit → Connectivity → Destination Trust → Active Trust Certificate → Export. ⚠️ Do NOT upload the full SAML metadata XML — S/4HANA cannot parse it. Upload only the raw certificate. |

**After uploading the certificate**, two read-only display fields will be populated:

| Display Field | Expected value |
|---------------|----------------|
| Signing Certificate | `OU=CP Destination Configuration,O=SAP,CN=cfapps.<region>.hana.ondemand.com/<subaccount-guid>` |
| Signing Certificate Issuer | same as Signing Certificate |

> **Tip — deriving the SAML Issuer from the certificate:**
> After uploading the certificate, look at the **CN (Common Name)** value in the Signing Certificate display field. It will show `CN=cfapps.<region>.hana.ondemand.com/<subaccount-guid>`. Copy the part after `CN=` and paste it into the **OAuth 2.0 SAML Issuer** field. This is the most reliable way to ensure the issuer matches the certificate.

> ⚠️ **Common mistake:** Using the XSUAA entity ID (`https://<subdomain>.authentication.<region>.hana.ondemand.com`) as the SAML Issuer. This gives `invalid_client`. The Destination Service entity always starts with `cfapps.`, never with `https://`.

### Section: Users for Inbound Communication

1. Click the **`+`** button — a popup appears: *New Inbound Communication User*
2. Set:
   - **Authentication Method**: `User Name and Password`
   - **User Name / Client ID**: the User Name from Step 1 (e.g. `BTP_PRINCPROP`)
3. Click **OK**
4. Click **Save** on the Communication System

**After saving**, S/4HANA automatically creates a second entry in this section:
- **Authentication Method**: `OAuth 2.0 (Confidential Client / SAML 2.0 Bearer Assertion)`
- **User Name / Client ID**: same user as above

> This second entry cannot be created manually — it is auto-generated when you save. Its presence confirms that S/4HANA has registered the user for SAML Bearer Assertion flows.

---

## Step 3: Create the Communication Arrangement

The Communication Arrangement links the Communication System to a specific S/4HANA API scenario and configures how inbound calls are authenticated.

**Navigation:** Fiori Launchpad → Search `Communication Arrangements` → Open → Click **New**

A dialog appears — select the **Communication Scenario** for the API your agent needs, then click **Create**. Examples:
- `SAP_COM_0053` — Business Partner
- `SAP_COM_0746` — Purchase Orders (`API_PURCHASEORDER_PROCESS_SRV`)
- `SAP_COM_0008` — Sales Orders
- Search by scenario code or API name to find the right one

### Section: Common Data

| Field | Value | Notes |
|-------|-------|-------|
| Arrangement Name | e.g. `SAP_COM_0053_BTP_PP` | Convention: `<SCENARIO>_BTP_PP` makes it easy to identify later |
| Communication System | select the system from Step 2 | e.g. `BTP_CF_SUBACCOUNT` |

### Section: Inbound Communication

Click the input field next to **OAuth 2.0 Client ID** — this opens a selection popup titled *Select User/Certificate for Inbound Services*.

> ⚠️ The Communication User appears **twice** in this list — once under the OAuth 2.0 section and once under User ID and Password. You must select the user from the **OAuth 2.0 section**.

After selecting the user, the following fields auto-populate (read-only — cannot be set manually):

| Field | Value |
|-------|-------|
| OAuth 2.0 Grant Type | `SAML 2.0 Bearer Assertion` |
| OAuth 2.0 Client Type | `Confidential Client` |
| Authentication Method | `OAuth 2.0` |

These values confirm that S/4HANA will accept SAML Bearer Assertions for this arrangement. If the user was accidentally selected from the User ID and Password section instead, these fields will show different values and the token exchange will fail.

### Section: Inbound Services

This section lists the specific services, application protocols, and endpoint URLs included in this Communication Scenario. The content differs per scenario.

> **Important for agent development:** The service entries here tell you:
> - The **application protocol** (OData v2, OData v4, REST, etc.)
> - The **Service URL / Instance** — the exact OData service path to use in `ODATA_BASE` in `src/tools.ts`
>
> Always verify the service path from this section rather than assuming from documentation, as paths differ between OData v2 and v4 and between scenarios.

Click **Save**.

### Verifying OAuth 2.0 Scopes and Business Catalog Authorization

After saving, exit edit mode and return to the arrangement view. In the **Inbound Communication** section, click the **OAuth 2.0 Details** button.

A popup appears listing the **OAuth 2.0 Scope IDs** included in this arrangement. For each scope:
1. Select the scope
2. Click **Granted by Business Catalogs**
3. A list appears showing every Business Catalog that grants access to this scope

This tells you which Business Catalogs a Business User must have assigned (via a Business Role) to be authorized to call this API. If a user's token exchange succeeds but the API call returns a 403 or authorization error, use this view to check whether the propagated user has the required Business Catalogs assigned in their Business Role.

---

## Step 4: Verify Business User Mapping

For principal propagation to correctly identify the Joule user in S/4HANA, the user's email address must exist as a Business User. Understanding the linking chain helps diagnose any identity mismatch.

### The Linking Pin

The identity flows through three hops — each must carry the same email value:

| Hop | Where | Value |
|-----|-------|-------|
| 1 | BTP Destination — `userIdSource: email` and `nameIdFormat: urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress` | Instructs the Destination Service to read the `email` claim from the user's JWT and write it as the SAML `NameID` |
| 2 | SAML Bearer Assertion — `NameID` element | Contains the user's email as a plain string (email format) |
| 3 | S/4HANA Communication System — `User ID Mapping Mode: Global User ID` | Matches the `NameID` value against the **Email** field of the Business User record |

The user logs into Joule with an email address (e.g. `user@company.com`). That email ends up in the `email` claim of the BTP JWT. The Destination Service reads it, puts it in the SAML assertion as the `NameID`, and S/4HANA looks up a Business User whose Email field matches it exactly.

> **Consequence:** If the email addresses differ — even in casing or by using an alias — S/4HANA may issue a token but attribute the action to the wrong user, or fail the user lookup entirely.

### Verification Steps

**Navigation:** Fiori Launchpad → Search `Maintain Business Users` → Open

1. Search by **Email** for the Joule user (e.g. `user@company.com`)
2. Confirm the user is **Active**
3. The **Email** field in the Business User record must **exactly match** the `email` claim in the user's BTP JWT — this is the email address the user logs into BTP/Joule with

---

## Summary Checklist

- [ ] Communication User created in `Maintain Communication Users` with clean alphanumeric password
- [ ] Communication System created with correct Host Name, Logical System, and Business System
- [ ] OAuth 2.0 Settings toggle enabled
- [ ] Signing certificate uploaded (raw `.pem` from BTP Connectivity → Destination Trust → Active Trust Certificate → Export)
- [ ] OAuth 2.0 SAML Issuer set to the CN value from the uploaded certificate (`cfapps.<region>.hana.ondemand.com/<subaccount-guid>`)
- [ ] User added to Inbound Communication (User Name and Password method)
- [ ] Auto-generated OAuth 2.0 entry visible after save
- [ ] Communication Arrangement created with the correct Scenario
- [ ] In Inbound Communication: user selected from the **OAuth 2.0 section** (not User ID and Password section)
- [ ] Auto-populated fields show: Grant Type = `SAML 2.0 Bearer Assertion`, Client Type = `Confidential Client`
- [ ] Inbound Services section reviewed — OData service path noted for use in `ODATA_BASE` in `src/tools.ts`
- [ ] Joule user exists as Active Business User in S/4HANA (`Maintain Business Users`) with email exactly matching the BTP JWT `email` claim

---

## Troubleshooting

| Error | Likely cause | Fix |
|-------|-------------|-----|
| `invalid_client` | SAML Issuer is the XSUAA entity, not the Destination Service entity | Re-set SAML Issuer to the CN value from the uploaded certificate |
| `invalid_grant` — "Error in ST program SAML2_ASSERTION" | Wrong certificate uploaded (e.g. from SAML metadata XML) | Re-upload using the Active Trust Certificate from BTP Connectivity → Destination Trust |
| `No OAuth 2.0 client authentication credentials` | S/4HANA requires Basic auth; only `client_id` was sent | Use `tokenServiceUser` + `tokenServicePassword` in the BTP destination |
| `401` with communication user credentials | Special characters in password | Reset password to alphanumeric only |
| API call succeeds but action logged as `BTP_PRINCPROP` | Business User not found by email | Verify user exists in `Maintain Business Users` with email matching the BTP JWT `email` claim exactly |
| Error on saving Communication System | Logical System or Business System left blank | Both must be filled even though shown as optional |
