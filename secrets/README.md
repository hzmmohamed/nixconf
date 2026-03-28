# Secrets

Encrypted with [sops-nix](https://github.com/Mic92/sops-nix) using age encryption.

## Age key

The private key must exist at `/home/meshmoss/.config/sops/age/keys.txt` on each host.
It is NOT stored in this repo.

## Secret files

| File | Keys | Used by |
|------|------|---------|
| `butternut/syncthing.yaml` | `syncthing/key`, `syncthing/cert` | Syncthing service authentication on butternut |

## Adding secrets

```bash
# Edit existing secrets (decrypts in-place with $EDITOR)
sops secrets/butternut/syncthing.yaml

# Create new secrets file (matched by .sops.yaml creation_rules)
sops secrets/<host>/<name>.yaml
```
