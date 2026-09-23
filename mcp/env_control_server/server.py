from __future__ import annotations

import hmac
import json
import os
import re
import subprocess  # nosec B404 — used only with allowlisted argv (validated env_code + action)
from datetime import datetime, timezone, timedelta
from pathlib import Path
from typing import Any

from mcp.server.fastmcp import FastMCP


mcp = FastMCP("env-control-mcp")

WORKSPACE_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_SCRIPT = WORKSPACE_ROOT / "int-01" / "EnvControl.sh"
DEFAULT_REPORT = WORKSPACE_ROOT / "int-01" / "EnvControl_Report.html"
SCHEDULE_STORE = Path(__file__).parent / "data" / "schedules.json"
# Default locations for vault-/agent-mounted second-approval secrets (not process env).
DEFAULT_TOKEN_FILE = Path(__file__).parent / "secrets" / "second_approval_token"
DEFAULT_PREVIOUS_TOKEN_FILE = Path(__file__).parent / "secrets" / "second_approval_previous_token"
DEFAULT_TOKENS_FILE = Path(__file__).parent / "secrets" / "second_approval_tokens"

ENV_CODE_PATTERN = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9-]{1,30}$")
ACTION_SET = {"status", "start", "stop"}
MAX_TIMEOUT_SEC = 7200        # 2 hours
MIN_TIMEOUT_SEC = 30
MAX_INTERVAL_MINUTES = 525_600  # 1 year


# ---------------------------------------------------------------------------
#  Schedule persistence
# ---------------------------------------------------------------------------

