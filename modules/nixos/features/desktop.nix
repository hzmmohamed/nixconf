{self, ...}: {
  flake.nixosModules.desktop = {
    config,
    pkgs,
    ...
  }: let
    fonts = self.fonts;
    selfpkgs = self.packages."${pkgs.stdenv.hostPlatform.system}";

    # Terminal (kitty, wrappedPrograms/kitty.nix) palette: the wrapper
    # includes ~/.local/state/theme/current/kitty.conf. Selection and the
    # active tab by inversion (≥7:1); borders, URLs and marks from the
    # guarded roles; the caret is the ink (where input goes); the 16 ANSI
    # slots are the text-grade ansi* roles (Catppuccin hues, stepped).
    mkKittyColors = p: ''
      foreground ${p.fg}
      background ${p.surface}
      selection_foreground ${p.onInverseSurface}
      selection_background ${p.inverseSurface}
      cursor ${p.selection}
      cursor_text_color ${p.onSelection}
      url_color ${p.accentText}
      active_border_color ${p.focus}
      inactive_border_color ${p.outlineVariant}
      bell_border_color ${p.warning}
      active_tab_foreground ${p.onInverseSurface}
      active_tab_background ${p.inverseSurface}
      inactive_tab_foreground ${p.fgMuted}
      inactive_tab_background ${p.surfaceContainerLow}
      tab_bar_background ${p.surfaceContainerLow}
      mark1_foreground ${p.onSelection}
      mark1_background ${p.selection}
      mark2_foreground ${p.onWarning}
      mark2_background ${p.warning}
      mark3_foreground ${p.onSuccess}
      mark3_background ${p.success}
      color0 ${p.surfaceContainerHigh}
      color8 ${p.surfaceContainerHighest}
      color1 ${p.ansiRed}
      color9 ${p.ansiRed}
      color2 ${p.ansiGreen}
      color10 ${p.ansiGreen}
      color3 ${p.ansiYellow}
      color11 ${p.ansiYellow}
      color4 ${p.ansiBlue}
      color12 ${p.ansiBlue}
      color5 ${p.ansiMagenta}
      color13 ${p.ansiMagenta}
      color6 ${p.ansiCyan}
      color14 ${p.ansiCyan}
      color7 ${p.fgDim}
      color15 ${p.fg}
    '';

    # Linux console (greetd/tuigreet, emergency shells): the dark terminal
    # palette, so the greeter matches the desktop. 16 ANSI slots, no "#".
    dark = config.preferences.theme.palette.dark.noHash;
    consoleColors = with dark; [surface ansiRed ansiGreen ansiYellow ansiBlue ansiMagenta ansiCyan fgDim surfaceContainerHighest ansiRed ansiGreen ansiYellow ansiBlue ansiMagenta ansiCyan fg];
  in {
    preferences.theme = {
      files."kitty.conf" = mkKittyColors;
      # kitty re-reads its config (incl. the include) on SIGUSR1. The
      # nixpkgs binary is wrapped, so match both process names.
      reloadHooks.kitty = "${pkgs.procps}/bin/pkill -USR1 -x 'kitty|\\.kitty-wrapped' || true";
    };

    console.colors = consoleColors;

    imports = [
      self.nixosModules.wallpaper

      self.nixosModules.pipewire
      self.nixosModules.firefox
      self.nixosModules.chromium
      self.nixosModules.removable-media # udisks2 + udiskie automount, eject
      self.nixosModules.network-ui # net-status (bar) + "Network" launcher picker
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

    # IBM Plex (Sans, Serif, Mono, Sans Arabic: self.fonts) + the BlexMono
    # Nerd Font build of Plex Mono for the bar glyphs; Noto for script
    # coverage (CJK, Naskh for serif Arabic) and emoji.
    fonts.packages = with pkgs; [
      ibm-plex
      nerd-fonts.blex-mono
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
        sansSerif = [fonts.sansSerif fonts.arabic];
        monospace = [fonts.monospace fonts.arabic];
        emoji = ["Noto Color Emoji"];
      };
      # Tabular numerals for the UI face (aligned digits in clocks, tables,
      # lists); Arabic falls back to Plex Sans Arabic in every generic family.
      localConf = ''
        <?xml version="1.0"?>
        <!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
        <fontconfig>
          <match target="font">
            <test name="family" compare="eq"><string>${fonts.sansSerif}</string></test>
            <edit name="fontfeatures" mode="append"><string>tnum</string></edit>
          </match>
          <alias binding="same">
            <family>${fonts.sansSerif}</family>
            <prefer><family>${fonts.sansSerif}</family><family>${fonts.arabic}</family></prefer>
          </alias>
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
