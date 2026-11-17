{
  inputs,
  self,
  lib,
  ...
}: let
  mkWhichKey = pkgs: menu:
    (self.wrapperModules.which-key.apply {
      inherit pkgs;
      settings = {
        inherit menu;

        # No runtime mode switch here (static wrapper): the dark palette.
        font = "${self.design.type.family.mono} ${toString self.design.type.size.body}";
        background = self.palettes.catppuccin.dark.surface;
        color = self.palettes.catppuccin.dark.fg;
        border = self.palettes.catppuccin.dark.outlineVariant;
        separator = " ➜ ";
        border_width = self.design.panel.border;
        corner_r = self.design.panel.radius;
        padding = self.design.panel.padding;
        rows_per_column = 5;
        column_padding = self.design.space.xxl;

        anchor = "bottom-right";
        margin_right = 0;
        margin_bottom = 5;
        margin_left = 5;
        margin_top = 0;
      };
    }).wrapper;
in {
  flake.mkWhichKeyExe = pkgs: menu: lib.getExe (mkWhichKey pkgs menu);

  flake.wrapperModules.which-key = inputs.wrappers.lib.wrapModule (
    {
      config,
      lib,
      ...
    }: let
      yamlFormat = config.pkgs.formats.yaml {};
    in {
      options = {
        settings = lib.mkOption {
          type = yamlFormat.type;
        };
      };

      config = {
        package = config.pkgs.wlr-which-key;

        args = [
          (toString (yamlFormat.generate "config.yaml" config.settings))
        ];
      };
    }
  );
}
