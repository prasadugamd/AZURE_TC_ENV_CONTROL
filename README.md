# AZURE_TC_ENV_CONTROL — Linux MCP Quickstart

This repository manages Azure INT environment lifecycle automation via EnvControl.sh and exposes it as MCP tools.

## Linux Quickstart

### 1. Clone and enter the repo
```bash
git clone <repo-url>
cd AZURE_TC_ENV_CONTROL
```

### 2. Create and activate a Python virtual environment
```bash
python3 -m venv .venv
source .venv/bin/activate
python3 -m pip install --upgrade pip
python3 -m pip install -r mcp/env_control_server/requirements.txt
```

### 3. Run the MCP server (local test)
```bash
python3 mcp/env_control_server/server.py
```

### 4. (Optional) Run the Linux smoke test
```bash
bash mcp/env_control_server/smoke_test.sh
```

### 5. MCP in VS Code / Cursor
- Open this repo in VS Code or Cursor.
- MCP JSON is shipped at the repo root as [`mcp.json`](mcp.json) (also mirrored at `.vscode/mcp.json`).
- Reload the window so MCP tools are discovered.

## Requirements
- Python 3.10 or newer (tested with Python 3.10+)
- bash
- Azure CLI (`az`)
- ssh
- kubectl (optional)

## MCP JSON
Root [`mcp.json`](mcp.json) wires the stdio MCP server:

```json
{
  "servers": {
    "env-control-mcp": {
      "type": "stdio",
      "command": "python3",
      "args": ["mcp/env_control_server/server.py"],
      "cwd": "${workspaceFolder}"
    }
  }
}
```

Dependencies: [`mcp/env_control_server/requirements.txt`](mcp/env_control_server/requirements.txt)

## Security
- Never commit real credentials or tokens.
- All generated configs and kubeconfig are ignored by .gitignore.

See mcp/env_control_server/README.md for full details.
