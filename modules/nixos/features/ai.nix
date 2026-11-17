{...}: {
  flake.nixosModules.ai = {
    lib,
    pkgs,
    ...
  }: {
    # Installed but not started at boot; start on demand with
    # `sudo systemctl start ollama` (models in /var/lib/ollama are kept).
    services.ollama = {
      enable = true;
    };
    systemd.services.ollama.wantedBy = lib.mkForce [];

    environment.systemPackages = with pkgs; [
      whisper-cpp
    ];
  };
}
