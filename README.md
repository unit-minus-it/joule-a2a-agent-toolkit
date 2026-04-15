<!-- Please include descriptive title -->

<!--- Register repository https://api.reuse.software/register, then add REUSE badge:
[![REUSE status](https://api.reuse.software/badge/github.com/SAP-samples/REPO-NAME)](https://api.reuse.software/info/github.com/SAP-samples/REPO-NAME)
-->

# SAP A2A Agent Toolkit Plugin

Build, deploy, and connect AI agents to SAP Joule via the A2A (Agent-to-Agent) protocol on BTP Cloud Foundry — all from Claude Code.

## What's Included

### Skills (auto-triggered by context)

| Skill | Triggers On | What It Does |
|-------|------------|--------------|
| **joule-a2a-agent** | "build an agent for Joule", "create A2A agent", "deploy agent to BTP", "CAP agent" | Scaffolds a complete LangGraph agent with A2A support (Express or CAP), CF manifest/MTA, and Joule capability YAML |
| **btp-cli** | "btp", "BTP CLI", subaccount management, entitlements | Generates correct `btp` commands for managing BTP global accounts, subaccounts, services, and security |
| **cf-cli** | "cf push", "Cloud Foundry", app deployment, service binding | Generates correct `cf` commands for deploying apps, managing services, routes, and spaces |
| **joule-cli** | "joule deploy", "joule compile", capability deployment | Generates correct Joule CLI commands for compiling and deploying digital assistant capabilities |

### Commands (user-invoked)

| Command | Usage | What It Does |
|---------|-------|--------------|
| `/sap-a2a-agent-toolkit:create-agent` | `/sap-a2a-agent-toolkit:create-agent po-assistant --lang typescript --framework cap --landscape eu10` | Scaffolds a new agent project in your working directory |
| `/sap-a2a-agent-toolkit:create-destination` | `/sap-a2a-agent-toolkit:create-destination po-assistant POAssistant_A2A eu10` | Creates a BTP HTTP destination connecting Joule to your CF agent |
| `/sap-a2a-agent-toolkit:deploy-agent` | `/sap-a2a-agent-toolkit:deploy-agent ./po-assistant` | Full deployment: CF push/MTA deploy + destination + Joule capability in one command |

## Prerequisites

- **cf CLI v8** installed and logged in (`cf login `)
- **Joule CLI** installed (`npm install -g @sap/joule-studio-cli`) and logged in (`joule login`)
- **BTP subaccount** with Cloud Foundry runtime, AI Core service, and Destination service
- **Node.js** v24.x (for TypeScript agents and Joule CLI)
- **Python 3.12+** (for Python agents only)
- **jq** (for the destination creation script)
- **mbt** (MTA Build Tool, for CAP agents only): `npm install -g mbt`

## Getting Started

Start Claude Code with the toolkit plugin, then log in to CF and Joule:

```bash
# 1. Start Claude Code with the plugin
claude --plugin-dir <path-to-sap-a2a-agent-toolkit>

# 2. Log in to Cloud Foundry
cf login -a https://api.cf.<landscape>.hana.ondemand.com 

# 3. Log in to Joule
joule login
```

## Quick Start

```bash
# 1. Scaffold an agent (TypeScript + Express, default)
/sap-a2a-agent-toolkit:create-agent po-assistant

# 1b. Or scaffold a CAP-based agent
/sap-a2a-agent-toolkit:create-agent po-assistant --framework cap

# 2. Customize tools, then deploy everything
/sap-a2a-agent-toolkit:deploy-agent ./po-assistant
```

Or just describe what you want:

> "Build me a Joule A2A agent in TypeScript using CAP that checks purchase order status from S/4HANA, deploy it to eu10"

Claude will use the skills automatically.

## Architecture

```
User prompt in Joule
        |
        v
+----------------+     A2A (JSON-RPC 2.0)     +----------------------+
|  SAP Joule     | --------------------------> |  Your Agent          |
|  (BTP)         | <-------------------------- |  (Cloud Foundry)     |
+-------+--------+     Protocol v0.3.0         +---------+------------+
        |                                                |
  capability.sapdas.yaml                     LangGraph + Tools
  functions/call_agent.yaml                  SAP GenAI Hub (AI Core)
  BTP Destination                            OrchestrationClient
```

### Framework Options (TypeScript)

| | Express (default) | CAP |
|---|---|---|
| Server | Express + A2AExpressApp | CAP + cds.on("bootstrap") |
| Deploy | `cf push` (manifest.yml) | `mbt build` + `cf deploy` (mta.yaml) |
| Auth | Manual XSUAA setup | Built-in CAP auth |
| Services | Manual bindings | CDS service definitions |
| Best for | Lightweight agents, quick prototyping | Enterprise agents, complex service bindings |

## Supported Stack

- **Framework:** LangGraph (Python) / LangGraph.js (TypeScript) on Express or CAP
- **LLM:** SAP GenAI Hub via `@sap-ai-sdk/langchain` OrchestrationClient
- **Protocol:** A2A v0.3.0 — JSON-RPC 2.0 over HTTPS (`@a2a-js/sdk` 0.3.10)
- **Deployment:** SAP BTP Cloud Foundry (manifest.yml or MTA)
- **Languages:** TypeScript (default), Python
- **Node.js:** 24.x


## Known Issues
<!-- You may simply state "No known issues. -->

## How to obtain support
[Create an issue](https://github.com/SAP-samples/joule-a2a-agent-toolkit/issues) in this repository if you find a bug or have questions about the content.
 
For additional support, [ask a question in SAP Community](https://answers.sap.com/questions/ask.html).

## Contributing
If you wish to contribute code, offer fixes or improvements, please send a pull request. Due to legal reasons, contributors will be asked to accept a DCO when they create the first pull request to this project. This happens in an automated fashion during the submission process. SAP uses [the standard DCO text of the Linux Foundation](https://developercertificate.org/).

## License
Copyright (c) 2026 SAP SE or an SAP affiliate company. All rights reserved. This project is licensed under the Apache Software License, version 2.0 except as noted otherwise in the [LICENSE](LICENSE) file.
