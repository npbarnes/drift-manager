{ config, lib, pkgs, ... }:

let
  cfg = config.services.configDriftManager;
  syncDir = "${config.xdg.configHome}/nix-drift-manager";
  
  enabledFiles = lib.filterAttrs (n: v: v.enable) cfg.file;

  mkFileLogic = name: fileCfg: let
    # FIX 2.1: Add a hash to prevent collisions between "a/b" and "a-b"
    nameHash = builtins.substring 0 8 (builtins.hashString "sha256" name);
    safeName = "${lib.replaceStrings ["/"] ["-"] name}-${nameHash}";
    
    liveFile = if lib.hasPrefix "/" fileCfg.target 
               then fileCfg.target 
               else "${config.home.homeDirectory}/${fileCfg.target}";
               
    sourcePath = fileCfg.source;
    
    nixGenFile = "${syncDir}/${safeName}.nix-gen";
    appliedFile = "${syncDir}/${safeName}.applied";
    stashedFile = "${syncDir}/${safeName}.drift-stash";
    conflictFlag = "${syncDir}/${safeName}.conflict";
  in {
    inherit name safeName liveFile sourcePath nixGenFile appliedFile stashedFile conflictFlag;
  };

  trackedFiles = lib.mapAttrs (name: fileCfg: mkFileLogic name fileCfg) enabledFiles;

  # FIX 1.2: Removed bad escaping. Added proper variable names.
  patchHelperFunc = ''
    generate_patch_path() {
      local safe_name="$1"
      local patch_dir="$2"
      local timestamp=$(date +%Y-%m-%dT%H:%M)
      
      mkdir -p "$patch_dir"

      local base_name="$patch_dir/nix-drift-''${safe_name}-''${timestamp}"
      local final_name="''${base_name}.patch"
      local counter=1

      while [ -e "$final_name" ]; do
        final_name="''${base_name}-''${counter}.patch"
        counter=$((counter + 1))
      done

      echo "$final_name"
    }
  '';

  # FIX 3.2: Allow standardizing on kdialog or zenity
  guiPromptFunc = if cfg.dialogTool == "kdialog" then ''
    prompt_user() {
      ${pkgs.kdePackages.kdialog}/bin/kdialog --title "Configuration Drift Detected" \
        --combobox "Activation applied a pure Nix generation to \$1.\nHow would you handle manual edits?" \
        "Reinstate manual edits (Override Nix)" "Save edits as a Git Patch" "Discard manual edits (Keep pure Nix)" \
        --default "Reinstate manual edits (Override Nix)"
    }
    notify_user() { ${pkgs.kdePackages.kdialog}/bin/kdialog --passivepopup "\$1" 4; }
  '' else ''
    prompt_user() {
      ${pkgs.zenity}/bin/zenity --list --title="Configuration Drift Detected" \
        --text="Activation applied a pure Nix generation to \$1.\nHow would you handle manual edits?" \
        --radiolist --column="Select" --column="Action" \
        TRUE "Reinstate manual edits (Override Nix)" FALSE "Save edits as a Git Patch" FALSE "Discard manual edits (Keep pure Nix)"
    }
    notify_user() { ${pkgs.libnotify}/bin/notify-send "Drift Manager" "\$1"; }
  '';

