# Unified Catppuccin Theming with Darkman

## Goal

Standardize all desktop apps on Catppuccin (Latte for light, Mocha for dark) and wire darkman to switch between them automatically by time with a manual override keybinding.

## Current State

| App | Current Theme | Problem |
|-----|---------------|---------|
| GTK | Gruvbox Dark (Green) | Wrong theme family |
| Waybar | Catppuccin Latte (hardcoded) | No dark mode |
| VSCodium | Catppuccin Latte (hardcoded) | No dark mode |
| Kitty | Gruvbox Dark (via `self.theme`) | Wrong theme family |
| Zellij | None | Unthemed |
| Wofi | None (old config had Catppuccin CSS) | Unthemed |
| Darkman | Not present | Was in old config |

## Design

### 1. Add catppuccin/nix flake input

Add `catppuccin.url = "github:catppuccin/nix"` to `flake.nix` and import both `catppuccin.nixosModules.catppuccin` and `catppuccin.homeModules.catppuccin` in the host configs (butternut, desktop-vm).

### 2. Set global Catppuccin flavor

In the host config or a shared module, set:

```nix
catppuccin.flavor = "latte";  # default to light
catppuccin.enable = true;
```

This auto-themes supported apps: kitty, zellij, gtk (via catppuccin GTK theme).

### 3. Create `modules/nixos/features/darkman.nix`

Uses Home Manager's `services.darkman` module:

```nix
home-manager.users.${user}.services.darkman = {
  enable = true;
  settings = {
    usegeoclue = false;
    lat = <lat>;
    lng = <lng>;
  };
  darkModeScripts = { ... };
  lightModeScripts = { ... };
};
```

### 4. Darkman transition scripts

**Light mode (`latte`):**

| App | Script Action |
|-----|---------------|
| GTK | `dconf write /org/gnome/desktop/interface/color-scheme "'prefer-light'"` |
| VSCodium | `sed` colorTheme to "Catppuccin Latte" in settings.json |
| Kitty | `kitten themes --reload-in=all "Catppuccin Latte"` |
| Waybar | Swap CSS symlink to latte variant, `killall -SIGUSR2 waybar` |
| Wofi | Swap CSS symlink to latte variant |
| Zellij | No live reload available; new sessions pick up the change |

**Dark mode (`mocha`):** Same actions but with Mocha variants.

### 5. Per-app changes

**`gtk.nix`** — Replace Gruvbox theme with Catppuccin GTK theme. Remove hardcoded `color-scheme` from dconf (darkman manages this). Install both light and dark Catppuccin GTK themes.

**`waybar.nix`** — Generate both Latte and Mocha CSS files at build time. Waybar config references `catppuccin-colors.css` (a symlink). Darkman flips the symlink. Uses `self.catppuccin` for build-time color values but generates both variants.

**`vscode.nix`** — Keep Catppuccin extensions. Default theme to Latte. Darkman's sed script handles runtime switching.

**`kitty.nix`** — Remove all Gruvbox color settings. Use `kitten themes` for runtime switching (built-in Catppuccin support). Set initial theme to Catppuccin Latte.

**`zellij.nix`** — Add Catppuccin theme configuration. The catppuccin nix module can handle this if `catppuccin.zellij.enable = true`.

**Wofi** — Add Catppuccin Latte and Mocha CSS files (from old config or catppuccin/wofi upstream). Darkman swaps a symlink.

**`theme.nix`** — Keep both Catppuccin Latte and Mocha palettes for modules that need build-time color references (like waybar CSS generation). Remove the Gruvbox palette.

### 6. Manual toggle keybinding

Add a sway keybinding (e.g. `Mod4+Shift+t`) that runs `darkman toggle` for manual override.

### 7. Module dependency

```
butternut/configuration.nix
  imports:
    self.nixosModules.darkman   (NEW - replaces separate theme switching)
    self.nixosModules.sway
    self.nixosModules.clipse
    self.nixosModules.gammastep  (stays - blue light only)
    self.nixosModules.waybar
    ...
```

## Implementation Order

1. Add catppuccin flake input + import modules
2. Create `darkman.nix` module with HM service
3. Update `gtk.nix` — Gruvbox to Catppuccin
4. Update `kitty.nix` — Gruvbox to Catppuccin
5. Update `waybar.nix` — generate both Latte/Mocha CSS
6. Add wofi Catppuccin CSS
7. Update `zellij.nix` — add catppuccin theme
8. Update `vscode.nix` — wire darkman sed script
9. Update `theme.nix` — remove Gruvbox, add Mocha palette
10. Add manual toggle keybinding to sway
11. Test light/dark switching
