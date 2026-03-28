{inputs, self, ...}: {
  perSystem = {pkgs, ...}: {
    packages.git = inputs.wrappers.lib.wrapPackage {
      inherit pkgs;
      package = pkgs.git;
      env = rec {
        GIT_AUTHOR_NAME = self.user.name;
        GIT_AUTHOR_EMAIL = "hzmmohamed@gmail.com";
        GIT_COMMITTER_NAME = GIT_AUTHOR_NAME;
        GIT_COMMITTER_EMAIL = GIT_AUTHOR_EMAIL;
      };
    };
  };
}
