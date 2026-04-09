# Copilot Workspace Instructions — AZ INT ENV CONTROL

These rules apply to all Copilot interactions in this repository.

## Identity and Scope
This repository manages Azure INT environment lifecycle automation via `EnvControl.sh`.
All code changes, suggestions, and operations are scoped to environment control workflows only.

## Tool Priority
- Always prefer MCP tools (`env_ping`, `env_status`, `env_start`, `env_stop`, `env_refresh_config`, `env_get_report`, `env_health_summary`, `env_set_schedule`, `env_get_next_run`) for operational actions.
- Fall back to reading scripts and config files only when diagnosing code-level issues.

## Credential and Secret Rules
- Never output, suggest, or echo real credentials, passwords, tokens, client IDs, tenant IDs, or subscription IDs.
- `int-01/Auth/set_az.sh` must always contain placeholder values — never real values.
- If a secret is detected in any file, flag it immediately and suggest replacing with an environment variable.

## Stop Action Safety
- Never invoke `env_stop` or `env_refresh_config` with `action=stop` without first confirming intent with the user.
- In production profile (`ENVCONTROL_PROFILE=production`), always remind the user that a second approval token is required.

## Code Change Rules
- Make minimal, targeted changes — no refactors, no added comments, no style changes unless asked.
- Always compile-check Python files after editing: `python3.14 -m py_compile <file>`.
- Preserve idempotent start/stop behavior in `EnvControl.sh`.

## Output Format
- For operational results, always include: what ran, return code, and any warnings or errors from output.
- For code changes, always include: what changed, why, and validation result.
- Never expose raw subprocess output that may contain credential-like strings.
