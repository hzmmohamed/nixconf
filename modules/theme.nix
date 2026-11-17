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
  # One family for the whole desktop (design-system signature, see
  # docs/plans/2026-11-17-design-system.md §2.3): IBM Plex Sans for UI, Plex
  # Mono (as the BlexMono Nerd Font build, for the bar glyphs) in terminals,
  # Plex Sans Arabic as the Arabic fallback drawn to the same rhythm, Plex
  # Serif for documents. Packages: features/desktop.nix.
  fonts = {
    sansSerif = "IBM Plex Sans";
    serif = "IBM Plex Serif";
    monospace = "BlexMono Nerd Font";
    arabic = "IBM Plex Sans Arabic";
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
  #   - colour roles with a contrast contract (docs/plans/2026-11-17-design-
  #     system.md §2; enforced for generated palettes by extra/theme-palette.py
  #     and verified for these by checks.design-contrast):
  #       surface, surfaceContainerLow/Container/High/Highest   opaque surfaces
  #       fg (≥7:1 on surface, ≥4.5 on the three text surfaces)
  #       ansiRed/Green/Yellow/Blue/Magenta/Cyan (≥4.5)  terminal colours 1–6
  #       fgMuted (≥4.5 on text surfaces)   secondary text
  #       fgFaint (≥3 on surface/Low)        indicators, disabled; never text
  #       outline (≥3)  visible borders/rings; outlineVariant  hairlines only
  #       accent (≥3 on surfaces, onAccent ≥3)   glyphs, borders, small fills
  #       accentText (≥4.5)                      accent as text, links
  #       selection / onSelection (≥3 / ≥4.5)    selected rows, toggles, fills
  #       focus (= accent)                       the 2 px focus ring
  #       error/warning/success/info (≥4.5 on surface/Low) + onX (≥4.5)
  #       inverseSurface / onInverseSurface (≥7) emphasis by inversion
  #   - contrast-tiered text roles fg/fgDim/fgMuted/fgFaint
  #   - derived opaque mixes: hairline{Soft,,Strong}, tint{5,10,16}
  #   - isDark: whether this is the dark variant
  #   - accentName: a Catppuccin accent name (lookup key for packages that
  #     only accept named colours, e.g. papirus-folders); null if unknown
  #   - noHash: the same attrset with every colour's leading "#" stripped
  # A wallpaper (matugen) palette provides the same keys.
  #
  # `roles` overrides the slot-derived defaults where a Catppuccin slot
  # misses its guarantee. The hex values were produced by the same OKLCH
  # lightness step the runtime generator uses (theme-palette.py `step`), so
  # a Latte lavender stays a lavender, only deep enough to pass.
  mkPalette = {
    slots,
    onAccent,
    isDark,
    accentName ? "lavender",
    roles ? {},
  }: let
    pole =
      if isDark
      then slots.crust
      else slots.base;
    p =
      slots
      // rec {
        accent = slots.${accentName};
        inherit onAccent;
        primary = accent;
        accentText = accent;
        focus = accent;
        selection = accent;
        onSelection = pole;

        error = slots.red;
        warning = slots.peach;
        success = slots.green;
        info = slots.blue;

        # Terminal ANSI 1–6 (text-grade, ≥4.5:1 on surface/Low): the
        # Catppuccin hues; Latte's are stepped in `roles` below.
        ansiRed = slots.red;
        ansiGreen = slots.green;
        ansiYellow = slots.yellow;
        ansiBlue = slots.blue;
        ansiMagenta = slots.pink;
        ansiCyan = slots.teal;
        onError = pole;
        onWarning = pole;
        onSuccess = pole;
        onInfo = pole;

        surface = slots.base;
        surfaceContainerLow = slots.mantle;
        surfaceContainer = slots.surface0;
        surfaceContainerHigh = slots.surface1;
        surfaceContainerHighest = slots.surface2;
        onSurface = slots.text;
        onSurfaceVariant = slots.subtext0;
        outline = slots.overlay1;
        outlineVariant = slots.surface1;
        inverseSurface = slots.text;
        onInverseSurface = slots.base;

        # Text tiers (design targets 12 / 9 / 6.6 / 4.6 : 1 on surface).
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
      }
      // roles;
    final = p // {focus = p.accent;};
  in
    final
    // {
      inherit accentName isDark;
      noHash = builtins.mapAttrs (_: stripHash) final;
    };

  palettes.catppuccin = {
    light = mkPalette {
      slots = catppuccin;
      onAccent = catppuccin.base;
      isDark = false;
      # Latte's mid-tone accents sit at 2.3–3.5:1 on base; stepped deeper.
      roles = {
        accent = "#5768da"; # lavender, L 0.66 → 0.56 (3:1 on base/mantle/surface0)
        accentText = "#4c5bcd"; # lavender, L 0.52 (4.5:1)
        selection = "#5161d4"; # lavender, L 0.54 (4.5:1 against base text)
        fgMuted = "#56586d"; # subtext0, L 0.47 (4.5:1 on surface0)
        outline = catppuccin.overlay2; # 3.5:1 (overlay1 is 2.3:1)
        error = "#ce0436"; # red, 4.46 → 4.5:1
        warning = "#af4816"; # peach, 2.6 → 4.5:1
        success = "#297816"; # green, 3.0 → 4.5:1
        info = "#135cea"; # blue, 4.3 → 4.5:1
        ansiRed = "#ce0436";
        ansiGreen = "#297816";
        ansiYellow = "#925c13"; # yellow 2.3 → 4.9:1
        ansiBlue = "#135cea";
        ansiMagenta = "#a93a8f"; # pink 2.3 → 5:1
        ansiCyan = "#097277"; # teal 3.3 → 5:1
      };
    };
    dark = mkPalette {
      slots = catppuccinMocha;
      onAccent = catppuccinMocha.crust;
      isDark = true;
      # Mocha's pastels pass everywhere; only the hairline needs a step up.
      roles.outline = catppuccinMocha.overlay1; # 3.6:1 (overlay0 is 2.8:1)
    };
  };
in {
  flake = {
    inherit theme themeNoHash catppuccin catppuccinMocha fonts palettes color;
  };
}
