{...}: {
  flake.nixosModules.wofi-emoji = {pkgs, ...}: let
    # Extract the emoji dataset from wofi-emoji at build time.
    # The upstream script embeds data after a "### DATA ###" marker;
    # extracting it avoids a runtime buffer overflow from sed on the large script.
    emojiData = pkgs.runCommand "emoji-data" {} ''
      sed '1,/^### DATA ###$/d' ${pkgs.wofi-emoji}/bin/wofi-emoji > $out
    '';

    emojiOverride = pkgs.writeText "wofi-emoji-override.css" ''
      * {
        font-size: 24px;
      }
    '';

    # Custom wrapper that merges the current wofi theme (managed by darkman
    # via ~/.config/wofi/style.css symlink) with a larger font override,
    # then types + copies the selected emoji.
    wofi-emoji-styled = pkgs.writeShellScriptBin "wofi-emoji" ''
      STYLE="$HOME/.config/wofi/style.css"
      COMBINED=$(${pkgs.coreutils}/bin/mktemp)
      trap '${pkgs.coreutils}/bin/rm -f "$COMBINED"' EXIT

      if [ -f "$STYLE" ]; then
        ${pkgs.coreutils}/bin/cat "$STYLE" ${emojiOverride} > "$COMBINED"
      else
        ${pkgs.coreutils}/bin/cat ${emojiOverride} > "$COMBINED"
      fi

      EMOJI="$(${pkgs.wofi}/bin/wofi -p "emoji" --show dmenu -i \
        --style "$COMBINED" \
        --columns 1 \
        < ${emojiData} \
        | cut -d ' ' -f 1 | tr -d '\n')"
      [ -n "$EMOJI" ] && ${pkgs.wtype}/bin/wtype "$EMOJI" && ${pkgs.wl-clipboard}/bin/wl-copy "$EMOJI"
    '';
  in {
    environment.systemPackages = [wofi-emoji-styled];
  };
}
