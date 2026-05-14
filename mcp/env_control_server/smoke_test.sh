#!/usr/bin/env bash
set -euo pipefail

# Activate venv if present
if [ -f ".venv/bin/activate" ]; then
  source .venv/bin/activate
fi

# Compile check
python3 -m py_compile mcp/env_control_server/server.py

# Import check
out=$(python3 -c "import importlib.util; spec = importlib.util.spec_from_file_location('env_control_server', 'mcp/env_control_server/server.py'); module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module); print(module.mcp.name)")

if [ "$out" = "env-control-mcp" ]; then
  echo "MCP Python server: OK"
else
  echo "MCP Python server: FAIL ($out)" >&2
  exit 1
fi
