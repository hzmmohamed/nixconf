{self, ...}: {
  flake.nixosModules.btop = {config, ...}: let
    user = config.preferences.user.name;

    mkBtopTheme = p: ''
      theme[main_bg]="${p.base}"
      theme[main_fg]="${p.text}"
      theme[title]="${p.text}"
      theme[hi_fg]="${p.blue}"
      theme[selected_bg]="${p.surface1}"
      theme[selected_fg]="${p.blue}"
      theme[inactive_fg]="${p.overlay1}"
      theme[graph_text]="${p.rosewater}"
      theme[meter_bg]="${p.surface1}"
      theme[proc_misc]="${p.rosewater}"
      theme[cpu_box]="${p.mauve}"
      theme[mem_box]="${p.green}"
      theme[net_box]="${p.maroon}"
      theme[proc_box]="${p.blue}"
      theme[div_line]="${p.overlay0}"
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
    home-manager.users.${user} = {
      xdg.configFile."btop/themes/catppuccin_latte.theme".text = mkBtopTheme self.catppuccin;
      xdg.configFile."btop/themes/catppuccin_mocha.theme".text = mkBtopTheme self.catppuccinMocha;

      # Default to latte; darkman sed-replaces the color_theme line
      xdg.configFile."btop/btop.conf".text = ''
        color_theme = "catppuccin_latte"
        theme_background = true
      '';
    };
  };
}