in {
  options.services.configDriftManager = {
    enable = lib.mkEnableOption "Configuration Drift Manager & Patch Generator";
    
    patchDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/nix-drift-patches";
      description = "Default directory to save generated patch files.";
    };

    dialogTool = lib.mkOption {
      type = lib.types.enum [ "kdialog" "zenity" ];
      default = "kdialog";
      description = "GUI toolkit to use for the conflict resolver.";
    };

    file = lib.mkOption {
      description = "Attribute set of files to manage for configuration drift.";
      default = {};
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Whether this file should be tracked for drift.";
          };
          target = lib.mkOption {
            type = lib.types.str;
            default = name;
            description = "Path to target file relative to HOME.";
          };
          source = lib.mkOption {
            type = lib.types.path; # TODO: Ensure users only pass files, not directories!
            description = "Path of the source file or directory.";
          };
        };
      }));
    };
  };

  config = lib.mkIf cfg.enable {

    home.file = lib.mapAttrs' (name: paths: 
      lib.nameValuePair "${syncDir}/${paths.safeName}.nix-gen" { source = paths.sourcePath; }
    ) trackedFiles;

    home.activation.driftManagerEnforcer = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      verboseEcho "Ensuring Drift Manager base directory exists at ${syncDir}..."
      run mkdir $VERBOSE_ARG -p ${lib.escapeShellArg syncDir}
      
      # FIX: Ensure we have access to coreutils and diffutils
      export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.diffutils ]}:$PATH
      
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: paths: ''
        verboseEcho "--- Processing tracked file: ${name} ---"
        
        verboseEcho "Checking if Nix generation changed or if this is the first run for ${name}..."
        if [ ! -f ${lib.escapeShellArg paths.appliedFile} ] || ! cmp -s ${lib.escapeShellArg paths.nixGenFile} ${lib.escapeShellArg paths.appliedFile}; then
          
          verboseEcho "Nix generation changed (or first run). Checking if a live configuration file already exists..."
          if [ -f ${lib.escapeShellArg paths.liveFile} ]; then
            
            verboseEcho "Live file exists. Checking if it contains configuration drift (manual edits)..."
            if [ ! -f ${lib.escapeShellArg paths.appliedFile} ] || ! cmp -s ${lib.escapeShellArg paths.liveFile} ${lib.escapeShellArg paths.appliedFile}; then
              verboseEcho "Drift detected. Stashing manual edits to ${paths.stashedFile}..."
              run cp $VERBOSE_ARG ${lib.escapeShellArg paths.liveFile} ${lib.escapeShellArg paths.stashedFile}
              
              verboseEcho "Flagging conflict to trigger GUI Negotiator..."
              run touch ${lib.escapeShellArg paths.conflictFlag}
            else
              verboseEcho "No drift detected. Live file matches previously applied Nix state."
            fi
          else
            verboseEcho "No existing live file found at ${paths.liveFile}."
          fi
          
          verboseEcho "Applying pure Nix state for ${name}..."
          verboseEcho "Ensuring target directories exist..."
          run mkdir $VERBOSE_ARG -p "$(dirname ${lib.escapeShellArg paths.liveFile})" "$(dirname ${lib.escapeShellArg paths.appliedFile})"
          
          verboseEcho "Copying pure Nix state to live file location..."
          run cp $VERBOSE_ARG ${lib.escapeShellArg paths.nixGenFile} ${lib.escapeShellArg paths.liveFile}
          
          verboseEcho "Making the live file writable so manual edits are permitted..."
          run chmod $VERBOSE_ARG u+w ${lib.escapeShellArg paths.liveFile}
          
          verboseEcho "Updating applied tracking file to reflect current Nix generation..."
          run cp $VERBOSE_ARG ${lib.escapeShellArg paths.nixGenFile} ${lib.escapeShellArg paths.appliedFile}
        else
          verboseEcho "Skipping ${name}: Nix generation unchanged and already applied."
        fi
      '') trackedFiles)}
    '';

    systemd.user.paths.nix-drift-negotiator = {
      Unit.Description = "Watch for NixOS Configuration Drift Conflicts";
      Path.PathExistsGlob = "${syncDir}/*.conflict";
      Path.MakeDirectory = true; # FIX 2.3: Prevents service start failure if syncDir is missing
      Install.WantedBy = [ "default.target" ];
    };

    systemd.user.services.nix-drift-negotiator = {
      Unit.Description = "NixOS Configuration Drift Negotiator";
      Service.Type = "oneshot";
      Service.ExecStart = pkgs.writeShellScript "nix-drift-negotiator" ''
        # FIX 1.3: Inject dependencies securely
        export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.diffutils pkgs.kdePackages.kdialog pkgs.zenity pkgs.libnotify ]}:$PATH
        
        sleep 2 
        ${patchHelperFunc}
        ${guiPromptFunc}
        
        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: paths: ''
          # Only process if this specific conflict flag exists
          if [ -f ${lib.escapeShellArg paths.conflictFlag} ] && [ -f ${lib.escapeShellArg paths.stashedFile} ]; then
            
            CHOICE=$(prompt_user ${lib.escapeShellArg name})

            if [ "$CHOICE" = "Reinstate manual edits (Override Nix)" ]; then
              cp ${lib.escapeShellArg paths.stashedFile} ${lib.escapeShellArg paths.liveFile}
              notify_user "Reinstated manual edits for ${name}."
            
            elif [ "$CHOICE" = "Save edits as a Git Patch" ]; then
              PATCH_FILE=$(generate_patch_path ${lib.escapeShellArg paths.safeName} ${lib.escapeShellArg cfg.patchDir})
              diff -u --label "a/${name}" ${lib.escapeShellArg paths.appliedFile} --label "b/${name}" ${lib.escapeShellArg paths.stashedFile} > "$PATCH_FILE" || true
              notify_user "Saved Git patch to $PATCH_FILE"
            
            elif [ "$CHOICE" = "Discard manual edits (Keep pure Nix)" ]; then
              notify_user "Discarded manual edits for ${name}. System is pure."
            fi

            rm -f ${lib.escapeShellArg paths.conflictFlag} ${lib.escapeShellArg paths.stashedFile}
          fi
        '') trackedFiles)}
      '';
    };

    home.packages = [
      (pkgs.writeShellScriptBin "nix-drift" ''
        set -euo pipefail
        # FIX 1.3: Inject coreutils/diffutils
        export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.diffutils ]}:$PATH

        ${patchHelperFunc}
        COMMAND=''${1:-status}

        case "$COMMAND" in
          status)
            echo "--- Nix Drift Status ---"
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: paths: ''
              if [ -f ${lib.escapeShellArg paths.appliedFile} ] && ! cmp -s ${lib.escapeShellArg paths.liveFile} ${lib.escapeShellArg paths.appliedFile}; then
                echo "DRIFT DETECTED: ${name}"
              fi
            '') trackedFiles)}
            ;;
            
          diff)
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: paths: ''
              if [ -f ${lib.escapeShellArg paths.appliedFile} ] && ! cmp -s ${lib.escapeShellArg paths.liveFile} ${lib.escapeShellArg paths.appliedFile}; then
                echo "--- Drift Diff for ${name} ---"
                diff -u --color=always ${lib.escapeShellArg paths.appliedFile} ${lib.escapeShellArg paths.liveFile} || true
                echo ""
              fi
            '') trackedFiles)}
            ;;
            
          patch)
            DEST_DIR="''${2:-${cfg.patchDir}}"
            COUNT=0
            
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: paths: ''
              if [ -f ${lib.escapeShellArg paths.appliedFile} ] && ! cmp -s ${lib.escapeShellArg paths.liveFile} ${lib.escapeShellArg paths.appliedFile}; then
                PATCH_FILE=$(generate_patch_path ${lib.escapeShellArg paths.safeName} "$DEST_DIR")
                echo "Generating $PATCH_FILE..."
                diff -u --label "a/${name}" ${lib.escapeShellArg paths.appliedFile} --label "b/${name}" ${lib.escapeShellArg paths.liveFile} > "$PATCH_FILE" || true
                COUNT=$((COUNT + 1))
              fi
            '') trackedFiles)}
            
            if [ "$COUNT" -gt 0 ]; then
              echo -e "\nDone. Patches saved to $DEST_DIR/"
              echo "Use 'git apply' or your preferred patch tool to merge these into your config."
            else
              echo "No configuration drift found."
            fi
            ;;
            
          *)
            echo "Usage: nix-drift [status|diff|patch [output-dir]]"
            exit 1
            ;;
        esac
      '')
    ];
  };
}