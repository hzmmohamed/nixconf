# Secrets

Encrypted with [sops-nix](https://github.com/Mic92/sops-nix) using age encryption.

## Age key

The private key must exist at `~/.config/sops/age/keys.txt` (primary user) on each host.
It is NOT stored in this repo.

## Secret files

| File | Keys | Used by |
|------|------|---------|
| `butternut/syncthing.yaml` | `syncthing/key`, `syncthing/cert` | Syncthing service authentication on butternut |
| `butternut/nix-serve.yaml` | `nix-serve-secret-key` | Nix binary cache signing key on butternut |
| `maple/syncthing.yaml` | `syncthing/key`, `syncthing/cert` | Syncthing service authentication on maple |
| `maple/nix-serve.yaml` | `nix-serve-secret-key` | Nix binary cache signing key on maple |
| `hazel/syncthing.yaml` | `syncthing/key`, `syncthing/cert` | Syncthing service authentication on hazel |
| `shared/tailscale.yaml` | `tailscale_authkey` | Tailscale auth key (`tailscale` feature, all hosts) |
| `shared/tailscale-oauth.yaml` | `tailscale_oauth` | Tailscale OAuth client secret (Auth Keys write; tag tag:provisioner only, which owns every host tag) for tagged logins (`preferences.tailscale.oauth.enable`: maple, peacelily, fern). Written by `scripts/fern/tailscale.sh store`; also encrypted for fern. Its ID is imported into OpenTofu (`infra/tailscale/oauth.tf`); a tofu rotation rewrites it via `scripts/tailscale/apply.sh` |
| `admin/tailscale-admin.yaml` | `tailscale_admin_oauth` | Tailnet **admin** OAuth client (Policy File, DNS, Feature/Networking Settings, Devices Core, Auth Keys, OAuth Keys; tag tag:provisioner): the OpenTofu provider credential for `infra/tailscale`. **Primary age key only** (`.sops.yaml` rule `secrets/admin/`), no host keys. Written by `scripts/tailscale/store-admin.sh` (docs/plans/2026-11-17-tailnet-as-code.md). Not created yet |
| `shared/wifi.yaml` | `wifi_env` | Home Wi-Fi PSK for NetworkManager (`wifi-home` feature) |
| `shared/librechat.yaml` | `librechat_creds_key`, `librechat_creds_iv`, `librechat_jwt_secret`, `librechat_jwt_refresh_secret` | LibreChat on peacelily (`ai-server`) |
| `shared/ai-search.yaml` | `searx_secret_key` | SearXNG (`ai-server`). Referenced but not created yet |
| `shared/user.yaml` | `user-hashed-password`, `syncthing-gui-password` | Opt-in (`preferences.user.passwordFromSops`, `preferences.syncthing.guiPasswordFromSops`). Not created yet |
| `atuin.yaml` | `atuin_key` | Atuin shell history sync encryption key |
| `fern/workspace.yaml` | `git-ssh-key`, `remotes` | fern (AWS agent host): read-only GitLab deploy key + clone URLs (`<name> <url>` lines), `workspace-bootstrap`. Encrypted for `primary` + fern's host key (ssh-to-age); fern also needs `shared/tailscale.yaml` (+ `tailscale-oauth.yaml`) re-encrypted for it. Written by `scripts/fern/deploy-key.sh` (docs/plans/2026-11-17-fern-runbook.md). Not created yet |
| `shared/aws-sso.yaml` | `account_id`, `start_url`, `region` | AWS Identity Center client settings: `features/aws.nix` renders the `tfc-*` SSO profiles into `~/.aws/config` (`preferences.aws.sso.enable`: butternut, hazel). Not credentials, but kept out of the public repo. `.sops.yaml` rule: primary only, **never fern** (instance role). Written by `scripts/aws-sso/store-config.sh` (docs/plans/2026-11-17-aws-sso-runbook.md). Not created yet |

## Adding secrets

```bash
# Enter devshell (has sops + age)
nix develop

# Edit existing secrets (decrypts in-place with $EDITOR)
sops secrets/butternut/syncthing.yaml

# Create new secrets file (matched by .sops.yaml creation_rules)
sops secrets/<host>/<name>.yaml

# Verify decryption works
sops -d secrets/butternut/syncthing.yaml
```
