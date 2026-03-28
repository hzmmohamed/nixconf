# Secrets

Encrypted with [sops-nix](https://github.com/Mic92/sops-nix) using age encryption.

## Age key

The private key must exist at `/home/meshmoss/.config/sops/age/keys.txt` on each host.
It is NOT stored in this repo.

## Secret files

| File | Keys | Used by |
|------|------|---------|
| `butternut/syncthing.yaml` | `syncthing/key`, `syncthing/cert` | Syncthing service authentication on butternut |
| `butternut/nix-serve.yaml` | `nix-serve-secret-key` | Nix binary cache signing key on butternut |
| `maple/syncthing.yaml` | `syncthing/key`, `syncthing/cert` | Syncthing service authentication on maple |
| `maple/nix-serve.yaml` | `nix-serve-secret-key` | Nix binary cache signing key on maple |
| `atuin.yaml` | `atuin_key` | Atuin shell history sync encryption key |

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
