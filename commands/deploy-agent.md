---
description: Deploy agent to CF and Joule in one go
allowed-tools: Read, Bash, Grep
argument-hint: [project-directory]
---

Deploy a Joule A2A agent project end-to-end: push to Cloud Foundry, create the BTP destination, and deploy the capability to Joule.

If `$ARGUMENTS` is provided, use it as the project directory. Otherwise use the current directory.

Execute these steps in order:

1. **Detect project type.** Check the project directory:
   - If `mta.yaml` exists → CAP project (deploy via MTA)
   - If `manifest.yml` exists with `python_buildpack` → Python Express
   - If `manifest.yml` exists with `nodejs_buildpack` → TypeScript Express
   - Verify `joule-capability/capability.sapdas.yaml` and `joule-capability/da.sapdas.yaml` exist.

2. **Pre-flight: Check Joule tenant schema compatibility.**
   Code-based agents (BYOA) using the `agent-request` action require Joule DTA schema version **3.28.0+**.

   a. Authenticate Joule CLI first. Look for a `.env` file that contains `JOULE_AUTH_URL`. If found:
      ```bash
      joule login --use-env <path-to-.env>
      ```
      If no `.env` is found, try `joule status` to check if already logged in.

   b. Try a test deploy to detect version issues early:
      ```bash
      cd <project-dir>/joule-capability
      joule deploy ./da.sapdas.yaml --compile -n "<assistant-name>" -d 2>&1
      ```
      If deploy fails with **"Schema version defined in config file is greater than the current schema version of Joule"**:
      - STOP immediately
      - Tell the user their Joule tenant doesn't support A2A capabilities yet (requires schema 3.28.0+)
      - Suggest: contact BTP admin for a Joule service update, or use a subaccount with a newer Joule instance
      - Show what DID succeed so those don't need to be redone
      - Do NOT continue

3. **Deploy to Cloud Foundry:**

   For CAP projects:
   ```bash
   cd <project-dir> && npm install && mbt build && cf deploy mta_archives/<ID>_<version>.mtar
   ```

   For TypeScript Express projects (must build locally first — `nodejs_buildpack` skips devDependencies in production):
   ```bash
   cd <project-dir> && npm install && npm run build && cf push
   ```

   For Python Express projects:
   ```bash
   cd <project-dir> && cf push
   ```

4. Wait for the app to start, then verify the agent card:
   ```bash
   curl -s https://<app-route>/.well-known/agent.json | head -20
   ```

5. Extract the destination name from `capability.sapdas.yaml`:
   - Look for `system_aliases:` → `<AliasName>:` → `destination: <DEST_NAME>`
   - Extract the app name from `manifest.yml` (Express) or `mta.yaml` (CAP — module name)

6. **Create the BTP destination:**
   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/skills/joule-a2a-agent/scripts/create-destination.sh \
     --agent-name <app-name> \
     --destination-name <DEST_NAME> \
     --landscape <landscape>
   ```

7. **Deploy to Joule:**
   ```bash
   cd <project-dir>/joule-capability
   joule deploy ./da.sapdas.yaml --compile -n "<assistant-name>"
   ```

Report the status of each step in a summary table. If any step fails, stop and show the error with troubleshooting guidance.
