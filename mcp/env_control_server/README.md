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
- Azure CLI/auth prerequisites already used by EnvControl.sh

## Local Run
From workspace root:

```powershell
C:/Users/prasadug/.local/bin/python3.14.exe mcp/env_control_server/server.py
```

## Configurable Environment Variables
- ENVCONTROL_SCRIPT_PATH: override default script path
  - default: int-01/EnvControl.sh
- ENVCONTROL_SHELL: shell executable
  - default: bash
- ENVCONTROL_PROFILE: runtime profile mode
  - values: nonprod (default), production
- ENVCONTROL_SECOND_APPROVAL_TOKEN: active token required in production for stop actions
  - recommendation: store in host secret manager or secure process environment
- ENVCONTROL_SECOND_APPROVAL_PREVIOUS_TOKEN: optional previous token for rotation grace period
- ENVCONTROL_SECOND_APPROVAL_TOKENS: optional comma-separated token allowlist
  - when set, this list is used as the full rotation set and takes precedence

## VS Code MCP Registration (workspace)
Create or update .vscode/mcp.json:

```json
{
  "servers": {
    "env-control-mcp": {
      "type": "stdio",
      "command": "C:/Users/prasadug/.local/bin/python3.14.exe",
      "args": [
        "mcp/env_control_server/server.py"
      ],
      "cwd": "${workspaceFolder}"
    }
  }
}
```

After saving mcp.json, reload VS Code window so tools are discovered.

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
1. Set ENVCONTROL_SECOND_APPROVAL_TOKEN to the new token.
2. Keep the old token temporarily in ENVCONTROL_SECOND_APPROVAL_PREVIOUS_TOKEN.
3. After clients switch to the new token, remove ENVCONTROL_SECOND_APPROVAL_PREVIOUS_TOKEN.

Alternative:
1. Set ENVCONTROL_SECOND_APPROVAL_TOKENS to a comma-separated allowlist during transition.
2. Remove old token entries after cutover.
