{...}: {
  flake.nixosModules.email = {
    config,
    lib,
    pkgs,
    ...
  }: let
    user = config.preferences.user.name;

    emailOauth2 = pkgs.writeShellScriptBin "email-oauth2" ''
            set -euo pipefail
            export PATH="${pkgs.lib.makeBinPath [
        pkgs.curl
        pkgs.jq
        pkgs.libsecret
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
              code = q.get('code', [""])[0]
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

    # ── Unread counts + new-mail notifications for the desktop bar ────────
    # One IMAP `STATUS INBOX (UNSEEN)` per account, written to
    # $XDG_RUNTIME_DIR/mail-unread/<account>.count. Runs when imapnotify
    # reports new mail, on a 5-minute timer (to catch mail read elsewhere), or
    # on demand (bar right click). When a count rises it notifies with the
    # sender and subject of the newest unseen message; the first refresh of a
    # session (no previous count) is silent. `mail-unread-status`
    # (modules/packages) reads the counts.
    mailAccounts =
      lib.filterAttrs (_: a: a.imapnotify.enable)
      config.home-manager.users.${user}.accounts.email.accounts;

    # Decode From/Subject out of an IMAP FETCH response (RFC 2047 words, folded
    # lines). Prints "<from>\t<subject>", or nothing.
    mailHeaders = pkgs.writeText "mail-headers.py" ''
      import sys, email, email.utils
      from email.header import decode_header, make_header
      raw = sys.stdin.buffer.read().decode("utf-8", "replace")
      body = raw.split("\n", 1)[1] if raw.startswith("*") else raw
      msg = email.message_from_string(body)
      def get(k):
          v = msg.get(k)
          if not v:
              return ""
          try:
              v = str(make_header(decode_header(v)))
          except Exception:
              pass
          return " ".join(v.split())
      frm = get("From")
      name, addr = email.utils.parseaddr(frm)
      if name or addr or get("Subject"):
          print((name or addr or frm) + "\t" + get("Subject"))
    '';

    mailUnreadRefresh = pkgs.writeShellApplication {
      name = "mail-unread-refresh";
      runtimeInputs = [pkgs.coreutils pkgs.curl pkgs.gnugrep pkgs.systemd pkgs.util-linux pkgs.libnotify pkgs.python3];
      text = ''
        dir="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/mail-unread"
        mkdir -p "$dir"
        # imapnotify and the timer can fire together: one refresh at a time,
        # so a rise is only ever notified once.
        exec 9>"$dir/.lock"
        flock 9

        # notify <account> <imap-url> <login> <token> <new-count>
        notify() {
          local search uid info from subject title body
          search=$(curl -sS --max-time 20 --url "$2/INBOX" --user "$3" \
            --oauth2-bearer "$4" --request 'UID SEARCH UNSEEN' 2>/dev/null) || search=""
          uid=$(grep -o '^\* SEARCH[ 0-9]*' <<<"$search" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | tail -n1) || uid=""
          info=""
          if [ -n "$uid" ]; then
            # BODY.PEEK: reading the headers must not mark the message seen.
            info=$(curl -sS --max-time 20 --url "$2/INBOX" --user "$3" --oauth2-bearer "$4" \
              --request "UID FETCH $uid (BODY.PEEK[HEADER.FIELDS (FROM SUBJECT)])" 2>/dev/null \
              | python3 ${mailHeaders}) || info=""
          fi
          title="''${1^}"
          if [ -n "$info" ]; then
            from=''${info%%$'\t'*}
            subject=''${info#*$'\t'}
            title+=" · $from"
            body="''${subject:-(no subject)}"
            [ "$5" -gt 1 ] && body+=$'\n'"+$(($5 - 1)) more"
          else
            body="$5 new message$([ "$5" -gt 1 ] && echo s)"
          fi
          notify-send -a Mail -i mail-unread "$title" "$body" || true
        }

        # refresh <account> <imap-host> <imap-port> <login>
        refresh() {
          local token out n prev url
          url="imaps://$2:$3"
          token=$(${emailOauth2}/bin/email-oauth2 "$1" 2>/dev/null) || return 0
          out=$(curl -sS --max-time 20 --url "$url/" --user "$4" \
            --oauth2-bearer "$token" --request 'STATUS INBOX (UNSEEN)' 2>/dev/null) || return 0
          n=$(grep -o 'UNSEEN [0-9]*' <<<"$out" | grep -o '[0-9]*$') || return 0
          prev=$(head -n1 "$dir/$1.count" 2>/dev/null || true)
          printf '%s\n' "$n" >"$dir/$1.count.tmp" && mv "$dir/$1.count.tmp" "$dir/$1.count"
          if [[ "$prev" =~ ^[0-9]+$ ]] && [ "$n" -gt "$prev" ]; then
            notify "$1" "$url" "$4" "$token" "$((n - prev))"
          fi
        }

        target="''${1:-all}"
        ${lib.concatStrings (lib.mapAttrsToList (name: a: ''
            if [ "$target" = all ] || [ "$target" = ${lib.escapeShellArg name} ]; then
              refresh ${lib.escapeShellArgs [name a.imap.host (toString a.imap.port) a.userName]}
            fi
          '')
          mailAccounts)}
        # Nudge waybar's custom/mail module (signal 9); harmless if waybar is not running.
        systemctl --user kill --kill-whom=main -s SIGRTMIN+9 waybar.service 2>/dev/null || true
      '';
    };

    # Webmail per account, from its home-manager flavor.
    webmail = a:
      {
        "gmail.com" = {
          label = "Gmail";
          url = "https://mail.google.com/mail/u/${a.address}/";
        };
        "outlook.office365.com" = {
          label = "Outlook";
          url = "https://outlook.office.com/mail/";
        };
      }.${
        a.flavor
      } or null;

    thunderbird = lib.getExe config.home-manager.users.${user}.programs.thunderbird.package;

    # mail-menu — the bar widget's left click: Thunderbird, each account's
    # webmail (with its unread count), refresh.
    #   MAIL_MENU_LAUNCHER  dmenu command (stdin options → selection on stdout)
    #                       default: vicinae dmenu -p Mail --no-quick-look
    mailMenu = pkgs.writeShellApplication {
      name = "mail-menu";
      runtimeInputs = [pkgs.coreutils pkgs.xdg-utils pkgs.util-linux];
      text = ''
        read -ra launcher <<<"''${MAIL_MENU_LAUNCHER:-vicinae dmenu -p Mail --no-quick-look}"
        dir="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/mail-unread"
        count() {
          local n
          n=$(head -n1 "$dir/$1.count" 2>/dev/null || true)
          [[ "$n" =~ ^[0-9]+$ ]] && printf ' (%s)' "$n"
          return 0
        }

        choice=$(
          {
            echo "Thunderbird"
            ${lib.concatStrings (lib.mapAttrsToList (name: a: let
          w = webmail a;
        in
          lib.optionalString (w != null) ''
            echo "${w.label} — ${name}$(count ${lib.escapeShellArg name})"
          '')
        mailAccounts)}
            echo "Refresh counts"
          } | "''${launcher[@]}"
        ) || exit 0

        case "$choice" in
          Thunderbird) setsid -f ${thunderbird} >/dev/null 2>&1 ;;
          "Refresh counts") exec ${lib.getExe mailUnreadRefresh} ;;
          ${lib.concatStrings (lib.mapAttrsToList (name: a: let
          w = webmail a;
        in
          lib.optionalString (w != null) ''
            ${lib.escapeShellArg "${w.label} — ${name}"}*) setsid -f xdg-open ${lib.escapeShellArg w.url} >/dev/null 2>&1 ;;
          '')
        mailAccounts)}
        esac
      '';
    };
  in {
    environment.systemPackages = [emailOauth2 mailUnreadRefresh mailMenu];

    # gnome-keyring as secret-service provider for OAuth2 tokens and VS Code secrets
    services.gnome.gnome-keyring.enable = true;

    # PAM: auto-unlock keyring on login, re-unlock after swaylock
    security.pam.services.greetd.enableGnomeKeyring = true;
    security.pam.services.swaylock.enableGnomeKeyring = true;

    # The keyring daemon is started and unlocked by PAM (gkr-pam) at greetd login.
    # Don't also run home-manager's services.gnome-keyring: that spawned a second
    # daemon racing the PAM one for org.freedesktop.secrets.
    home-manager.users.${user} = {
      # Remove stale .backup files before home-manager activation to prevent
      # "would be clobbered" errors from Thunderbird's runtime-generated files
      home.activation.removeThunderbirdBackups = {
        before = ["checkFilesChanged"];
        after = [];
        data = ''
          rm -f "$HOME/.thunderbird/${user}/search.json.mozlz4.backup"
        '';
      };

      programs.thunderbird = {
        enable = true;

        # Follow system dark/light preference (set by darkman via GTK/dconf)
        settings = {
          "browser.theme.content-theme" = 2; # 2 = follow system
          "browser.theme.toolbar-theme" = 2;
          "layout.css.prefers-color-scheme.content-override" = 2; # 2 = follow system
          "browser.in-content.dark-mode" = true; # allow dark mode in content
        };

        profiles.hfahmi = {
          isDefault = true;
          search.default = "ddg";
        };
      };

      programs.aerc = {
        enable = true;
        extraConfig.general.unsafe-accounts-conf = true;
      };

      services.imapnotify.enable = true;

      # imapnotify needs gnome-keyring unlocked to retrieve OAuth2 tokens
      # via secret-tool. Wait for sway-session.target (keyring is PAM-unlocked
      # during greetd login, but user services can race ahead of it).
      systemd.user.services.imapnotify-personal.Unit = {
        After = ["sway-session.target"];
        Requisite = ["sway-session.target"];
      };
      systemd.user.services.imapnotify-work.Unit = {
        After = ["sway-session.target"];
        Requisite = ["sway-session.target"];
      };

      # Slow background refresh of the unread counts (see mailUnreadRefresh).
      # Bound to the sway session: the keyring is only unlocked inside it.
      systemd.user.services.mail-unread-refresh = {
        Unit = {
          Description = "Refresh unread mail counts for the desktop bar";
          After = ["sway-session.target"];
        };
        Service = {
          Type = "oneshot";
          ExecStart = lib.getExe mailUnreadRefresh;
        };
      };
      systemd.user.timers.mail-unread-refresh = {
        Unit = {
          Description = "Refresh unread mail counts every 5 minutes";
          PartOf = ["sway-session.target"];
          After = ["sway-session.target"];
        };
        Timer = {
          OnActiveSec = "20s";
          OnUnitActiveSec = "5min";
        };
        Install.WantedBy = ["sway-session.target"];
      };

      accounts.email.accounts = {
        personal = {
          address = "hzmmohamed@gmail.com";
          flavor = "gmail.com";
          primary = true;
          realName = "Hazem Fahmi";
          passwordCommand = "${emailOauth2}/bin/email-oauth2 personal";
          signature = {
            delimiter = "--";
            text = ''
              Hazem Fahmi
            '';
            showSignature = "append";
          };
          thunderbird = {
            enable = true;
            profiles = ["hfahmi"];
            settings = id: {
              # OAuth2 authentication (method 10)
              "mail.server.server_${id}.authMethod" = 10;
              "mail.smtpserver.smtp_${id}.authMethod" = 10;
              "mail.server.server_${id}.autosync_max_age_days" = 30;
            };
          };
          aerc = {
            enable = true;
            imapAuth = "xoauth2";
            smtpAuth = "xoauth2";
          };
          imapnotify = {
            enable = true;
            boxes = ["INBOX"];
            onNotify = "${lib.getExe mailUnreadRefresh} personal";
          };
        };

        work = {
          address = "h.fahmi@transportforcairo.com";
          flavor = "outlook.office365.com";
          realName = "Hazem Fahmi";
          passwordCommand = "${emailOauth2}/bin/email-oauth2 work";
          signature = {
            delimiter = "--";
            text = ''
              Hazem Fahmi
              Senior Research Software Engineer
            '';
            showSignature = "append";
          };
          thunderbird = {
            enable = true;
            profiles = ["hfahmi"];
            settings = id: {
              # OAuth2 authentication (method 10)
              "mail.server.server_${id}.authMethod" = 10;
              "mail.smtpserver.smtp_${id}.authMethod" = 10;
            };
          };
          aerc = {
            enable = true;
            imapAuth = "xoauth2";
            smtpAuth = "xoauth2";
          };
          imapnotify = {
            enable = true;
            boxes = ["INBOX"];
            onNotify = "${lib.getExe mailUnreadRefresh} work";
          };
        };
      };
    };
  };
}
