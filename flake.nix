{
  description = "Config Drift Manager - Safe, mutable dotfiles for Nix";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager }: {
    
    # 1. Export the module so users can import it in their flake.nix
    homeManagerModules.default = import ./module.nix;

    # 2. Define the Test Suite
    checks.x86_64-linux.default = let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
    in pkgs.testers.runNixOSTest {
      name = "config-drift-manager-test";

      nodes.machine = { config, pkgs, ... }: {
        imports = [ home-manager.nixosModules.home-manager ];

        # Setup a test user
        users.users.alice = {
          isNormalUser = true;
          home = "/home/alice";
        };

        # -----------------------------------------------------------------
        # GENERATION 1: The Initial Baseline Configuration
        # -----------------------------------------------------------------
        home-manager.users.alice = {
          imports = [ self.homeManagerModules.default ];
          home.stateVersion = "23.11";
          
          services.configDriftManager.enable = true;
          services.configDriftManager.file = {
            # Single file test
            "bashrc".source = pkgs.writeText "b1" "NIX_STATE_V1";
            
            # Weird filename test (escaping validation)
            "weird \"name\" with $paces.txt".source = pkgs.writeText "w1" "NIX_STATE_V1";
            
            # Recursive directory expansion test
            "my-dir".source = ./fixtures/test-dir;
          };
        };

        # -----------------------------------------------------------------
        # GENERATION 2: A NixOS "Specialisation" to simulate a Rebuild
        # -----------------------------------------------------------------
        specialisation.gen2.configuration = {
          home-manager.users.alice = {
            services.configDriftManager.file = {
              "bashrc".source = pkgs.writeText "b2" "NIX_STATE_V2";
              "weird \"name\" with $paces.txt".source = pkgs.writeText "w2" "NIX_STATE_V2";
              "my-dir".source = ./fixtures/test-dir;
            };
          };
        };
      };

      # -----------------------------------------------------------------
      # THE TEST SCRIPT (Runs sequentially inside the VM)
      # -----------------------------------------------------------------
      testScript = ''
        machine.wait_for_unit("multi-user.target")
        sync_dir = "/home/alice/.config/nix-drift-manager"

        with subtest("Step 1: First Run Deployment & Writable Permissions"):
            # Start a user session to ensure systemd --user starts
            machine.succeed("loginctl enable-linger alice")
            machine.wait_for_unit("user@1000.service")

            # Verify pure Nix state was applied
            machine.succeed("su - alice -c 'grep NIX_STATE_V1 /home/alice/bashrc'")
            
            # Verify file is WRITABLE (Requirement 1.2)
            machine.succeed("su - alice -c 'test -w /home/alice/bashrc'")
            machine.succeed("su - alice -c 'test -w \"/home/alice/weird \\\"name\\\" with \\$paces.txt\"'")

        with subtest("Step 2: Recursive Directory Expansion"):
            # Verify the module recursively expanded the fixture directory
            machine.succeed("su - alice -c 'test -f /home/alice/my-dir/fileA.txt'")
            machine.succeed("su - alice -c 'test -f /home/alice/my-dir/sub/fileB.txt'")

        with subtest("Step 3: User Manual Edits (Configuration Drift)"):
            # Simulate the user opening their editor and making changes
            machine.succeed("su - alice -c 'echo \"USER_DRIFT\" > /home/alice/bashrc'")
            machine.succeed("su - alice -c 'echo \"WEIRD_DRIFT\" > \"/home/alice/weird \\\"name\\\" with \\$paces.txt\"'")

        with subtest("Step 4: Activate Generation 2 (Nixos-rebuild switch)"):
            # Trigger activation script for generation 2
            machine.succeed("/run/current-system/specialisation/gen2/bin/switch-to-configuration test")

        with subtest("Step 5: Verify Pure Nix State Enforced"):
            # Ensure the live files were overwritten unconditionally
            machine.succeed("su - alice -c 'grep NIX_STATE_V2 /home/alice/bashrc'")

        with subtest("Step 6: Verify Drift Stashing and Systemd Path Unit"):
            # Check that the stashed file contains the user's manual edits
            machine.succeed(f"su - alice -c 'grep USER_DRIFT {sync_dir}/*bashrc*.drift-stash'")
            
            # Verify the .conflict flag was created
            machine.succeed(f"su - alice -c 'ls {sync_dir}/*bashrc*.conflict'")
            
            # Verify the systemd path watcher is active and detected the conflict
            machine.succeed("su - alice -c 'systemctl --user is-active nix-drift-negotiator.path'")

        with subtest("Step 7: CLI Tool and Patch Generation"):
            # Test 'nix-drift status'
            out = machine.succeed("su - alice -c 'nix-drift status'")
            assert "DRIFT DETECTED: bashrc" in out, "Status did not detect bashrc drift"
            
            # Generate the patches
            machine.succeed("su - alice -c 'nix-drift patch /home/alice/patches'")
            
            # Verify git-compatible labels (a/ and b/) were safely generated
            machine.succeed("su - alice -c 'grep \"--- a/bashrc\" /home/alice/patches/*.patch'")
            machine.succeed("su - alice -c 'grep \"+++ b/bashrc\" /home/alice/patches/*.patch'")
            
            # Verify extreme filename escaping worked in the patch diff
            machine.succeed("su - alice -c 'grep \"--- a/weird \\\"name\\\" with \\$paces.txt\" /home/alice/patches/*.patch'")
            machine.succeed("su - alice -c 'grep \"+WEIRD_DRIFT\" /home/alice/patches/*.patch'")
      '';
    };
  };
}