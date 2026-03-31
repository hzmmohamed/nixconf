# Email Notifications & DND Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add background email notifications (imapnotify), aerc TUI client, OAuth2 token helper, and system-wide DND with quiet hours.

**Architecture:** All email components live in `email.nix`. The `email-oauth2` script is the shared credential provider for aerc and imapnotify. DND integrates mako, waybar, sway, and systemd timers across their respective modules.

**Tech Stack:** NixOS, home-manager, goimapnotify, aerc, gnome-keyring/secret-tool, mako, waybar, systemd timers.

---

### Task 1: Create OAuth2 Token Helper Script

**Files:**
- Modify: `modules/nixos/features/email.nix`

**Step 1: Add the `email-oauth2` script to email.nix**

Add a `let` binding for the script and include it in `environment.systemPackages`. The script handles two modes: `setup <account>` (browser auth flow) and `<account>` (return access token).

```nix
# Inside the let block, after `user = ...`:
emailOauth2 = pkgs.writeShellScriptBin "email-oauth2" ''
  set -euo pipefail
  export PATH="${pkgs.lib.makeBinPath [
    pkgs.curl
    pkgs.jq
    pkgs.gnome-keyring
    pkgs.xdg-utils
    pkgs.python3
  ]}:$PATH"

  # Provider configs
  GOOGLE_CLIENT_ID="903830131492-crpilk15k0n1q5h0c3gl94rcj5co4533.apps.googleusercontent.com"
  GOOGLE_CLIENT_SECRET=""
  GOOGLE_AUTH_URL="https://accounts.google.com/o/oauth2/v2/auth"
  GOOGLE_TOKEN_URL="https://oauth2.googleapis.com/token"
  GOOGLE_SCOPE="https://mail.google.com/"
  GOOGLE_REDIRECT_URI="http://localhost:8089"

  MS_CLIENT_ID="9e5f94bc-e8a4-4e73-b8be-63364c29d753"
  MS_AUTH_URL="https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
  MS_TOKEN_URL="https://login.microsoftonline.com/common/oauth2/v2.0/token"
  MS_SCOPE="https://outlook.office365.com/IMAP.AccessAsUser.All https://outlook.office365.com/SMTP.Send offline_access"
  MS_REDIRECT_URI="http://localhost:8089"

  get_provider() {
    case "$1" in
      personal) echo "google" ;;
      work) echo "microsoft" ;;
      *) echo "Unknown account: $1" >&2; exit 1 ;;
    esac
  }

  get_var() {
    local provider="$1" var="$2"
    case "$provider" in
      google) eval "echo \$GOOGLE_''${var}" ;;
      microsoft) eval "echo \$MS_''${var}" ;;
    esac
  }

  do_setup() {
    local account="$1"
    local provider
    provider=$(get_provider "$account")
    local client_id auth_url token_url scope redirect_uri
    client_id=$(get_var "$provider" CLIENT_ID)
    auth_url=$(get_var "$provider" AUTH_URL)
    token_url=$(get_var "$provider" TOKEN_URL)
    scope=$(get_var "$provider" SCOPE)
    redirect_uri=$(get_var "$provider" REDIRECT_URI)

    local auth_link="''${auth_url}?client_id=''${client_id}&response_type=code&redirect_uri=''${redirect_uri}&scope=''${scope}&access_type=offline&prompt=consent"

    echo "Opening browser for $account ($provider) authorization..."
    echo "If browser doesn't open, visit: $auth_link"
    xdg-open "$auth_link" 2>/dev/null || true

    echo "Waiting for OAuth2 callback on localhost:8089..."
    local code
    code=$(python3 -c "
import http.server, urllib.parse
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        code = q.get('code', [''])[0]
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'Authorization complete. You can close this tab.')
        print(code, flush=True)
        raise SystemExit(0)
    def log_message(self, *a): pass
s = http.server.HTTPServer(('127.0.0.1', 8089), H)
s.handle_request()
")

    if [ -z "$code" ]; then
      echo "Error: no authorization code received" >&2
      exit 1
    fi

    echo "Exchanging code for tokens..."
    local token_response
    if [ "$provider" = "google" ]; then
      token_response=$(curl -s -X POST "$token_url" \
        -d "code=$code" \
        -d "client_id=$client_id" \
        -d "client_secret=$GOOGLE_CLIENT_SECRET" \
        -d "redirect_uri=$redirect_uri" \
        -d "grant_type=authorization_code")
    else
      token_response=$(curl -s -X POST "$token_url" \
        -d "code=$code" \
        -d "client_id=$client_id" \
        -d "redirect_uri=$redirect_uri" \
        -d "grant_type=authorization_code" \
        -d "scope=$scope")
    fi

    local refresh_token
    refresh_token=$(echo "$token_response" | jq -r '.refresh_token // empty')
    if [ -z "$refresh_token" ]; then
      echo "Error: no refresh token in response" >&2
      echo "$token_response" | jq . >&2
      exit 1
    fi

    echo "$refresh_token" | secret-tool store --label="email-oauth2 $account" account "$account" service email-oauth2
    echo "Refresh token stored in keyring for account: $account"
  }

  get_token() {
    local account="$1"
    local provider
    provider=$(get_provider "$account")
    local client_id token_url scope
    client_id=$(get_var "$provider" CLIENT_ID)
    token_url=$(get_var "$provider" TOKEN_URL)
    scope=$(get_var "$provider" SCOPE)

    local refresh_token
    refresh_token=$(secret-tool lookup account "$account" service email-oauth2)
    if [ -z "$refresh_token" ]; then
      echo "No refresh token found for $account. Run: email-oauth2 setup $account" >&2
      exit 1
    fi

    local token_response
    if [ "$provider" = "google" ]; then
      token_response=$(curl -s -X POST "$token_url" \
        -d "refresh_token=$refresh_token" \
        -d "client_id=$client_id" \
        -d "client_secret=$GOOGLE_CLIENT_SECRET" \
        -d "grant_type=refresh_token")
    else
      token_response=$(curl -s -X POST "$token_url" \
        -d "refresh_token=$refresh_token" \
        -d "client_id=$client_id" \
        -d "grant_type=refresh_token" \
        -d "scope=$scope")
    fi

    local access_token
    access_token=$(echo "$token_response" | jq -r '.access_token // empty')
    if [ -z "$access_token" ]; then
      echo "Error: failed to refresh token for $account" >&2
      echo "$token_response" | jq . >&2
      exit 1
    fi

    echo "$access_token"
  }

  case "''${1:-}" in
    setup)
      [ -n "''${2:-}" ] || { echo "Usage: email-oauth2 setup <account>" >&2; exit 1; }
      do_setup "$2"
      ;;
    personal|work)
      get_token "$1"
      ;;
    *)
      echo "Usage: email-oauth2 {setup <account>|personal|work}" >&2
      exit 1
      ;;
  esac
'';
```

