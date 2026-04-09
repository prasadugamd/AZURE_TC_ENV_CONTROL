# Env Control AI Agent Delivery

This repository delivers the environment control tool as a custom GitHub Copilot agent.

## Included Agent
- `env-control.agent.md`
  - Name: Env Control Agent
  - Purpose: Operate and troubleshoot Azure INT environment control workflows.

## How To Use In VS Code
1. Open this repository in VS Code.
2. Open Copilot Chat.
3. Select **Env Control Agent** from the agent picker.
4. Give a task with environment + action + intent.

## Example Prompts
- `Run status flow for int-01 and summarize unhealthy components.`
- `Debug why stop action fails for int-01 consul nodes.`
- `Refresh config files for int-01 and validate VM/PG/CDH detection.`
- `Review EnvControl.sh start flow and patch idempotency issues.`

## Recommended Input Format
`<env-code> | <action: status/start/stop> | <goal: run/debug/fix/refactor>`

Example:
`int-01 | status | debug`

## Team Delivery Checklist
- Keep agent file in `.github/agents/` so it is shared with the repo.
- Avoid hardcoding secrets in scripts or chat messages.
- Validate changes with small, safe checks before full start/stop runs.
- Commit both agent and docs to enable onboarding for other users.

## Host Prerequisites (per machine, not committed to repo)

### Azure CLI auth
```bash
# Fill in real values in int-01/Auth/set_az.sh then:
cd int-01/Auth && . set_az.sh
```

### kubeconfig (optional — only needed for local kubectl)
`.kube/` is excluded from the repo (contains cluster tokens — security risk).
Run once per host after Azure login:
```bash
az aks get-credentials \
  --resource-group <AKS_RESOURCE_GROUP> \
  --name <AKS_CLUSTER_NAME> \
  --overwrite-existing
```
Without this, EnvControl.sh automatically falls back to SSH-based kubectl on the K8s management node.

### MCP server Python dependency
```bash
pip install -r mcp/env_control_server/requirements.txt
```
