{lib, ...}: let
  # Sway config generator: converts Nix attrs to sway config syntax
  # key = "value"       → key value
  # section = { ... }   → section { ... }
  # list values         → repeated keys
  toSwayConfig = {
    attrs,
    indentLevel ? 0,
  }: let
    indent = lib.concatStrings (lib.replicate indentLevel "    ");

    renderValue = name: value:
      if lib.isAttrs value
      then ''
        ${indent}${name} {
        ${toSwayConfig {
          attrs = value;
          indentLevel = indentLevel + 1;
        }}${indent}}
      ''
      else if lib.isList value
      then lib.concatMapStringsSep "" (v: renderValue name v) value
      else "${indent}${name} ${toString value}\n";
  in
    lib.concatStrings (lib.mapAttrsToList renderValue attrs);
in {
  flake.nixosModules.extra_hjem_sway = {
    lib,
    config,
    pkgs,
    ...
  }: let
    user = config.preferences.user.name;
    cfg = config.home.programs.sway;
  in {
    options.home.programs.sway = {
      enable = lib.mkEnableOption "sway configuration";

      settings = lib.mkOption {
        default = {};
        description = "Sway configuration as Nix attribute set";
      };

      extraConfig = lib.mkOption {
        default = "";
        type = lib.types.lines;
        description = "Extra sway configuration appended verbatim";
      };

      finalConfig = lib.mkOption {
        default = "";
      };
    };

    config = lib.mkIf cfg.enable {
      home.programs.sway.finalConfig =
        (toSwayConfig {attrs = cfg.settings;})
        + cfg.extraConfig;

      hjem.users.${user}.files.".config/sway/config".text = cfg.finalConfig;

      # Map preferences.autostart to exec lines
      home.programs.sway.extraConfig = lib.mkBefore (
        lib.concatMapStringsSep "\n" (
          entry: let
            exe =
              if (builtins.typeOf entry) == "string"
              then lib.getExe (pkgs.writeShellScriptBin "autostart" entry)
              else lib.getExe entry;
          in "exec ${exe}"
        )
        config.preferences.autostart
      );
    };
  };
}
