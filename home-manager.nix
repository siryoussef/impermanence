{ pkgs, config, lib, ... }:

let
  inherit (lib)
    mkOption
    types
    catAttrs
    any
    filter
    attrNames
    attrValues
    foldl'
    recursiveUpdate
    concatMapStrings
    escapeShellArg
    mapAttrsToList
    mkMerge
    mkIf
    optional
    optionalString
    makeBinPath
    versionAtLeast
    ;

  inherit (config) home;

  cfg = config.home.persistence;

  persistentStorageNames = (filter (path: cfg.${path}.enable) (attrNames cfg));

  inherit (pkgs.callPackage ./lib.nix { })
    concatPaths
    splitPath
    dirListToPath
    getPersistentPath
    ;

  # V1-style unmount script for standalone/activation logic
  mount = "${pkgs.util-linux}/bin/mount";
  unmountScript = mountPoint: tries: sleep: ''
    triesLeft=${toString tries}
    if ${mount} | grep -F ${mountPoint}' ' >/dev/null; then
        while (( triesLeft > 0 )); do
            if fusermount -u ${mountPoint}; then
                break
            else
                (( triesLeft-- ))
                if (( triesLeft == 0 )); then
                    echo "Couldn't perform regular unmount of ${mountPoint}. Attempting lazy unmount."
                    fusermount -uz ${mountPoint}
                else
                    sleep ${toString sleep}
                fi
            fi
        done
    fi
  '';

in
{
  options = {
    home.persistence = mkOption {
      default = { };
      type = types.attrsOf (
        types.submodule ({ name, config, ... }:
          import ./submodule-options.nix {
            inherit pkgs lib name config;
            user = home.username;
            homeDir = home.homeDirectory;
            group = null;
          }
        ));
    };
  };

  config = {
    # 1. STANDALONE SYMLINKS (From V1)
    # Even on NixOS, it is often safer to let Home Manager handle symlinks
    # so that 'mkOutOfStoreSymlink' works correctly with Home Manager's tracking.
    home.file =
      let
        mkLinkNameValuePair = persistentStorageName: fileOrDir: {
          name = lib.removePrefix "/" (lib.removePrefix home.homeDirectory
            (if cfg.${persistentStorageName}.removePrefixDirectory then
              # Use the new shared logic for flattening if requested
              getPersistentPath { 
                persistentStoragePath = ""; 
                dirPath = fileOrDir; 
                removePrefixDirectory = true; 
                home = home.homeDirectory; 
              }
            else
              fileOrDir)
          );
          value = {
            source = config.lib.file.mkOutOfStoreSymlink (getPersistentPath {
              persistentStoragePath = cfg.${persistentStorageName}.persistentStoragePath;
              dirPath = fileOrDir;
              removePrefixDirectory = cfg.${persistentStorageName}.removePrefixDirectory;
              home = home.homeDirectory;
            });
          };
        };

        mkLinksToPersistentStorage = persistentStorageName:
          builtins.listToAttrs (map
            (mkLinkNameValuePair persistentStorageName)
            (cfg.${persistentStorageName}.files ++ (map (v: v.directory)
              (filter (v: v.method == "symlink") cfg.${persistentStorageName}.directories)))
          );
      in
      foldl' recursiveUpdate { } (map mkLinksToPersistentStorage persistentStorageNames);

    # 2. STANDALONE BIND MOUNTS (From V1, but modernised)
    # These only activate if we aren't using the NixOS system-level mounts.
    systemd.user.services =
      let
        mkBindMountService = persistentStorageName: dirConfig:
          let
            dir = dirConfig.directory;
            targetDir = getPersistentPath {
              persistentStoragePath = cfg.${persistentStorageName}.persistentStoragePath;
              dirPath = dir;
              removePrefixDirectory = cfg.${persistentStorageName}.removePrefixDirectory;
              home = home.homeDirectory;
            };
            relPath = lib.removePrefix "/" (lib.removePrefix home.homeDirectory dir);
            mountPoint = concatPaths [ home.homeDirectory relPath ];
            
            # Use targetDir as the name for the service
            name = "bindMount-${lib.replaceStrings ["/"] ["-"] (lib.removePrefix "/" targetDir)}";
            
            bindfsOptions = lib.concatStringsSep "," (
              optional (!cfg.${persistentStorageName}.allowOther) "no-allow-other"
              ++ optional dirConfig.hideMount "x-gvfs-hide"
              ++ optional dirConfig.allowTrash "x-gvfs-trash"
              ++ optional (versionAtLeast pkgs.bindfs.version "1.14.9") "fsname=${targetDir}"
            );
            bindfsOptionFlag = optionalString (bindfsOptions != "") (" -o " + bindfsOptions);
            bindfs = "${pkgs.bindfs}/bin/bindfs" + bindfsOptionFlag;
            
            startScript = pkgs.writeShellScript name ''
              set -eu
              if ! mount | grep -F ${escapeShellArg mountPoint}' ' && ! mount | grep -F ${escapeShellArg mountPoint}/; then
                  mkdir -p ${escapeShellArg mountPoint}
                  exec ${bindfs} ${escapeShellArg targetDir} ${escapeShellArg mountPoint}
              else
                  echo "There is already an active mount at or below ${mountPoint}!" >&2
                  exit 0
              fi
            '';
            stopScript = pkgs.writeShellScript "unmount-${name}" ''
              set -eu
              ${unmountScript (escapeShellArg mountPoint) 6 5}
            '';
          in
          {
            inherit name;
            value = {
              Unit = {
                Description = "Bind mount ${targetDir} at ${mountPoint}";
                X-RestartIfChanged = false;
                DefaultDependencies = false;
                Before = [ "basic.target" "default.target" ];
              };
              Install.WantedBy = [ "default.target" ];
              Service = {
                Type = "forking";
                ExecStart = "${startScript}";
                ExecStop = "${stopScript}";
                Environment = "PATH=${makeBinPath [ pkgs.coreutils pkgs.util-linux pkgs.gnugrep pkgs.bindfs ]}:/run/wrappers/bin";
              };
            };
          };

        mkBindMountServicesForPath = persistentStorageName:
          lib.listToAttrs (map
            (dirConfig: (mkBindMountService persistentStorageName dirConfig))
            (filter (d: d.method == "bindfs") cfg.${persistentStorageName}.directories)
          );
      in
      # Only generate these if we are NOT on NixOS (or if the user explicitly wants HM-level bindfs)
      # For your system, NixOS handles this with higher performance Systemd mounts.
      mkIf (!config.lib.impermanence.isNixos or false) (
        foldl' recursiveUpdate { } (map mkBindMountServicesForPath persistentStorageNames)
      );

    # 3. DIRECTORY PRE-CREATION (From V1)
    home.activation = {
      createTargetFileDirectories =
        let
          dag = config.lib.dag;
        in
        dag.entryBefore [ "writeBoundary" ] (concatMapStrings
          (persistentStorageName:
            concatMapStrings
              (targetFilePath: ''
                mkdir -p ${escapeShellArg (getPersistentPath {
                  persistentStoragePath = cfg.${persistentStorageName}.persistentStoragePath;
                  dirPath = (lib.dirOf targetFilePath);
                  removePrefixDirectory = cfg.${persistentStorageName}.removePrefixDirectory;
                  home = home.homeDirectory;
                })}
              '')
              (cfg.${persistentStorageName}.files ++ (map (v: v.directory) (filter (v: v.method == "symlink") cfg.${persistentStorageName}.directories))))
          persistentStorageNames);
    };
  };
}
