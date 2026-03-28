{self, ...}: {
  flake.nixosModules.desktop = {pkgs, ...}: let
    selfpkgs = self.packages."${pkgs.system}";
  in {
    imports = [
      self.nixosModules.gtk
      self.nixosModules.wallpaper

      self.nixosModules.pipewire
      self.nixosModules.firefox
      self.nixosModules.chromium
    ];

    environment.systemPackages = [
      selfpkgs.terminal
      pkgs.pcmanfm
    ];

    fonts.packages = with pkgs; [
      nerd-fonts.jetbrains-mono
      nerd-fonts.fira-code
      nerd-fonts.droid-sans-mono
      ubuntu-sans
      cm_unicode
      corefonts
      unifont
      noto-fonts
      noto-fonts-cjk-sans
      noto-fonts-cjk-serif
      noto-fonts-color-emoji
      font-awesome
      roboto
      roboto-mono
      victor-mono
      jetbrains-mono
      open-sans
      meslo-lgs-nf
    ];

    environment.variables.LOG_ICONS = "true";

    fonts.fontconfig.defaultFonts = {
      serif = ["Ubuntu Sans"];
      sansSerif = ["Ubuntu Sans"];
      monospace = ["JetBrainsMono Nerd Font"];
    };

    i18n.defaultLocale = "en_US.UTF-8";

    services.upower.enable = true;

    # Disable VT switching (Ctrl+Alt+F1-F12) — prevents accidentally
    # leaving the compositor session, especially problematic in nested/VM setups.
    services.logind.settings.Login.NAutoVTs = 0;
    systemd.services."getty@".enable = false;
    systemd.services."autovt@".enable = false;

    security.polkit.enable = true;

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
