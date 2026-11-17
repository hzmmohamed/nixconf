# A tiny local Noctalia plugin ("nixconf/status") shipped from the Nix store
# as a read-only `path` plugin source. Two bar-widget entries:
#   command  — runs a command printing waybar-style JSON ({text,tooltip,class})
#              every N seconds; hidden while text is empty. Reuses the exact
#              scripts the waybar stack uses (modules/packages/desktop-status.nix).
#   syswarn  — one system stat (cpu|ram|temp|disk) from Noctalia's own monitor,
#              shown only above a threshold.
{self, ...}: {
  flake.nixosModules.noctalia = {
    config,
    lib,
    pkgs,
    ...
  }: let
    user = config.preferences.user.name;
    selfpkgs = self.packages.${pkgs.stdenv.hostPlatform.system};
    toml = pkgs.formats.toml {};

    setting = key: type: default: {
      inherit key type default;
      label_key = "settings.${key}";
    };

    manifest = {
      id = "nixconf/status";
      name = "Status";
      version = "1.0.0";
      plugin_api = 24;
      author = "nixconf";
      description = "Threshold system warnings and command-driven status widgets.";
      widget = [
        {
          id = "command";
          entry = "command.luau";
          setting = [
            (setting "command" "string" "")
            (setting "interval" "int" 30)
            (setting "glyph" "glyph" "point")
            (setting "click_command" "string" "")
            (setting "right_click_command" "string" "")
          ];
        }
        {
          id = "syswarn";
          entry = "syswarn.luau";
          setting = [
            (setting "stat" "string" "cpu")
            (setting "threshold" "double" 80.0)
            (setting "critical" "double" 90.0)
            (setting "path" "string" "/")
            (setting "interval" "int" 20)
          ];
        }
      ];
    };

    translations = builtins.toJSON {
      "settings.command" = "Command (prints waybar-style JSON)";
      "settings.interval" = "Refresh interval (seconds)";
      "settings.glyph" = "Glyph";
      "settings.click_command" = "Left-click command";
      "settings.right_click_command" = "Right-click command";
      "settings.stat" = "Stat: cpu, ram, temp or disk";
      "settings.threshold" = "Show at or above";
      "settings.critical" = "Critical at or above";
      "settings.path" = "Disk path";
    };

    commandLuau = ''
      --!nonstrict
      local busy = false

      local function hide()
        barWidget.setVisible(false)
      end

      local function apply(result)
        busy = false
        if result == nil or result.exitCode ~= 0 then
          return hide()
        end
        local data = noctalia.json.decode(result.stdout or "")
        if type(data) ~= "table" or data.text == nil or data.text == "" then
          return hide()
        end
        barWidget.setText(data.text)
        if data.tooltip ~= nil and data.tooltip ~= "" then
          barWidget.setTooltip(data.tooltip)
        else
          barWidget.clearTooltip()
        end
        local cls = data.class or ""
        if cls == "error" or cls == "down" or cls == "critical" then
          barWidget.setGlyphColor("error")
        else
          barWidget.setGlyphColor("primary")
        end
        barWidget.setVisible(true)
      end

      local function refresh()
        if busy then
          return
        end
        local cmd = noctalia.getConfig("command")
        if cmd == nil or cmd == "" then
          return hide()
        end
        busy = true
        if not noctalia.runAsync({ cmd }, apply) then
          busy = false
        end
      end

      local function runAction(key)
        local c = noctalia.getConfig(key)
        if c ~= nil and c ~= "" then
          noctalia.runAsync({ "/bin/sh", "-c", c }, function(_)
            refresh()
          end)
        end
      end

      barWidget.setGlyph(noctalia.getConfig("glyph") or "point")
      noctalia.setUpdateInterval(math.max(5, noctalia.getConfig("interval") or 30) * 1000)
      hide()
      refresh()

      function update()
        refresh()
      end

      function onClick()
        runAction("click_command")
      end

      function onRightClick()
        runAction("right_click_command")
      end

      function onIpc(event, _payload)
        if event == "refresh" then
          refresh()
        end
      end
    '';

    syswarnLuau = ''
      --!nonstrict
      local stat = noctalia.getConfig("stat") or "cpu"
      local threshold = noctalia.getConfig("threshold") or 80
      local critical = noctalia.getConfig("critical") or 90
      local path = noctalia.getConfig("path") or "/"
      local glyphs = { cpu = "cpu-usage", ram = "memory", temp = "cpu-temperature", disk = "storage" }

      local function read()
        if stat == "disk" then
          local d = noctalia.diskStats(path)
          return d and d.usagePercent, "%"
        end
        local s = noctalia.systemStats()
        if s == nil then
          return nil, ""
        end
        if stat == "cpu" then
          return s.cpu and s.cpu.usagePercent, "%"
        elseif stat == "ram" then
          return s.ram and s.ram.usagePercent, "%"
        elseif stat == "temp" then
          return s.cpu and s.cpu.tempC, "°"
        end
        return nil, ""
      end

      function update()
        local v, unit = read()
        if v == nil or v < threshold then
          barWidget.setVisible(false)
          return
        end
        local color = v >= critical and "error" or "tertiary"
        barWidget.setText(string.format("%.0f%s", v, unit))
        barWidget.setGlyphColor(color)
        barWidget.setColor(color)
        barWidget.setVisible(true)
      end

      barWidget.setGlyph(glyphs[stat] or "warning")
      barWidget.setVisible(false)
      noctalia.setUpdateInterval(math.max(5, noctalia.getConfig("interval") or 20) * 1000)
      update()
    '';

    # Source root: one sub-directory per plugin (`<root>/status/plugin.toml`).
    pluginSource = pkgs.runCommand "noctalia-nixconf-plugins" {} ''
      d=$out/status
      mkdir -p $d/translations
      cp ${toml.generate "plugin.toml" manifest} $d/plugin.toml
      cp ${pkgs.writeText "command.luau" commandLuau} $d/command.luau
      cp ${pkgs.writeText "syswarn.luau" syswarnLuau} $d/syswarn.luau
      cp ${pkgs.writeText "en.json" translations} $d/translations/en.json
    '';

    syswarn = stat: threshold: critical:
      {
        type = "nixconf/status:syswarn";
        inherit stat threshold critical;
      }
      // lib.optionalAttrs (stat == "disk") {
        path = "/";
        interval = 300;
      };
  in {
    config = lib.mkIf (config.preferences.desktopShell == "noctalia") {
      home-manager.users.${user}.programs.noctalia.settings = {
        plugins = {
          enabled = ["nixconf/status"];
          auto_update = "none";
          source = [
            {
              name = "nixconf";
              kind = "path";
              location = "${pluginSource}";
              enabled = true;
            }
          ];
        };

        # Named widget instances (placed on the bar in bar.nix).
        widget = {
          mail = {
            type = "nixconf/status:command";
            command = lib.getExe selfpkgs.mail-unread-status;
            interval = 60;
            glyph = "mail";
            click_command = "${pkgs.thunderbird}/bin/thunderbird";
            right_click_command = "mail-unread-refresh";
          };
          sync = lib.mkIf config.services.syncthing.enable {
            type = "nixconf/status:command";
            command = lib.getExe selfpkgs.sync-status;
            interval = 30;
            glyph = "refresh";
            click_command = "xdg-open http://${config.services.syncthing.guiAddress}";
          };
          cpu-warn = syswarn "cpu" 75.0 90.0;
          ram-warn = syswarn "ram" 80.0 92.0;
          temp-warn = syswarn "temp" 80.0 90.0;
          disk-warn = syswarn "disk" 85.0 95.0;
        };
      };
    };
  };
}
