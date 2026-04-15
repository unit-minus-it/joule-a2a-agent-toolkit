---
description: Scaffold a new Joule A2A agent project
allowed-tools: Read, Write, Edit, Bash, Grep, Glob, Agent
argument-hint: <agent-name> [--lang python|typescript] [--framework cap|express] [--landscape eu10]
---

Create a new Joule A2A agent project using the joule-a2a-agent skill.

Read the skill at `${CLAUDE_PLUGIN_ROOT}/skills/joule-a2a-agent/SKILL.md` first, then follow its workflow starting from Step 2 (Generate the Agent Project).

Use the arguments provided by the user:
- First positional argument: agent name (kebab-case)
- `--lang`: TypeScript (default) or Python
- `--framework`: Express (default) or CAP (TypeScript only)
- `--landscape`: CF landscape (default: eu10)

If the user provided `$ARGUMENTS`, parse the agent name and options from it. If no arguments were given, ask the user for the agent name and purpose.

For TypeScript projects, use the scaffold script:
```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/joule-a2a-agent/scripts/scaffold-ts.sh \
  --name <agent-name> \
  --framework <express|cap> \
  --namespace <namespace> \
  --output <output-dir> \
  --description "<description>" \
  --landscape <landscape>
```

For Python projects, use the Python scaffold script:
```bash
python ${CLAUDE_PLUGIN_ROOT}/skills/joule-a2a-agent/scripts/scaffold.py \
  --name <agent-name> \
  --namespace <namespace> \
  --output <output-dir> \
  --description "<description>" \
  --landscape <landscape>
```

Note: CAP framework is only available for TypeScript. If user requests `--lang python --framework cap`, inform them CAP is TypeScript-only and fall back to Express.

Save the generated project to the user's current working directory.
