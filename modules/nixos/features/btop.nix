{...}: {
  flake.nixosModules.btop = {config, ...}: let
    user = config.preferences.user.name;

    mkBtopTheme = p: ''
      theme[main_bg]="${p.surface}"
      theme[main_fg]="${p.fg}"
      theme[title]="${p.fg}"
      theme[hi_fg]="${p.accentText}"
      theme[selected_bg]="${p.inverseSurface}"
      theme[selected_fg]="${p.onInverseSurface}"
      theme[inactive_fg]="${p.fgMuted}"
      theme[graph_text]="${p.fgMuted}"
      theme[meter_bg]="${p.surfaceContainerHigh}"
      theme[proc_misc]="${p.accentText}"
      theme[cpu_box]="${p.outline}"
      theme[mem_box]="${p.outline}"
      theme[net_box]="${p.outline}"
      theme[proc_box]="${p.outline}"
      theme[div_line]="${p.outlineVariant}"
      theme[temp_start]="${p.green}"
      theme[temp_mid]="${p.yellow}"
      theme[temp_end]="${p.red}"
      theme[cpu_start]="${p.teal}"
      theme[cpu_mid]="${p.sapphire}"
      theme[cpu_end]="${p.lavender}"
      theme[free_start]="${p.mauve}"
      theme[free_mid]="${p.lavender}"
      theme[free_end]="${p.blue}"
      theme[cached_start]="${p.sapphire}"
      theme[cached_mid]="${p.blue}"
      theme[cached_end]="${p.lavender}"
      theme[available_start]="${p.peach}"
      theme[available_mid]="${p.maroon}"
      theme[available_end]="${p.red}"
      theme[used_start]="${p.green}"
      theme[used_mid]="${p.teal}"
      theme[used_end]="${p.sky}"
      theme[download_start]="${p.peach}"
      theme[download_mid]="${p.maroon}"
      theme[download_end]="${p.red}"
      theme[upload_start]="${p.green}"
      theme[upload_mid]="${p.teal}"
      theme[upload_end]="${p.sky}"
      theme[process_start]="${p.sapphire}"
      theme[process_mid]="${p.lavender}"
      theme[process_end]="${p.mauve}"
    '';
  in {
    preferences.theme = {
      files."btop.theme" = mkBtopTheme;
      links.".config/btop/themes/current.theme" = "btop.theme";
    };

    home-manager.users.${user} = {
      # Remove stale .backup file before activation to prevent "would be clobbered" errors
      home.activation.removeBtopBackup = {
        before = ["checkFilesChanged"];
        after = [];
        data = ''
          rm -f "$HOME/.config/btop/btop.conf.backup"
        '';
      };

      # themes/current.theme -> theme state dir (follows light/dark; btop
      # picks it up on its next start).
      xdg.configFile."btop/btop.conf".text = ''
        color_theme = "current"
        theme_background = true
      '';
    };
  };
}