Add to the NixOS module body:

```nix
environment.systemPackages = [emailOauth2];
```

**Step 2: Verify the module evaluates**

Run: `nix build .#nixosConfigurations.butternut.config.system.build.toplevel --no-link`
Expected: builds successfully

**Step 3: Commit**

```bash
git add modules/nixos/features/email.nix
git commit -m "Add email-oauth2 helper script for OAuth2 token management"
```

---

### Task 2: Add aerc and imapnotify to Account Definitions

**Files:**
- Modify: `modules/nixos/features/email.nix`

**Step 1: Add `passwordCommand`, aerc, and imapnotify to each account**

On both `personal` and `work` accounts, add:

```nix
# On account level (shared by aerc + imapnotify):
passwordCommand = "${emailOauth2}/bin/email-oauth2 personal";  # or "work"

aerc = {
  enable = true;
  imapAuth = "xoauth2";
  smtpAuth = "xoauth2";
};

imapnotify = {
  enable = true;
  boxes = ["INBOX"];
  onNotify = "${pkgs.libnotify}/bin/notify-send 'New Email' 'New message in personal'";
};
```

**Step 2: Enable aerc and imapnotify services**

Inside the `home-manager.users.${user}` block:

```nix
programs.aerc = {
  enable = true;
  extraConfig.general.unsafe-accounts-conf = true;
};

services.imapnotify.enable = true;
```

**Step 3: Verify the module evaluates**

Run: `nix build .#nixosConfigurations.butternut.config.system.build.toplevel --no-link`
Expected: builds successfully

**Step 4: Commit**

```bash
git add modules/nixos/features/email.nix
git commit -m "Add aerc TUI client and imapnotify push notifications"
```

---

### Task 3: Add DND Toggle Script and Sway Keybinding

**Files:**
- Modify: `modules/nixos/features/mako.nix` (add dnd-toggle script)
- Modify: `modules/nixos/hosts/butternut/configuration.nix` (add keybinding)

**Step 1: Add dnd-toggle script to mako.nix**

Inside the `let` block of mako.nix, add:

```nix
dndToggle = pkgs.writeShellScriptBin "dnd-toggle" ''
  if ${pkgs.mako}/bin/makoctl mode | grep -q do-not-disturb; then
    ${pkgs.mako}/bin/makoctl set-mode default
  else
    ${pkgs.mako}/bin/makoctl set-mode do-not-disturb
  fi
'';
```

