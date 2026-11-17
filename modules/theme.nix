{lib, ...}: let
  theme = {
    base00 = "#242424"; # bg
    base01 = "#3c3836"; # dark
    base02 = "#504945";
    base03 = "#665c54";
    base04 = "#bdae93";
    base05 = "#d5c4a1";
    base06 = "#ebdbb2"; # fg
    base07 = "#fbf1c7"; # light fg
    base08 = "#fb4934"; # red
    base09 = "#fe8019"; # orange
    base0A = "#fabd2f"; # yellow
    base0B = "#b8bb26"; # green
    base0C = "#8ec07c"; # cyan
    base0D = "#7daea3"; # blue
    base0E = "#e089a1"; # magenta
    base0F = "#f28534"; # orange
  };

  stripHash = str:
    if builtins.substring 0 1 str == "#"
    then builtins.substring 1 (builtins.stringLength str - 1) str
    else str;

  themeNoHash = builtins.mapAttrs (_: v: stripHash v) theme;

  # Catppuccin Latte — light mode
  catppuccin = {
    rosewater = "#dc8a78";
    flamingo = "#dd7878";
    pink = "#ea76cb";
    mauve = "#8839ef";
    red = "#d20f39";
    maroon = "#e64553";
    peach = "#fe640b";
    yellow = "#df8e1d";
    green = "#40a02b";
    teal = "#179299";
    sky = "#04a5e5";
    sapphire = "#209fb5";
    blue = "#1e66f5";
    lavender = "#7287fd";
    text = "#4c4f69";
    subtext1 = "#5c5f77";
    subtext0 = "#6c6f85";
    overlay2 = "#7c7f93";
    overlay1 = "#8c8fa1";
    overlay0 = "#9ca0b0";
    surface2 = "#acb0be";
    surface1 = "#bcc0cc";
    surface0 = "#ccd0da";
    base = "#eff1f5";
    mantle = "#e6e9ef";
    crust = "#dce0e8";
  };

  # Catppuccin Mocha — dark mode
  catppuccinMocha = {
    rosewater = "#f5e0dc";
    flamingo = "#f2cdcd";
    pink = "#f5c2e7";
    mauve = "#cba6f7";
    red = "#f38ba8";
    maroon = "#eba0ac";
    peach = "#fab387";
    yellow = "#f9e2af";
    green = "#a6e3a1";
    teal = "#94e2d5";
    sky = "#89dceb";
    sapphire = "#74c7ec";
    blue = "#89b4fa";
    lavender = "#b4befe";
    text = "#cdd6f4";
    subtext1 = "#bac2de";
    subtext0 = "#a6adc8";
    overlay2 = "#9399b2";
    overlay1 = "#7f849c";
    overlay0 = "#6c7086";
    surface2 = "#585b70";
    surface1 = "#45475a";
    surface0 = "#313244";
    base = "#1e1e2e";
    mantle = "#181825";
    crust = "#11111b";
  };
  fonts = {
    sansSerif = "Inter";
    serif = "Noto Serif";
    monospace = "JetBrainsMono Nerd Font";
    size = 12;
    barSize = 12;
  };

  # --- Colour helpers (sRGB, opaque) ----------------------------------------
  # Used to derive hairlines and interaction tints by mixing palette colours
  # onto opaque surfaces (no alpha anywhere).
  hexDigits = {
    "0" = 0;
    "1" = 1;
    "2" = 2;
    "3" = 3;
    "4" = 4;
    "5" = 5;
    "6" = 6;
    "7" = 7;
    "8" = 8;
    "9" = 9;
    "a" = 10;
    "b" = 11;
    "c" = 12;
    "d" = 13;
    "e" = 14;
    "f" = 15;
  };
  byteAt = s: i:
    hexDigits.${lib.toLower (builtins.substring i 1 s)}
    * 16
    + hexDigits.${lib.toLower (builtins.substring (i + 1) 1 s)};
  toRgb = hex: let
    s = stripHash hex;
  in [(byteAt s 0) (byteAt s 2) (byteAt s 4)];
  toByteHex = n: let
    h = lib.toLower (lib.toHexString n);
  in
    if n < 16
    then "0${h}"
    else h;
  fromRgb = rgb: "#" + lib.concatMapStrings toByteHex rgb;
  # mix a b t: t·a + (1−t)·b, t in [0,1] (e.g. "26% fg over surface").
  mix = a: b: t:
    fromRgb (lib.zipListsWith (x: y: let
      v = t * x + (1 - t) * y;
    in
      builtins.floor (v + 0.5)) (toRgb a) (toRgb b));
  color = {inherit stripHash toRgb fromRgb mix;};

  # --- Palette shape ---------------------------------------------------------
  # Every themed module consumes this shape (via
  # config.preferences.theme.palette.{light,dark}):
  #   - the 26 Catppuccin slot names (rosewater … crust)
  #   - semantic aliases (accent, onAccent, Material-style surface roles)
  #   - contrast-tiered text roles fg/fgDim/fgMuted/fgFaint
  #   - derived opaque mixes: hairline{Soft,,Strong}, tint{5,10,16}
  #   - isDark: whether this is the dark variant
  #   - accentName: a Catppuccin accent name (lookup key for packages that
  #     only accept named colours, e.g. papirus-folders); null if unknown
  #   - noHash: the same attrset with every colour's leading "#" stripped
  # A future wallpaper (matugen) palette must provide the same keys.
  mkPalette = {
    slots,
    onAccent,
    isDark,
    accentName ? "lavender",
  }: let
    p =
      slots
      // rec {
        accent = slots.${accentName};
        inherit onAccent;
        primary = accent;
        error = slots.red;

        surface = slots.base;
        surfaceContainerLow = slots.mantle;
        surfaceContainer = slots.surface0;
        surfaceContainerHigh = slots.surface1;
        onSurface = slots.text;
        onSurfaceVariant = slots.subtext0;
        outline = slots.overlay0;
        outlineVariant = slots.surface1;
        inverseSurface = slots.text;
        onInverseSurface = slots.base;

        # Text tiers (design targets 12 / 9 / 6.6 / 4.6 : 1 on surface).
        # Catppuccin slots only approximate them — Latte tops out at ~7:1 and
        # its fgFaint (overlay2) is ~3.5:1; the WCAG guard (phase 5) will
        # enforce minimums for generated palettes.
        fg = slots.text;
        fgDim = slots.subtext1;
        fgMuted = slots.subtext0;
        fgFaint = slots.overlay2;

        hairlineSoft = mix slots.text slots.base 0.13;
        hairline = mix slots.text slots.base 0.26;
        hairlineStrong = mix slots.text slots.base 0.42;
        tint5 = mix slots.text slots.base 0.05;
        tint10 = mix slots.text slots.base 0.10;
        tint16 = mix slots.text slots.base 0.16;
      };
  in
    p
    // {
      inherit accentName isDark;
      noHash = builtins.mapAttrs (_: stripHash) p;
    };

  palettes.catppuccin = {
    light = mkPalette {
      slots = catppuccin;
      onAccent = catppuccin.base;
      isDark = false;
    };
    dark = mkPalette {
      slots = catppuccinMocha;
      onAccent = catppuccinMocha.crust;
      isDark = true;
    };
  };
in {
  flake = {
    inherit theme themeNoHash catppuccin catppuccinMocha fonts palettes color;
  };
}
