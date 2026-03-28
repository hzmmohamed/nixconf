{inputs, self, ...}: {
  perSystem = {pkgs, ...}: {
    packages.git = inputs.wrappers.lib.wrapPackage {
      inherit pkgs;
      package = pkgs.git;
      runtimeInputs = [
        pkgs.delta
        pkgs.git-lfs
      ];
      env = rec {
        GIT_AUTHOR_NAME = self.user.name;
        GIT_AUTHOR_EMAIL = "hzmmohamed@gmail.com";
        GIT_COMMITTER_NAME = GIT_AUTHOR_NAME;
        GIT_COMMITTER_EMAIL = GIT_AUTHOR_EMAIL;
      };
      flags = {
        "-c" = [
          "init.defaultBranch=main"
          "pull.rebase=true"
          "push.autoSetupRemote=true"
          "core.pager=delta"
          "interactive.diffFilter=delta --color-only"
          "delta.navigate=true"
          "delta.line-numbers=true"
          "delta.syntax-theme=GitHub"
          "merge.conflictstyle=diff3"
          "diff.colorMoved=default"
          "safe.directory=*"
        ];
      };
    };
  };
}
