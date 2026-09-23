# Second-approval secret mounts

Do not commit real tokens. Mount secrets from Vault, CyberArk, or Azure Key Vault CSI.

Expected files (mode `600`):

| File | Purpose |
|------|---------|
| `second_approval_token` | Active production stop token |
| `second_approval_previous_token` | Optional previous token during rotation |
| `second_approval_tokens` | Optional comma- or newline-separated allowlist (takes precedence) |

Override paths with:

- `ENVCONTROL_STOP_APPROVAL_PRIMARY_PATH`
- `ENVCONTROL_STOP_APPROVAL_PREVIOUS_PATH`
- `ENVCONTROL_STOP_APPROVAL_ALLOWLIST_PATH`
