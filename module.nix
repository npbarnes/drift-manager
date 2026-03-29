{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.drift-manager;

  enabledFiles = lib.filterAttrs (n: v: v.enable) cfg.file;

  # --- recursive directory flattening logic ---
  expandFileCfg =
    name: fileCfg:
    let
      # Check if the source is an actual directory that exists at evaluation time
      isDir = builtins.pathExists fileCfg.source && builtins.readFileType fileCfg.source == "directory";
    in
    if isDir then
      let
        # Get all files inside the directory recursively
        allFiles = lib.filesystem.listFilesRecursive fileCfg.source;
        sourceStr = toString fileCfg.source;
      in
      # Convert the list of files into a flattened attribute set
      builtins.listToAttrs (
        map (
          filePath:
          let
            # Extract the relative path (e.g., "init.lua" or "lua/plugins.lua")
            relPath = lib.removePrefix "${sourceStr}/" (toString filePath);
          in
          lib.nameValuePair "${name}/${relPath}" {
            enable = fileCfg.enable;
            target = "${fileCfg.target}/${relPath}";
            source = filePath;
          }
        ) allFiles
      )
    else
      # If it's just a file, return it exactly as-is
      { "${name}" = fileCfg; };

  # Merge all the expanded sets together
  flattenedFiles = lib.foldl' lib.mergeAttrs { } (lib.mapAttrsToList expandFileCfg enabledFiles);
  # ---------------------------------------------------

  mkFileLogic =
    name: fileCfg:
    let
      liveFile =
        if lib.hasPrefix "/" fileCfg.target then
          fileCfg.target
        else
          "${config.home.homeDirectory}/${fileCfg.target}";

      sourcePath = fileCfg.source;

      refFile = "${cfg.referenceDir}/${name}";
      appliedFile = "${cfg.appliedDir}/${name}";
      stashedFile = "${cfg.stashDir}/${name}";
      conflictFlag = "${cfg.conflictDir}/${name}";
      deleteFlag = "${cfg.conflictDir}/${name}";
    in
    {
      inherit
        name
        liveFile
        sourcePath
        refFile
        appliedFile
        stashedFile
        conflictFlag
        ;
    };

  trackedFiles = lib.mapAttrs (name: fileCfg: mkFileLogic name fileCfg) flattenedFiles;

  patchHelperFunc = ''
    generate_patch_path() {
      local safe_name="$1"
      local patch_dir="$2"
      local timestamp=$(date +%Y-%m-%dT%H:%M)

      mkdir -p "$patch_dir"

      local base_name="$patch_dir/nix-drift-"${safe_name}"-"${timestamp}
      local final_name=${base_name}".patch"
      local counter=1

      while [ -e "$final_name" ]; do
        final_name=${base_name}"-"${counter}".patch"
        counter=$((counter + 1))
      done

      echo "$final_name"
    }
  '';

  # GUI toolkit agnostic prompts
  prompt-title = "Configuration Drift Detected";
  prompt = "Activation applied a pure Nix generation to $1.\nHow would you handle manual endits?";
  reinstate-opt = "Reinstate manual edits (Override Nix)";
  patch-opt = "Save edits as a Git patch";
  discard-opt = "Discard manual edits (Keep pure Nix)";
  guiPromptFunc =
    if cfg.dialogTool == "kdialog" then
      ''
        prompt_user() {
          ${pkgs.kdePackages.kdialog}/bin/kdialog --title "${prompt-title}" \
            --combobox "${prompt}" \
            "${reinstate-opt}" "${patch-opt}" "${discard-opt}" \
            --default "${reinstate-opt}"
        }
        notify_user() { ${pkgs.kdePackages.kdialog}/bin/kdialog --passivepopup "$1" 4; }
      ''
    else
      ''
        prompt_user() {
          ${pkgs.zenity}/bin/zenity --list --title="${prompt-title}" \
            --text="${prompt}" \
            --radiolist --column="Select" --column="Action" \
            TRUE "${reinstate-opt}" FALSE "${patch-opt}" FALSE "${discard-opt}"
        }
        notify_user() { ${pkgs.libnotify}/bin/notify-send "Drift Manager" "$1"; }
      '';

in
{
  options.services.drift-manager = {
    enable = lib.mkEnableOption "Configuration Drift Manager & Patch Generator";

    # These directories need to be absolute paths
    # TODO: Validate that these directories are absolute paths
    worksapce = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/.nix-drift-manager";
      description = "Default directory to save internal files used to manage synchonization.";
    };

    referenceDir = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.workspace}/reference";
      description = "Directory where reference files are kept.";
    };

    appliedDir = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.workspace}/activated";
      description = "Directory where files applied this generation are kept.";
    };

    stashDir = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.workspace}/stash";
      description = "Temporary stash location for file changes.";
    };

    archiveDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/configuration-drift-archive";
      description = "A directory to store archived configuration drift.";
    };

    dialogTool = lib.mkOption {
      type = lib.types.enum [
        "kdialog"
        "zenity"
      ];
      default = "kdialog";
      description = "GUI toolkit to use for the conflict resolver.";
    };

    file = lib.mkOption {
      description = "Attribute set of files to manage for configuration drift.";
      default = { };
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
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
          }
        )
      );
    };
  };

  config = lib.mkIf cfg.enable {

    # 1. THE ANCHOR
    home.file = lib.mapAttrs' (
      name: paths: lib.nameValuePair "${referenceDir}/${name}" { source = paths.sourcePath; }
    ) trackedFiles;

    # 2. ACTIVATION SCRIPT
    home.activation.driftManagerEnforcer =
      let
        listToBashArray = list: "(\"" + (lib.concatStrigsSep "\" \"" list) + "\")";
        mapAttrsToBashArray = f: s: listToBashArray (lib.mapAttrsToList f s);
      in
      lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        set -euo pipefail
        source ${./activation.sh}

        STASH_DIR=${cfg.stashDir}
        REF_DIR=${cfg.referenceDir}
        APPLIED_DIR=${cfg.appliedDir}

        REF_FILES=${mapAttrsToBashArray (name: paths: paths.refFile) trackedFiles}
        APPLIED_FILES=${mapAttrsToBashArray (name: paths: paths.appliedFile) trackedFiles}
        LIVE_FILES=${mapAttrsToBashArray (name: paths: paths.liveFile) trackedFiles}

        activate "$STASH_DIR" "$REF_DIR" "$APPLIED_DIR" "$REF_FILES" "$APPLIED_FILES" "$LIVE_FILES"
      '';

    # 3. NEGOTIATOR DAEMON
    systemd.user.paths.nix-drift-negotiator = {
      Unit.Description = "Watch for NixOS Configuration Drift Conflicts";
      Path.PathExistsGlob = "${syncDir}/*.conflict";
      Path.MakeDirectory = true;
      Install.WantedBy = [ "default.target" ];
    };

    systemd.user.services.nix-drift-negotiator = {
      Unit.Description = "NixOS Configuration Drift Negotiator";
      Service.Type = "oneshot";
      Service.ExecStart = pkgs.writeShellScript "nix-drift-negotiator" ''
        export PATH=${
          lib.makeBinPath [
            pkgs.coreutils
            pkgs.diffutils
            pkgs.kdePackages.kdialog
            pkgs.zenity
            pkgs.libnotify
          ]
        }:$PATH

        sleep 2
        ${patchHelperFunc}
        ${guiPromptFunc}

        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (name: paths: ''
            if [ -f ${paths.esc.conflictFlag} ] && [ -f ${paths.esc.stashedFile} ]; then

              CHOICE=$(prompt_user ${paths.esc.name})

              if [ "$CHOICE" = "${reinstate-opt}" ]; then
                cp ${paths.esc.stashedFile} ${paths.esc.liveFile}
                notify_user "Reinstated manual edits for "${paths.esc.name}"."

              elif [ "$CHOICE" = "${patch-opt}" ]; then
                PATCH_FILE=$(generate_patch_path ${paths.esc.name} ${escPatchDir})
                diff -u --label "a/"${paths.esc.name} ${paths.esc.appliedFile} --label "b/"${paths.esc.name} ${paths.esc.stashedFile} > "$PATCH_FILE" || true
                notify_user "Saved Git patch to $PATCH_FILE"

              elif [ "$CHOICE" = "${discard-opt}" ]; then
                notify_user "Discarded manual edits for "${paths.esc.name}". System is pure."
              fi

              rm -f ${paths.esc.conflictFlag} ${paths.esc.stashedFile}
            fi
          '') trackedFiles
        )}
      '';
    };

    # 4. THE CLI TOOL
    home.packages = [
      (pkgs.writeShellScriptBin "nix-drift" ''
        set -euo pipefail
        export PATH=${
          lib.makeBinPath [
            pkgs.coreutils
            pkgs.diffutils
          ]
        }:$PATH

        ${patchHelperFunc}
        COMMAND=''${1:-status}

        case "$COMMAND" in
          status)
            echo "--- Nix Drift Status ---"
            ${lib.concatStringsSep "\n" (
              lib.mapAttrsToList (name: paths: ''
                if [ -f ${paths.esc.appliedFile} ] && ! cmp -s ${paths.esc.liveFile} ${paths.esc.appliedFile}; then
                  echo "DRIFT DETECTED: "${paths.esc.name}
                fi
              '') trackedFiles
            )}
            ;;

          diff)
            ${lib.concatStringsSep "\n" (
              lib.mapAttrsToList (name: paths: ''
                if [ -f ${paths.esc.appliedFile} ] && ! cmp -s ${paths.esc.liveFile} ${paths.esc.appliedFile}; then
                  echo "--- Drift Diff for "${paths.esc.name}" ---"
                  diff -u --color=always ${paths.esc.appliedFile} ${paths.esc.liveFile} || true
                  echo ""
                fi
              '') trackedFiles
            )}
            ;;

          patch)
            # Standard bash variables inside double quotes are natively safe
            DEST_DIR="''${2:-${cfg.patchDir}}"
            COUNT=0

            ${lib.concatStringsSep "\n" (
              lib.mapAttrsToList (name: paths: ''
                if [ -f ${paths.esc.appliedFile} ] && ! cmp -s ${paths.esc.liveFile} ${paths.esc.appliedFile}; then
                  PATCH_FILE=$(generate_patch_path ${paths.esc.name} "$DEST_DIR")
                  echo "Generating $PATCH_FILE..."
                  diff -u --label "a/"${paths.esc.name} ${paths.esc.appliedFile} --label "b/"${paths.esc.name} ${paths.esc.liveFile} > "$PATCH_FILE" || true
                  COUNT=$((COUNT + 1))
                fi
              '') trackedFiles
            )}

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
