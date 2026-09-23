# Env Control MCP Server

This package exposes your existing environment control script as MCP tools.

## Tools Exposed
- env_status
- env_start
- env_stop
- env_refresh_config
- env_get_report
- env_health_summary

## Runtime Requirements
- Python 3.10+
- mcp package
- Access to shell runtime for EnvControl.sh (bash)
- Azure CLI authenticated (see Auth Setup below)
- kubectl (optional — only needed for local K8s deployment scaling)

## Linux Setup
From the workspace root on a Linux host:

```bash
python3 -m venv .venv
source .venv/bin/activate
python3 -m pip install --upgrade pip
python3 -m pip install -r mcp/env_control_server/requirements.txt
```

Ensure these commands resolve in `PATH` before running the server:
- `bash`
- `az`
- `ssh`
- `kubectl` (optional)

Linux compatibility note:
- The MCP SDK dependency is Linux-compatible.
- Its `pywin32` dependency is only installed on Windows via a platform marker and is not required on Linux.

## Auth Setup (required on each new host)

### 1. Azure CLI login
Update `int-01/Auth/set_az.sh` with real values (do NOT commit them), then source it:
```bash
cd int-01/Auth && . set_az.sh
```

### 2. Kubeconfig for kubectl (optional)
`.kube/` is excluded from the repo because it contains cluster tokens.
Generate it on each host after Azure login:
```bash
az aks get-credentials \
  --resource-group <AKS_RESOURCE_GROUP> \
  --name <AKS_CLUSTER_NAME> \
  --overwrite-existing
```
This creates `~/.kube/config` (or `int-01/Auth/.kube/config` if KUBECONFIG is set).
If kubectl is not available locally, EnvControl.sh falls back to SSH on the K8s management node automatically.

## Local Run
From workspace root:

```bash
source .venv/bin/activate
python3 mcp/env_control_server/server.py
```

## Linux Smoke Test
Use these commands on Linux to verify the Python side before wiring MCP in VS Code:

```bash
source .venv/bin/activate
python3 -m py_compile mcp/env_control_server/server.py
python3 -c "import importlib.util; spec = importlib.util.spec_from_file_location('env_control_server', 'mcp/env_control_server/server.py'); module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module); print(module.mcp.name)"
```

Expected result:
- No output from `py_compile`
- `env-control-mcp` printed by the import check

## Configurable Environment Variables
- ENVCONTROL_SCRIPT_PATH: override default script path
  - default: int-01/EnvControl.sh
- ENVCONTROL_SHELL: shell executable
  - default: bash
- ENVCONTROL_DNS_SUFFIX: DNS suffix used when building internal host FQDNs
  - example: env.example.internal
- ENVCONTROL_PROFILE: runtime profile mode
  - values: nonprod (default), production
- ENVCONTROL_STOP_APPROVAL_PRIMARY_PATH: path to the active second-approval token file
  - default: mcp/env_control_server/secrets/second_approval_token
  - mount this file from Vault/CyberArk/Azure Key Vault CSI (do not put the token in env vars)
- ENVCONTROL_STOP_APPROVAL_PREVIOUS_PATH: path to previous token file (rotation grace)
  - default: mcp/env_control_server/secrets/second_approval_previous_token
- ENVCONTROL_STOP_APPROVAL_ALLOWLIST_PATH: path to comma- or newline-separated allowlist file
  - default: mcp/env_control_server/secrets/second_approval_tokens
  - when present and non-empty, this list is the full rotation set and takes precedence

## VS Code MCP Registration (workspace)
Create or update .vscode/mcp.json:

```json
{
  "servers": {
    "env-control-mcp": {
      "type": "stdio",
      "command": "python3",
      "args": [
        "mcp/env_control_server/server.py"
      ],
      "cwd": "${workspaceFolder}"
    }
  }
}
```

After saving mcp.json, reload VS Code window so tools are discovered.

## Linux Notes
- Keep using forward-slash paths exactly as shown in this README.
- If you set `ENVCONTROL_SCRIPT_PATH`, use the Linux path to `int-01/EnvControl.sh`.
- If your Linux host does not have local kubeconfig, the shell flow can still fall back to SSH on the K8s management node.

## Safety Notes
- env_stop requires confirmed=true.
- In production profile, stop requires both:
  - confirmed=true
  - approval_token matching any active token in the configured rotation set
- The same production stop gate is enforced when using env_refresh_config with action=stop.
- Basic output redaction masks password/token-like values.
- Commands are allowlisted to status/start/stop only.

## Production Stop Example
```json
{
  "env_code": "int-01",
  "confirmed": true,
  "approval_token": "<second-approval-token>",
  "refresh_config": false,
  "timeout_sec": 1800
}
```

## Token Rotation Flow
1. Write the new token into `mcp/env_control_server/secrets/second_approval_token`
   (or the path in `ENVCONTROL_STOP_APPROVAL_PRIMARY_PATH`) via your secret manager mount.
2. Keep the old token temporarily in `secrets/second_approval_previous_token`.
3. After clients switch to the new token, remove the previous-token file.

Alternative:
1. Write a comma- or newline-separated allowlist to `secrets/second_approval_tokens`.
2. Remove old token entries after cutover.

Example (local non-prod only — prefer vault mounts in production):
```bash
mkdir -p mcp/env_control_server/secrets
umask 077
printf '%s' 'active-token-value' > mcp/env_control_server/secrets/second_approval_token
chmod 600 mcp/env_control_server/secrets/second_approval_token
```
