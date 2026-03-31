# Email Notifications & DND Design

## Goal

Background email notifications via IMAP IDLE push, aerc TUI client, and system-wide Do Not Disturb mode. All OAuth2 credentials flow through gnome-keyring.

## Accounts

| Name | Address | Provider | Flavor |
|------|---------|----------|--------|
| personal | hzmmohamed@gmail.com | Google | gmail.com |
| work | h.fahmi@transportforcairo.com | Microsoft | outlook.office365.com |

Both use OAuth2. Thunderbird handles its own tokens natively. All other tools (aerc, imapnotify) use a shared helper script.

## Components

### 1. OAuth2 Token Helper (`email-oauth2`)

A `writeShellScriptBin` wrapper with `curl`, `jq`, `secret-tool`, `xdg-open`, `python3` in PATH.

**Setup mode** (`email-oauth2 setup personal`):
1. Opens browser for OAuth2 authorization using Thunderbird's public client IDs
2. Catches redirect on localhost with a tiny HTTP listener
3. Exchanges auth code for refresh + access tokens
4. Stores refresh token in gnome-keyring via `secret-tool store`

**Token mode** (`email-oauth2 personal`):
1. Reads refresh token from keyring via `secret-tool lookup`
2. POSTs to token endpoint, prints access token to stdout

**Client IDs (Thunderbird public):**
- Google: `903830131492-crpilk15k0n1q5h0c3gl94rcj5co4533.apps.googleusercontent.com`
- Microsoft: `9e5f94bc-e8a4-4e73-b8be-63364c29d753` (tenant: `common`)

**Scopes:**
- Google: `https://mail.google.com/`
- Microsoft: `https://outlook.office365.com/IMAP.AccessAsUser.All https://outlook.office365.com/SMTP.Send offline_access`

### 2. imapnotify (Background Push Notifications)

Per-account systemd user services via home-manager `services.imapnotify`:
- Connects to IMAP with IDLE on INBOX
- `passwordCmd` calls `email-oauth2 <account>`
- `onNotify` runs `notify-send` via mako
- Starts on `graphical-session.target`

### 3. aerc (TUI Mail Client)

- Both accounts enabled with `xoauth2` auth
- `password-command` calls same `email-oauth2 <account>`
- Inherits terminal colors from kitty/foot (no separate theming)
- No darkman integration needed

### 4. DND Mode

**Sway keybinding:** `Mod+n` toggles via `dnd-toggle` script.

**Waybar indicator:** `custom/dnd` module polls mako mode every 2s, shows bell/crossed-bell icon, click toggles.

**Quiet hours:** Two systemd user timers:
- `dnd-on.timer`: `OnCalendar=*-*-* 22:00:00` enables DND
- `dnd-off.timer`: `OnCalendar=*-*-* 08:00:00` disables DND

Manual override always works. Quiet hours set the baseline.

## Module Structure

All declared in `modules/nixos/features/email.nix`. DND waybar module added to `waybar.nix`. DND keybinding added to `sway.nix`.

## First-Time Setup

After `nixos-rebuild switch`:
1. `email-oauth2 setup personal` — authorize Gmail in browser
2. `email-oauth2 setup work` — authorize O365 in browser
3. imapnotify services start automatically, aerc is ready to use
