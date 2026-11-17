{self, ...}: {
  flake.nixosModules.wofi-theme = {...}: let
    d = self.design;
    px = n: "${toString n}px";

    # The shared panel: surface, hairline border, panel radius, no shadow;
    # the chosen row by inversion; no fades (motion only where functional).
    mkWofiCss = cat: ''
      * {
        font-family: '${d.type.family.ui}';
        font-size: ${px d.type.size.body};
      }

      window {
        margin: 0;
        padding: ${px d.space.sm};
        border: ${px d.panel.border} solid ${cat.outlineVariant};
        border-radius: ${px d.panel.radius};
        background-color: ${cat.surface};
      }

      #inner-box, #outer-box, #scroll {
        margin: 0;
        padding: ${px d.space.sm};
        border: none;
        background-color: ${cat.surface};
      }

      #input {
        margin: ${px d.space.sm};
        padding: ${px d.space.md} ${px d.space.lg};
        border: ${px d.border.hairline} solid ${cat.outlineVariant};
        border-radius: ${px d.radius.control};
        color: ${cat.fg};
        background-color: ${cat.surfaceContainerLow};
      }
      #input:focus { border-color: ${cat.focus}; }
      #input image { border: none; color: ${cat.fgMuted}; }

      #text {
        margin: ${px d.space.xs} ${px d.space.md};
        border: none;
        color: ${cat.fg};
      }

      #entry {
        padding: ${px d.space.sm} ${px d.space.md};
        border-radius: ${px d.radius.control};
        background-color: ${cat.surface};
      }
      #entry arrow { border: none; color: ${cat.accentText}; }
      #entry:selected { background-color: ${cat.inverseSurface}; }
      #entry:selected #text { color: ${cat.onInverseSurface}; }
      #entry:drop(active) { background-color: ${cat.selection}; }
      #entry:drop(active) #text { color: ${cat.onSelection}; }
    '';
  in {
    # wofi only reads ~/.config/wofi/style.css: link it to the current mode.
    preferences.theme = {
      files."wofi.css" = mkWofiCss;
      links.".config/wofi/style.css" = "wofi.css";
    };
  };
}
