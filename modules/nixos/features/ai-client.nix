{...}: {
  flake.nixosModules.ai-client = {pkgs, ...}: {
    programs.firefox.policies.ManagedBookmarks = [
      {toplevel_name = "AI";}
      {
        name = "LibreChat";
        url = "http://peacelily:3080";
      }
      {
        name = "llama-swap";
        url = "http://peacelily:9292";
      }
      {
        name = "Qdrant";
        url = "http://peacelily:6333/dashboard";
      }
    ];

    environment.systemPackages = with pkgs; [
      whisper-cpp
    ];
  };
}
