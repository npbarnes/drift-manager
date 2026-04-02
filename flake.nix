{
  description = "Configuration Drift Manager - Safe, mutable dotfiles for Nix";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs =
    {
      self,
      nixpkgs,
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
          pkgs.statix
          pkgs.deadnix
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
              find . -name '*.nix' -exec nixfmt --check {} +
              touch "$out"
            '';

        nix-linting =
          pkgs.runCommand "nix-linting"
            {
              nativeBuildInputs = [
                pkgs.statix
                pkgs.deadnix
              ];
              src = self;
            }
            ''
              cd "$src"
              echo "Linting Nix files..."
              find . -name '*.nix' -print0 | xargs -0 -I {} statix check {}
              find . -name '*.nix' -exec deadnix {} +
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
              find . -name '*.sh' ! -name '*_spec.sh' ! -path './spec/*' -exec shfmt --indent 2 --diff {} +
              touch "$out"
            '';

        shellcheck =
          pkgs.runCommand "shellcheck"
            {
              nativeBuildInputs = [ pkgs.shellcheck ];
              src = self;
            }
            ''
              cd "$src"
              echo "Linting Bash files..."
              find . -name '*.sh' -exec shellcheck {} +
              touch "$out"
            '';
      };
    };
}
