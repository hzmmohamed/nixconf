# Test VMs

Dedicated QEMU VMs for testing specific aspects of the configuration.
Each VM is purpose-built — include only what's needed for the test.

## Available VMs

### `desktop-test.nix` → `nixosConfigurations.desktop-vm`

Tests the Sway desktop experience: window manager, waybar, swayidle,
cliphist, gammastep. Auto-logs in via greetd (user: meshmoss, password: test).

```bash
nix build .#nixosConfigurations.desktop-vm.config.system.build.vm
./result/bin/run-desktop-vm-vm
```

## Planned VMs

- **Network test pair** — Two VMs (butternut + maple) for testing Syncthing
  sync, Tailscale VPN, SSH between hosts. Will be added when networking
  features are ready to test.

## Design principles

- **Purpose-built, not monolithic.** Each VM tests one thing. Don't replicate
  an entire host — include only the modules relevant to the test.
- **Fast to build.** Fewer modules means faster `nix build`. A desktop VM
  shouldn't include docker, k8s, music production, or AI services.
- **No real secrets.** Test VMs use `initialPassword` and skip sops/syncthing.
  Network test VMs that need secrets will use test-specific credentials.
- **Auto-login.** Test VMs use greetd with direct session launch, no greeter.
