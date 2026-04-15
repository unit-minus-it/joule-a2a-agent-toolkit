---
description: Create a BTP destination for a Joule A2A agent
allowed-tools: Read, Bash
argument-hint: <agent-name> <destination-name> <landscape>
---

Create a BTP HTTP destination that connects Joule to a CF-deployed A2A agent.

Run the destination creation script at `${CLAUDE_PLUGIN_ROOT}/skills/joule-a2a-agent/scripts/create-destination.sh` with the provided arguments.

Parse arguments from `$ARGUMENTS`:
- First argument: CF app name of the deployed agent
- Second argument: BTP destination name (must match `system_aliases.<AliasName>.destination` in capability.sapdas.yaml)
- Third argument: CF landscape (e.g. eu10, us10)

If arguments are missing, ask the user for:
1. The CF app name (from `cf apps`)
2. The destination name they want
3. The CF landscape

Run the script:
```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/joule-a2a-agent/scripts/create-destination.sh \
  --agent-name <agent-name> \
  --destination-name <destination-name> \
  --landscape <landscape>
```

Prerequisites: `cf` CLI must be logged in and targeting the correct org/space.
