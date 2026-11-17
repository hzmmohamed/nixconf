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
| `shared/wifi.yaml` | `wifi_env` | Home Wi-Fi PSK for NetworkManager (`wifi-home` feature) |
| `shared/librechat.yaml` | `librechat_creds_key`, `librechat_creds_iv`, `librechat_jwt_secret`, `librechat_jwt_refresh_secret` | LibreChat on peacelily (`ai-server`) |
| `shared/ai-search.yaml` | `searx_secret_key` | SearXNG (`ai-server`). Referenced but not created yet |
| `shared/user.yaml` | `user-hashed-password`, `syncthing-gui-password` | Opt-in (`preferences.user.passwordFromSops`, `preferences.syncthing.guiPasswordFromSops`). Not created yet |
| `atuin.yaml` | `atuin_key` | Atuin shell history sync encryption key |
| `fern/workspace.yaml` | `git-ssh-key`, `remotes` | fern (AWS agent host): read-only GitLab deploy key + clone URLs (`<name> <url>` lines), `workspace-bootstrap`. Encrypted for `primary` + fern's host key (ssh-to-age); fern also needs `shared/tailscale.yaml` (+ `tailscale-oauth.yaml`) re-encrypted for it. See docs/plans/2026-11-17-aws-agent-host.md. Not created yet |

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