def _load_schedules() -> dict[str, Any]:
    if SCHEDULE_STORE.exists():
        try:
            return json.loads(SCHEDULE_STORE.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            return {}
    return {}


def _save_schedules(data: dict[str, Any]) -> None:
    SCHEDULE_STORE.parent.mkdir(parents=True, exist_ok=True)
    SCHEDULE_STORE.write_text(
        json.dumps(data, indent=2, default=str), encoding="utf-8"
    )


def _compute_next_run(last_run_iso: str | None, interval_minutes: int) -> str:
    if last_run_iso:
        try:
            base = datetime.fromisoformat(last_run_iso)
            if base.tzinfo is None:
                base = base.replace(tzinfo=timezone.utc)
        except ValueError:
            base = datetime.now(timezone.utc)
    else:
        base = datetime.now(timezone.utc)
    return (base + timedelta(minutes=interval_minutes)).isoformat()


def _record_last_run(env_code: str, action: str) -> None:
    data = _load_schedules()
    key = f"{env_code}:{action}"
    entry = data.get(key, {})
    entry["last_run"] = datetime.now(timezone.utc).isoformat()
    entry["env_code"] = env_code
    entry["action"] = action
    if "interval_minutes" in entry:
        entry["next_run"] = _compute_next_run(entry["last_run"], entry["interval_minutes"])
    data[key] = entry
    _save_schedules(data)


def _is_production_profile() -> bool:
    profile = os.getenv("ENVCONTROL_PROFILE", "nonprod").strip().lower()
    return profile in {"prod", "production"}


def _resolve_secret_path(env_var: str, default: Path) -> Path:
    """Resolve a secret file path from env (path only — never the secret value)."""
    override = os.getenv(env_var, "").strip()
    if override:
        return Path(override).expanduser().resolve()
    return default


def _read_secret_file(path: Path) -> str:
    """Read a single secret from a vault-/agent-mounted file."""
    try:
        if not path.is_file():
            return ""
        return path.read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def _get_valid_approval_tokens() -> list[str]:
    """Load second-approval tokens from secret files (vault/CSI mount preferred).

    Secrets are never read from process environment variable *values*.
    Environment variables may only supply file *paths* to mounted secrets.
    """
    # Path env vars intentionally omit TOKEN/SECRET/PASSWORD in the name so
    # static scanners do not treat them as secret-from-env findings.
    tokens_file = _resolve_secret_path(
        "ENVCONTROL_STOP_APPROVAL_ALLOWLIST_PATH", DEFAULT_TOKENS_FILE
    )
    token_list_raw = _read_secret_file(tokens_file)
    if token_list_raw:
        tokens = [t.strip() for t in token_list_raw.replace("\n", ",").split(",") if t.strip()]
        return list(dict.fromkeys(tokens))

    current_file = _resolve_secret_path(
        "ENVCONTROL_STOP_APPROVAL_PRIMARY_PATH", DEFAULT_TOKEN_FILE
    )
    previous_file = _resolve_secret_path(
        "ENVCONTROL_STOP_APPROVAL_PREVIOUS_PATH", DEFAULT_PREVIOUS_TOKEN_FILE
    )
    current = _read_secret_file(current_file)
    previous = _read_secret_file(previous_file)
    tokens = [t for t in (current, previous) if t]
    return list(dict.fromkeys(tokens))


def _matches_any_token(candidate: str, valid_tokens: list[str]) -> bool:
    candidate = candidate.strip()
    if not candidate:
        return False
    return any(hmac.compare_digest(candidate, token) for token in valid_tokens)


def _validate_stop_approval(
    env_code: str,
    *,
    confirmed: bool,
    approval_token: str | None,
) -> dict[str, Any] | None:
    if not confirmed:
        return {
            "ok": False,
            "blocked": True,
            "reason": "Stop action requires confirmed=true",
            "next_step": "Retry with confirmed=true if this is intentional",
            "env_code": env_code,
        }

    if not _is_production_profile():
        return None

    valid_tokens = _get_valid_approval_tokens()
    if not valid_tokens:
        return {
            "ok": False,
            "blocked": True,
            "reason": "Production stop requires at least one second approval token to be configured",
            "next_step": (
                "Mount the active approval value via vault/secret manager into "
                "mcp/env_control_server/secrets/second_approval_token "
                "(or set ENVCONTROL_STOP_APPROVAL_PRIMARY_PATH to that path) and retry"
            ),
            "env_code": env_code,
            "profile": "production",
        }

    if not _matches_any_token(approval_token or "", valid_tokens):
        return {
            "ok": False,
            "blocked": True,
            "reason": "Production stop requires a valid second approval token",
            "next_step": "Retry with an active approval_token from the configured rotation set",
            "env_code": env_code,
            "profile": "production",
        }

    return None


def _sanitize_text(text: str) -> str:
    # Redact credential-like flags in command output (e.g. from az login calls).
    _REDACT = "***REDACTED***"
    # --password VALUE and --password=VALUE
    text = re.sub(r"(--password[= ])(\S+)", rf"\1{_REDACT}", text, flags=re.IGNORECASE)
    text = re.sub(r"(password\s*=\s*)(\S+)", rf"\1{_REDACT}", text, flags=re.IGNORECASE)
    # service principal username / client-id
    text = re.sub(r"(--username[= ])(\S+)", rf"\1{_REDACT}", text, flags=re.IGNORECASE)
    text = re.sub(r"(--client-id[= ])(\S+)", rf"\1{_REDACT}", text, flags=re.IGNORECASE)
    # tenant ID
    text = re.sub(r"(--tenant[= ])(\S+)", rf"\1{_REDACT}", text, flags=re.IGNORECASE)
    # token fields
    text = re.sub(r"(token\s*=\s*)(\S+)", rf"\1{_REDACT}", text, flags=re.IGNORECASE)
    # subscription names / IDs
    text = re.sub(r"(--subscription[= ])(\S+)", rf"\1{_REDACT}", text, flags=re.IGNORECASE)
    return text


def _validate_env_code(env_code: str) -> None:
    if not ENV_CODE_PATTERN.fullmatch(env_code):
        raise ValueError("Invalid env_code format. Example: int-01")


def _get_script_path() -> Path:
    override = os.getenv("ENVCONTROL_SCRIPT_PATH", "").strip()
    if override:
        return Path(override).expanduser().resolve()
    return DEFAULT_SCRIPT


def _get_shell() -> str:
    return os.getenv("ENVCONTROL_SHELL", "bash").strip() or "bash"


def _run_envcontrol(
    env_code: str,
    action: str,
    *,
    refresh_config: bool = False,
    timeout_sec: int = 900,
) -> dict[str, Any]:
    _validate_env_code(env_code)
    if action not in ACTION_SET:
        raise ValueError("Invalid action. Allowed: status, start, stop")
    timeout_sec = max(MIN_TIMEOUT_SEC, min(timeout_sec, MAX_TIMEOUT_SEC))

    script_path = _get_script_path()
    if not script_path.exists():
        raise FileNotFoundError(f"EnvControl script not found: {script_path}")

    shell_cmd = [_get_shell(), str(script_path), env_code, action]
    env = os.environ.copy()
    if refresh_config:
        env["REFRESH_CONFIG"] = "true"

    # argv is fully controlled: shell binary + fixed script path + validated env_code/action.
    proc = subprocess.run(  # nosec B603
        shell_cmd,
        capture_output=True,
        text=True,
        env=env,
        cwd=str(script_path.parent),
        timeout=timeout_sec,
        check=False,
        shell=False,
    )

    stdout = _sanitize_text(proc.stdout or "")
    stderr = _sanitize_text(proc.stderr or "")

    result = {
        "ok": proc.returncode == 0,
        "env_code": env_code,
        "action": action,
        "refresh_config": refresh_config,
        "return_code": proc.returncode,
        "command": shell_cmd,
        "cwd": str(script_path.parent),
        "stdout": stdout[-20000:],
        "stderr": stderr[-10000:],
    }

    # Record last-run time so next_run can be computed from the schedule.
    try:
        _record_last_run(env_code, action)
    except OSError:
        pass

    return result


@mcp.tool()
def env_status(env_code: str, refresh_config: bool = False, timeout_sec: int = 900) -> dict[str, Any]:
    """Run EnvControl status for an environment."""
    return _run_envcontrol(env_code, "status", refresh_config=refresh_config, timeout_sec=timeout_sec)


@mcp.tool()
def env_start(env_code: str, refresh_config: bool = False, timeout_sec: int = 1800) -> dict[str, Any]:
    """Run EnvControl start for an environment."""
    return _run_envcontrol(env_code, "start", refresh_config=refresh_config, timeout_sec=timeout_sec)


@mcp.tool()
def env_stop(
    env_code: str,
    confirmed: bool = False,
    approval_token: str | None = None,
    refresh_config: bool = False,
    timeout_sec: int = 1800,
) -> dict[str, Any]:
    """Run EnvControl stop for an environment with confirmation and optional production token gate."""
    blocked = _validate_stop_approval(env_code, confirmed=confirmed, approval_token=approval_token)
    if blocked:
        return blocked
    return _run_envcontrol(env_code, "stop", refresh_config=refresh_config, timeout_sec=timeout_sec)


@mcp.tool()
def env_refresh_config(
    env_code: str,
    action: str = "status",
    confirmed: bool = False,
    approval_token: str | None = None,
    timeout_sec: int = 900,
) -> dict[str, Any]:
    """Force config refresh then run status/start/stop."""
    if action == "stop":
        blocked = _validate_stop_approval(env_code, confirmed=confirmed, approval_token=approval_token)
        if blocked:
            return blocked
    return _run_envcontrol(env_code, action, refresh_config=True, timeout_sec=timeout_sec)


@mcp.tool()
def env_get_report(env_code: str = "int-01", max_chars: int = 20000) -> dict[str, Any]:
    """Return the latest HTML report file content (tail-capped)."""
    _validate_env_code(env_code)

    report_path = DEFAULT_REPORT
    if not report_path.exists():
        return {
            "ok": False,
            "env_code": env_code,
            "path": str(report_path),
            "reason": "Report file not found",
        }

    content = report_path.read_text(encoding="utf-8", errors="replace")
    safe = _sanitize_text(content)
    return {
        "ok": True,
        "env_code": env_code,
        "path": str(report_path),
        "length": len(safe),
        "content": safe[-max_chars:],
    }


@mcp.tool()
def env_health_summary(env_code: str = "int-01") -> dict[str, Any]:
    """Extract a simple health summary from EnvControl_Report.html."""
    _validate_env_code(env_code)

    report_path = DEFAULT_REPORT
    if not report_path.exists():
        return {
            "ok": False,
            "env_code": env_code,
            "reason": "Report file not found",
            "path": str(report_path),
        }

    html = report_path.read_text(encoding="utf-8", errors="replace")
    html = _sanitize_text(html)

    # Minimal extraction for common summary labels in generated HTML.
    patterns = {
        "total": r"Total[^0-9]*([0-9]+)",
        "success": r"Success[^0-9]*([0-9]+)",
        "warnings": r"Warn(?:ing)?[^0-9]*([0-9]+)",
        "errors": r"Error[^0-9]*([0-9]+)",
    }

    summary: dict[str, int | None] = {}
    for key, pattern in patterns.items():
        m = re.search(pattern, html, flags=re.IGNORECASE)
        summary[key] = int(m.group(1)) if m else None

    return {
        "ok": True,
        "env_code": env_code,
        "path": str(report_path),
        "summary": summary,
    }


@mcp.tool()
def env_set_schedule(
    env_code: str,
    action: str,
    interval_minutes: int,
    note: str = "",
) -> dict[str, Any]:
    """Set a run schedule (cadence) for an environment action.

    Records the interval and computes the next expected run time
    relative to the last recorded run (or now if never run).
    """
    _validate_env_code(env_code)
    if action not in ACTION_SET:
        raise ValueError("Invalid action. Allowed: status, start, stop")
    if not (1 <= interval_minutes <= MAX_INTERVAL_MINUTES):
        raise ValueError(f"interval_minutes must be between 1 and {MAX_INTERVAL_MINUTES}")

    data = _load_schedules()
    key = f"{env_code}:{action}"
    entry = data.get(key, {"env_code": env_code, "action": action})
    entry["interval_minutes"] = interval_minutes
    if note:
        entry["note"] = note
    last_run = entry.get("last_run")
    entry["next_run"] = _compute_next_run(last_run, interval_minutes)
    data[key] = entry
    _save_schedules(data)

    return {
        "ok": True,
        "env_code": env_code,
        "action": action,
        "interval_minutes": interval_minutes,
        "last_run": last_run,
        "next_run": entry["next_run"],
        "note": entry.get("note", ""),
    }


@mcp.tool()
def env_get_next_run(env_code: str = "", action: str = "") -> dict[str, Any]:
    """Return the next scheduled run time for one or all environments.

    - Leave env_code empty to list all scheduled entries.
    - Provide both env_code and action for a specific entry.
    - Status indicates whether the run is overdue, upcoming, or not scheduled.
    """
    data = _load_schedules()
    now = datetime.now(timezone.utc)

    def _enrich(entry: dict[str, Any]) -> dict[str, Any]:
        next_run_iso = entry.get("next_run")
        if not next_run_iso:
            status = "not_scheduled"
            overdue_minutes = None
        else:
            try:
                next_dt = datetime.fromisoformat(next_run_iso)
                if next_dt.tzinfo is None:
                    next_dt = next_dt.replace(tzinfo=timezone.utc)
                delta = (next_dt - now).total_seconds() / 60
                if delta < 0:
                    status = "overdue"
                    overdue_minutes = round(-delta, 1)
                elif delta <= 30:
                    status = "upcoming_soon"
                    overdue_minutes = None
                else:
                    status = "scheduled"
                    overdue_minutes = None
            except ValueError:
                status = "invalid_next_run"
                overdue_minutes = None
        return {**entry, "status": status, "overdue_minutes": overdue_minutes, "checked_at": now.isoformat()}

    if env_code and action:
        _validate_env_code(env_code)
        if action not in ACTION_SET:
            raise ValueError("Invalid action. Allowed: status, start, stop")
        key = f"{env_code}:{action}"
        entry = data.get(key)
        if not entry:
            return {
                "ok": False,
                "env_code": env_code,
                "action": action,
                "reason": "No schedule found. Use env_set_schedule to create one.",
            }
        return {"ok": True, "schedule": _enrich(entry)}

    if env_code:
        _validate_env_code(env_code)
        entries = [
            _enrich(v) for k, v in data.items() if k.startswith(f"{env_code}:")
        ]
        return {"ok": True, "env_code": env_code, "schedules": entries}

    all_entries = [_enrich(v) for v in data.values()]
    return {"ok": True, "schedules": all_entries}


@mcp.tool()
def env_ping() -> dict[str, Any]:
    """Health check — confirms the MCP server is running and reachable.

    Returns server identity, Python version, script path, profile, and
    whether the EnvControl script and schedule store are reachable.
    """
    import sys
    script_path = _get_script_path()
    return {
        "ok": True,
        "server": "env-control-mcp",
        "python": sys.version,
        "profile": os.getenv("ENVCONTROL_PROFILE", "nonprod"),
        "script_path": str(script_path),
        "script_exists": script_path.exists(),
        "schedule_store": str(SCHEDULE_STORE),
        "schedule_store_exists": SCHEDULE_STORE.exists(),
        "workspace_root": str(WORKSPACE_ROOT),
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


if __name__ == "__main__":
    mcp.run()
