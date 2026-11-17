{self, ...}: {
  flake.nixosModules.wofi-theme = {...}: let
    mkWofiCss = cat: ''
      * {
        font-family: '${self.fonts.monospace}', monospace;
        font-size: ${toString self.fonts.size}px;
      }

      window {
        margin: 0px;
        padding: 10px;
        border: 1px solid ${cat.outlineVariant};
        border-radius: 8px;
        background-color: ${cat.base};
        animation: slideIn 0.2s ease-in-out both;
      }

      @keyframes slideIn {
        0% { opacity: 0; }
        100% { opacity: 1; }
      }

      #inner-box {
        margin: 5px;
        padding: 10px;
        border: none;
        background-color: ${cat.base};
        animation: fadeIn 0.2s ease-in-out both;
      }

      @keyframes fadeIn {
        0% { opacity: 0; }
        100% { opacity: 1; }
      }

      #outer-box {
        margin: 5px;
        padding: 10px;
        border: none;
        background-color: ${cat.base};
      }

      #scroll {
        margin: 0px;
        padding: 10px;
        border: none;
        background-color: ${cat.base};
      }

      #input {
        margin: 5px 20px;
        padding: 10px;
        border: none;
        border-radius: 0.1em;
        color: ${cat.text};
        background-color: ${cat.base};
        animation: fadeIn 0.5s ease-in-out both;
      }

      #input image {
        border: none;
        color: ${cat.red};
      }

      #text {
        margin: 5px;
        border: none;
        color: ${cat.text};
        animation: fadeIn 0.5s ease-in-out both;
      }

      #entry {
        background-color: ${cat.base};
      }

      #entry arrow {
        border: none;
        color: ${cat.lavender};
      }

      #entry:selected {
        background-color: ${cat.inverseSurface};
        border-radius: 6px;
      }

      #entry:selected #text {
        color: ${cat.onInverseSurface};
      }

      #entry:drop(active) {
        background-color: ${cat.lavender};
      }
    '';
  in {
    # wofi only reads ~/.config/wofi/style.css: link it to the current mode.
    preferences.theme = {
      files."wofi.css" = mkWofiCss;
      links.".config/wofi/style.css" = "wofi.css";
    };
  };
}
