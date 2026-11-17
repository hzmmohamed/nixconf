# Design tokens: every non-colour number a themed module uses (spacing, radii,
# borders, type, motion, state rules). Flake-level data, read as `self.design`
# next to the palette (`config.preferences.theme.palette`, modules/theme.nix).
# Reference: docs/plans/2026-11-17-design-system.md, section 2.
#
# Rules of thumb for consumers:
#   - spacing and sizes come from `space` (4 px base; 2 px for hairline gaps)
#   - controls (buttons, bar items, list rows, chips) use radius.control,
#     panels (popups, notifications, launcher, tooltips, OSD) radius.panel
#   - elevation without shadows: a panel is `surface` + border.hairline in
#     `outlineVariant`; a raised card inside it is `surfaceContainerLow`
#   - hover = tint10, pressed = tint16, active/selected = selection with
#     onSelection text, focus = border.focus in `focus`, disabled = fgFaint
#   - motion is functional only: motion.fast for state tints, motion.base for
#     reveals (drawers, popups), motion.slow for the wallpaper/mode cross-fade
{self, ...}: let
  space = {
    xs = 2;
    sm = 4;
    md = 8;
    lg = 12;
    xl = 16;
    xxl = 24;
    xxxl = 32;
  };

  radius = {
    none = 0;
    control = 6;
    panel = 8;
    pill = 999;
  };

  border = {
    hairline = 1;
    focus = 2;
  };

  type = {
    family = {
      ui = self.fonts.sansSerif; # Inter: UI text, tabular numerals via fontconfig
      mono = self.fonts.monospace; # terminal and literal data
      # Nerd Font "Propo" variant: proportional, so bar glyphs are centred
      # and never clipped.
      glyph = "${self.fonts.monospace} Propo";
    };
    # px. Arabic (Noto Sans Arabic fallback) needs body >= 12 and a line
    # height >= 1.4 to keep its ascenders and marks legible.
    size = {
      caption = 11; # values under bar glyphs, timestamps, hints
      body = 12; # everything else
      title = 15; # panel titles (notification centre, launcher sections)
      glyph = 16; # bar and OSD icons
      display = 32; # lock-screen clock
    };
    weight = {
      regular = 400;
      medium = 500;
      bold = 700;
    };
    lineHeight = {
      tight = 1.2;
      body = 1.4;
    };
  };

  # Durations in ms. 0 where a reveal would only draw attention.
  motion = {
    fast = 90;
    base = 170;
    slow = 210;
  };

  # Composite tokens: what the surfaces share.
  bar = {
    edgePadding = space.md; # above the first / below the last item
    itemPaddingY = space.sm; # glyph box: 16 px glyph + 2 * 4 px = 24 px tall
    itemMarginX = space.sm;
    itemMarginY = space.xs; # 28 px pitch between glyph boxes
    radius = radius.control;
    rule = border.hairline; # the bar's inner edge
    traySpacing = space.md;
  };

  window = {
    gap = space.md; # sway inner gaps; the bar's outer margin matches
    border = border.focus;
  };

  panel = {
    padding = space.lg;
    margin = space.md; # distance from the screen edge / the bar
    gap = space.sm; # between actions, rows
    border = border.hairline;
    radius = radius.panel;
  };

  # The ink is a rule, not a fill: the lock ring and the OSD level bar are
  # thin lines (space.sm), like the 2 px focus ring scaled for distance.
  lock = {
    ringRadius = 120;
    ringThickness = space.sm;
  };

  osd = {
    margin = space.xl;
    barHeight = space.sm;
    width = 320;
  };
in {
  flake.design = {
    inherit space radius border type motion bar window panel lock osd;
  };
}
