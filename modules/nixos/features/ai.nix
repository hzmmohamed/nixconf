{...}: {
  flake.nixosModules.ai = {pkgs, ...}: {
    services.ollama = {
      enable = true;
    };

    environment.systemPackages = with pkgs; [
      whisper-cpp
    ];
  };
}
