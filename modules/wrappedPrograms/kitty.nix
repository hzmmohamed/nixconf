{
  self,
  inputs,
  ...
}: {
  flake.wrapperModules.kitty = {
    config,
    lib,
    ...
  }: {
    options.shell = lib.mkOption {
      type = lib.types.str;
      default = "";
    };
    config = {
      args = lib.mkAfter (lib.optionals (config.shell != "") [config.shell]);
      settings = {
        enable_audio_bell = "no";

        font_size = self.fonts.size;
        font_family = self.fonts.monospace;

        cursor_text_color = "background";

        allow_remote_control = "yes";
        shell_integration = "enabled";

        cursor_trail = 3;

        include = "~/.config/kitty/current-theme.conf";

        remember_window_size = "no";
        initial_window_width = 800;
        initial_window_height = 600;

        map = [
          "ctrl+shift+equal change_font_size all +1.0"
          "ctrl+shift+minus change_font_size all -1.0"
          "ctrl+shift+0 change_font_size all 0"
        ];
      };
    };
  };

  perSystem = {pkgs, ...}: {
    packages.kitty =
      (inputs.wrappers.wrapperModules.kitty.apply {
        inherit pkgs;
        imports = [self.wrapperModules.kitty];
      }).wrapper;
  };
}
