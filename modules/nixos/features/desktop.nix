{self, ...}: {
  flake.nixosModules.desktop = {pkgs, ...}: let
    fonts = self.fonts;
    selfpkgs = self.packages."${pkgs.stdenv.hostPlatform.system}";

    # Terminal (kitty, wrappedPrograms/kitty.nix) palette: the wrapper
    # includes ~/.local/state/theme/current/kitty.conf.
    mkKittyColors = p: ''
      foreground ${p.fg}
      background ${p.surface}
      selection_foreground ${p.onInverseSurface}
      selection_background ${p.inverseSurface}
      cursor ${p.rosewater}
      cursor_text_color ${p.surface}
      url_color ${p.accent}
      active_border_color ${p.accent}
      inactive_border_color ${p.surface0}
      bell_border_color ${p.peach}
      active_tab_foreground ${p.onInverseSurface}
      active_tab_background ${p.inverseSurface}
      inactive_tab_foreground ${p.fgMuted}
      inactive_tab_background ${p.surfaceContainerLow}
      tab_bar_background ${p.crust}
      mark1_foreground ${p.surface}
      mark1_background ${p.lavender}
      mark2_foreground ${p.surface}
      mark2_background ${p.mauve}
      mark3_foreground ${p.surface}
      mark3_background ${p.sapphire}
      color0 ${p.surface1}
      color8 ${p.surface2}
      color1 ${p.red}
      color9 ${p.red}
      color2 ${p.green}
      color10 ${p.green}
      color3 ${p.yellow}
      color11 ${p.yellow}
      color4 ${p.blue}
      color12 ${p.blue}
      color5 ${p.pink}
      color13 ${p.pink}
      color6 ${p.teal}
      color14 ${p.teal}
      color7 ${p.subtext1}
      color15 ${p.subtext0}
    '';
  in {
    preferences.theme = {
      files."kitty.conf" = mkKittyColors;
      # kitty re-reads its config (incl. the include) on SIGUSR1. The
      # nixpkgs binary is wrapped, so match both process names.
      reloadHooks.kitty = "${pkgs.procps}/bin/pkill -USR1 -x 'kitty|\\.kitty-wrapped' || true";
    };

    imports = [
      self.nixosModules.wallpaper

      self.nixosModules.pipewire
      self.nixosModules.firefox
      self.nixosModules.chromium
      self.nixosModules.removable-media # udisks2 + udiskie automount, eject
    ];

    # Turns on GUI bits of modules every host imports (gtk, tailscale tray).
    preferences.desktop.enable = true;

    environment.systemPackages = [
      selfpkgs.terminal
      pkgs.file-roller # archive manager used by thunar-archive-plugin
    ];

    # File manager: Thunar (GTK3, adw-gtk3 recoloured from the palette).
    # No search/indexing plugins here — file search lives in the launcher.
    programs.thunar = {
      enable = true;
      plugins = with pkgs; [
        thunar-archive-plugin
        # no thunar-volman: udiskie (removable-media) is the only automounter
      ];
    };
    services.gvfs.enable = true; # trash, volumes + eject in the sidebar, MTP, sftp://, smb://
    services.tumbler.enable = true; # thumbnails

    # Inter (UI), JetBrains Mono Nerd Font (terminal, bar, literal data),
    # Noto Serif, Noto Sans Arabic (in noto-fonts) as fallback, CJK + emoji.
    fonts.packages = with pkgs; [
      inter
      nerd-fonts.jetbrains-mono
      noto-fonts
      noto-fonts-cjk-sans
      noto-fonts-cjk-serif
      noto-fonts-color-emoji
      corefonts # metric-compatible fonts for office documents
    ];

    environment.variables.LOG_ICONS = "true";

    fonts.fontconfig = {
      defaultFonts = {
        serif = [fonts.serif "Noto Naskh Arabic"];
        sansSerif = [fonts.sansSerif "Noto Sans Arabic"];
        monospace = [fonts.monospace "Noto Sans Arabic"];
        emoji = ["Noto Color Emoji"];
      };
      # Tabular numerals for Inter (aligned digits in clocks, tables, lists).
      localConf = ''
        <?xml version="1.0"?>
        <!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
        <fontconfig>
          <match target="font">
            <test name="family" compare="eq"><string>Inter</string></test>
            <edit name="fontfeatures" mode="append"><string>tnum</string></edit>
          </match>
        </fontconfig>
      '';
    };

    i18n.defaultLocale = "en_US.UTF-8";

    services.upower.enable = true;

    # Disable VT switching (Ctrl+Alt+F1-F12) — prevents accidentally
    # leaving the compositor session, especially problematic in nested/VM setups.
    services.logind.settings.Login.NAutoVTs = 0;
    systemd.services."getty@".enable = false;
    systemd.services."autovt@".enable = false;

    security.polkit.enable = true;
    # Graphical polkit agent (Sway has none): without it pkexec/admin actions
    # (gnome-disks on internal disks, virt-manager, nm system connections,
    # fwupd) fail with "Not authorized". Noctalia's own agent stays off.
    security.soteria.enable = true;

    hardware = {
      enableAllFirmware = true;

      bluetooth.enable = true;
      bluetooth.powerOnBoot = true;

      graphics = {
        enable = true;
        enable32Bit = true;
      };
    };
  };
}
