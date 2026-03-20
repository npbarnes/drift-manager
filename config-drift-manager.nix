{ config, lib, pkgs, ... }:

let
  cfg = config.services.configDriftManager;
  syncDir = "${config.xdg.configHome}/nix-drift-manager";
  
  # Filter to only process enabled files (mirroring home.file.<name>.enable)
  enabledFiles = lib.filterAttrs (n: v: v.enable) cfg.file;

  mkFileLogic = name: fileCfg: let
    # Sanitize the name so paths like ".config/app/rc" become ".config-app-rc" for tracking files
    safeName = lib.replaceStrings ["/"] ["-"] name;
    
    # Mirror home.file: target is relative to HOME (unless absolute path is explicitly provided)
    liveFile = if lib.hasPrefix "/" fileCfg.target 
               then fileCfg.target 
               else "${config.home.homeDirectory}/${fileCfg.target}";
               
    # 'source' is now a standard Nix path, just like home.file
    sourcePath = fileCfg.source;
    
    nixGenFile = "${syncDir}/${safeName}.nix-gen";
    appliedFile = "${syncDir}/${safeName}.applied";
    stashedFile = "${syncDir}/${safeName}.drift-stash";
    conflictFlag = "${syncDir}/${safeName}.conflict";
  in {
    inherit name safeName liveFile sourcePath nixGenFile appliedFile stashedFile conflictFlag;
  };

  trackedFiles = lib.mapAttrs (name: fileCfg: mkFileLogic name fileCfg) enabledFiles;

  # --- BASH HELPER FUNCTION ---
  patchHelperFunc = ''
    generate_patch_path() {
      local safe_name="\\$1"
      local patch_dir="\\$2"
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

in {
  options.services.configDriftManager = {
    enable = lib.mkEnableOption "Configuration Drift Manager & Patch Generator";
    
    patchDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/nix-drift-patches";
      description = "Default directory to save generated patch files.";
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
            type = lib.types.path;
            description = "Path of the source file or directory.";
          };
        };
      }));
    };
  };

  config = lib.mkIf cfg.enable {

    # 1. THE ANCHOR
    home.file = lib.mapAttrs' (name: paths: 
      lib.nameValuePair "${syncDir}/${paths.safeName}.nix-gen" { source = paths.sourcePath; }
    ) trackedFiles;

    # 2. ACTIVATION SCRIPT (Fully Verbose Execution Trace Preserved)
    home.activation.driftManagerEnforcer = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      verboseEcho "Ensuring Drift Manager base directory exists at ${syncDir}..."
      run mkdir $VERBOSE_ARG -p ${lib.escapeShellArg syncDir}
      
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: paths: ''
        verboseEcho "--- Processing tracked file: ${name} ---"
        
        verboseEcho "Checking if Nix generation changed or if this is the first run for ${name}..."
        if [ ! -f "${paths.appliedFile}" ] || ! cmp -s "${paths.nixGenFile}" "${paths.appliedFile}"; then
          
          verboseEcho "Nix generation changed (or first run). Checking if a live configuration file already exists..."
          if [ -f "${paths.liveFile}" ]; then
            
            verboseEcho "Live file exists. Checking if it contains configuration drift (manual edits)..."
            if [ ! -f "${paths.appliedFile}" ] || ! cmp -s "${paths.liveFile}" "${paths.appliedFile}"; then
              verboseEcho "Drift detected. Stashing manual edits to ${paths.stashedFile}..."
              run cp $VERBOSE_ARG "${paths.liveFile}" "${paths.stashedFile}"
              
              verboseEcho "Flagging conflict to trigger KDE Negotiator on login..."
              run touch "${paths.conflictFlag}"
            else
              verboseEcho "No drift detected. Live file matches previously applied Nix state."
            fi
          else
            verboseEcho "No existing live file found at ${paths.liveFile}."
          fi
          
          verboseEcho "Applying pure Nix state for ${name}..."
          verboseEcho "Ensuring target directories exist..."
          run mkdir $VERBOSE_ARG -p "$(dirname "${paths.liveFile}")" "$(dirname "${paths.appliedFile}")"
          
          verboseEcho "Copying pure Nix state to live file location..."
          run cp $VERBOSE_ARG "${paths.nixGenFile}" "${paths.liveFile}"
          
          verboseEcho "Updating applied tracking file to reflect current Nix generation..."
          run cp $VERBOSE_ARG "${paths.nixGenFile}" "${paths.appliedFile}"
        else
          verboseEcho "Skipping ${name}: Nix generation unchanged and already applied."
        fi
      '') trackedFiles)}
    '';

    # 3. NEGOTIATOR DAEMON
    systemd.user.paths.nix-drift-negotiator = {
      Unit.Description = "Watch for NixOS Configuration Drift Conflicts";
      Path.PathExistsGlob = "${syncDir}/*.conflict";
      Install.WantedBy = [ "default.target" ];
    };

    systemd.user.services.nix-drift-negotiator = {
      Unit.Description = "NixOS Configuration Drift Negotiator";
      Service.Type = "oneshot";
      Service.ExecStart = pkgs.writeShellScript "nix-drift-negotiator" ''
        sleep 2 
        ${patchHelperFunc}
        
        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: paths: ''
          if [ -f "${paths.conflictFlag}" ] && [ -f "${paths.stashedFile}" ]; then
            CHOICE=$(${pkgs.kdePackages.kdialog}/bin/kdialog --title "Configuration Drift Detected" \
              --combobox "Activation applied a pure Nix generation to ${name}, overwriting configuration drift (manual edits).\nHow would you like to handle your manual edits?" \
              "Reinstate manual edits (Override Nix)" \
              "Save edits as a Git Patch" \
              "Discard manual edits (Keep pure Nix)" \
              --default "Reinstate manual edits (Override Nix)")

            if [ "$CHOICE" = "Reinstate manual edits (Override Nix)" ]; then
              cp "${paths.stashedFile}" "${paths.liveFile}"
              ${pkgs.kdePackages.kdialog}/bin/kdialog --passivepopup "Reinstated manual edits for ${name}." 3
            
            elif [ "$CHOICE" = "Save edits as a Git Patch" ]; then
              PATCH_FILE=$(generate_patch_path "${paths.safeName}" "${cfg.patchDir}")
              # Note: Labels are now natively based on the 'name' (target relative to $HOME)
              diff -u --label "a/${name}" "${paths.appliedFile}" --label "b/${name}" "${paths.stashedFile}" > "$PATCH_FILE" || true
              ${pkgs.kdePackages.kdialog}/bin/kdialog --passivepopup "Saved Git patch to $PATCH_FILE" 5
            
            elif [ "$CHOICE" = "Discard manual edits (Keep pure Nix)" ]; then
              ${pkgs.kdePackages.kdialog}/bin/kdialog --passivepopup "Discarded manual edits for ${name}. System is pure." 3
            fi

            rm -f "${paths.conflictFlag}" "${paths.stashedFile}"
          fi
        '') trackedFiles)}
      '';
    };

    # 4. THE CLI TOOL
    home.packages = [
      (pkgs.writeShellScriptBin "nix-drift" ''
        set -euo pipefail
        ${patchHelperFunc}
        
        COMMAND=''${1:-status}

        case "$COMMAND" in
          status)
            echo "--- Nix Drift Status ---"
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: paths: ''
              if [ -f "${paths.appliedFile}" ] && ! cmp -s "${paths.liveFile}" "${paths.appliedFile}"; then
                echo "DRIFT DETECTED: ${name}"
              fi
            '') trackedFiles)}
            ;;
            
          diff)
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: paths: ''
              if [ -f "${paths.appliedFile}" ] && ! cmp -s "${paths.liveFile}" "${paths.appliedFile}"; then
                echo "--- Drift Diff for ${name} ---"
                diff -u --color=always "${paths.appliedFile}" "${paths.liveFile}" || true
                echo ""
              fi
            '') trackedFiles)}
            ;;
            
          patch)
            DEST_DIR="''${2:-${cfg.patchDir}}"
            COUNT=0
            
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: paths: ''
              if [ -f "${paths.appliedFile}" ] && ! cmp -s "${paths.liveFile}" "${paths.appliedFile}"; then
                PATCH_FILE=$(generate_patch_path "${paths.safeName}" "$DEST_DIR")
                echo "Generating $PATCH_FILE..."
                diff -u --label "a/${name}" "${paths.appliedFile}" --label "b/${name}" "${paths.liveFile}" > "$PATCH_FILE" || true
                COUNT=$((COUNT + 1))
              fi
            '') trackedFiles)}
            
            if [ "$COUNT" -gt 0 ]; then
              echo ""
              echo "Done. Patches saved to $DEST_DIR/"
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