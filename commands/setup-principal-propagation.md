---
description: Set up S/4HANA Public Cloud principal propagation for a Joule A2A agent
allowed-tools: Read, Write, Edit, Bash, Grep, Glob, Agent
argument-hint: [agent-project-directory]
---

Set up principal propagation so the Joule user's identity flows through this CF agent to S/4HANA Public Cloud.

Read the skill at `${CLAUDE_PLUGIN_ROOT}/skills/principal-propagation/SKILL.md` first, then follow its workflow.

If `$ARGUMENTS` specifies a project directory, work in that directory. Otherwise work in the current directory.

## What this command does

1. **Applies code changes** to the agent project:
   - Creates `src/context.ts`
   - Creates `src/destination.ts`
   - Adds JWT middleware to `src/index.ts`
   - Adds `@sap-cloud-sdk/http-client` to `package.json`
   - Creates `xs-security.json`
   - Updates `manifest.yml` service bindings

2. **Guides BTP configuration** — walk the user through:
   - Creating XSUAA and destination service instances
   - Creating both BTP destinations (`OAuth2UserTokenExchange` and `OAuth2SAMLBearerAssertion`)

3. **Provides S/4HANA setup checklist** — present the steps from `references/pp-s4hana-setup.md` and ask the user to confirm each one is complete before testing

4. **Verifies the setup** — after the user confirms S/4HANA steps are done, rebuild and push, then instruct the user to test via Joule

## Important notes

- Only apply code changes to TypeScript Express agents. CAP and Python require different approaches (not yet documented).
- Do not overwrite `src/tools.ts` if it already has tool implementations — instead show the user the `destOptions` / `fetchCsrfToken` pattern from `references/pp-code.md` and let them apply it manually.
- The S/4HANA steps cannot be automated — they require Fiori UI access. Present them as a checklist.
- After code changes, always run `npm run build` to verify the TypeScript compiles before pushing.
