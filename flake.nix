{
  description = "Configuration Drift Manager - Safe, mutable dotfiles for Nix";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      homeModules.default = import ./module.nix;

      devShells.${system}.default = pkgs.mkShell {
        packages = [
          pkgs.shfmt
          pkgs.shellcheck
          pkgs.shellspec
          pkgs.nixfmt
          pkgs.nixfmt-tree
        ];
      };

      checks.x86_64-linux = {
        nixfmt =
          pkgs.runCommand "check-nixfmt"
            {
              nativeBuildInputs = [ pkgs.nixfmt ];
              src = self;
            }
            ''
              cd "$src"
              echo "Checking Nix formatting..."
              find . -name '*.nix' -print0 | xargs -0 nixfmt --check
              touch "$out"
            '';

        shfmt =
          pkgs.runCommand "check-shfmt"
            {
              nativeBuildInputs = [ pkgs.shfmt ];
              src = self;
            }
            ''
              cd "$src"
              echo "Checking Bash formatting..."
              find . -name '*.sh' -print0 | xargs -0 shfmt --indent 4 --diff
              touch "$out"
            '';
      };
    };
}
