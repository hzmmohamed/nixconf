{self, ...}: {
  flake.nixosModules.wofi = {config, ...}: let
    user = config.preferences.user.name;
    latte = self.catppuccin;
    mocha = self.catppuccinMocha;

    mkWofiCss = cat: ''
      * {
        font-family: 'JetBrainsMono Nerd Font', monospace;
        font-size: 16px;
      }

      window {
        margin: 0px;
        padding: 10px;
        border: 0.16em solid ${cat.lavender};
        border-radius: 0.1em;
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
        border: 0.11em solid ${cat.lavender};
      }

      #entry:selected #text {
        color: ${cat.mauve};
      }

      #entry:drop(active) {
        background-color: ${cat.lavender};
      }
    '';
  in {
    home-manager.users.${user}.home.file = {
      ".config/wofi/style-light.css".text = mkWofiCss latte;
      ".config/wofi/style-dark.css".text = mkWofiCss mocha;
    };
  };
}