Add to system packages inside the home-manager block:

```nix
home.packages = [pkgs.libnotify dndToggle];
```

**Step 2: Add keybinding to butternut configuration.nix**

In the `keybindings = lib.mkOptionDefault { ... }` block, add:

```nix
"Mod4+n" = "exec dnd-toggle";
```

**Step 3: Verify the module evaluates**

Run: `nix build .#nixosConfigurations.butternut.config.system.build.toplevel --no-link`
Expected: builds successfully

**Step 4: Commit**

```bash
git add modules/nixos/features/mako.nix modules/nixos/hosts/butternut/configuration.nix
git commit -m "Add DND toggle script with Mod+n keybinding"
```

---

### Task 4: Add DND Waybar Indicator

**Files:**
- Modify: `modules/nixos/features/waybar.nix`

**Step 1: Add `custom/dnd` module to waybar settings**

In the `waybarSettings.mainBar` attrset, update `modules-left` and add the module definition:

```nix
modules-left = ["custom/dnd" "custom/notification" "clock" "tray"];

"custom/dnd" = {
  exec = "makoctl mode 2>/dev/null | grep -q do-not-disturb && echo '{\"text\": \"󰂛\", \"class\": \"active\"}' || echo '{\"text\": \"󰂚\", \"class\": \"inactive\"}'";
  return-type = "json";
  interval = 2;
  on-click = "dnd-toggle";
  tooltip = false;
};
```

**Step 2: Add CSS for DND indicator**

In `waybarStyle`, add:

```css
#custom-dnd {
  transition: all .3s ease;
  color: @cat-text;
}

#custom-dnd.active {
  color: @cat-overlay0;
}
```

**Step 3: Verify the module evaluates**

Run: `nix build .#nixosConfigurations.butternut.config.system.build.toplevel --no-link`
Expected: builds successfully

**Step 4: Commit**

```bash
git add modules/nixos/features/waybar.nix
git commit -m "Add DND indicator to waybar status bar"
```

---

### Task 5: Add Quiet Hours Systemd Timers

**Files:**
- Modify: `modules/nixos/features/mako.nix`

**Step 1: Add systemd user services and timers for quiet hours**

Inside the `home-manager.users.${user}` block of mako.nix:

```nix
systemd.user.services.dnd-on = {
  Unit.Description = "Enable Do Not Disturb";
  Service = {
    Type = "oneshot";
    ExecStart = "${pkgs.mako}/bin/makoctl set-mode do-not-disturb";
  };
};

systemd.user.timers.dnd-on = {
  Unit.Description = "Enable DND at 22:00";
  Timer = {
    OnCalendar = "*-*-* 22:00:00";
    Persistent = true;
  };
  Install.WantedBy = ["timers.target"];
};

systemd.user.services.dnd-off = {
  Unit.Description = "Disable Do Not Disturb";
  Service = {
    Type = "oneshot";
    ExecStart = "${pkgs.mako}/bin/makoctl set-mode default";
  };
};

systemd.user.timers.dnd-off = {
  Unit.Description = "Disable DND at 08:00";
  Timer = {
    OnCalendar = "*-*-* 08:00:00";
    Persistent = true;
  };
  Install.WantedBy = ["timers.target"];
};
```

**Step 2: Verify the module evaluates**

Run: `nix build .#nixosConfigurations.butternut.config.system.build.toplevel --no-link`
Expected: builds successfully

**Step 3: Commit**

```bash
git add modules/nixos/features/mako.nix
git commit -m "Add quiet hours DND timers (22:00-08:00)"
```

---

### Task 6: Remove Empty swaylock PAM and Update TODO

**Files:**
- Modify: `modules/nixos/features/swayidle.nix`
- Modify: `TODO.md`

**Step 1: Remove the empty PAM attrset from swayidle.nix**

Remove this line:
```nix
security.pam.services.swaylock = {};
```

The email module now sets `security.pam.services.swaylock.enableGnomeKeyring = true;` which also creates the PAM service.

**Step 2: Update TODO.md**

Mark the email and aerc tasks as done. Keep imapnotify OAuth2 first-time setup note.

**Step 3: Verify the module evaluates**

Run: `nix build .#nixosConfigurations.butternut.config.system.build.toplevel --no-link`
Expected: builds successfully

**Step 4: Commit**

```bash
git add modules/nixos/features/swayidle.nix TODO.md
git commit -m "Clean up swaylock PAM duplicate and update TODO"
```
