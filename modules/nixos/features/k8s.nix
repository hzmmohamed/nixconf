{...}: {
  flake.nixosModules.k8s = {pkgs, ...}: {
    environment.systemPackages = with pkgs; [
      kubectl
      kubernetes-helm
      kubectx
      k9s
      kind
      stern
      eksctl
    ];
  };
}
