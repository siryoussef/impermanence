{
  pkgs,
  lib,
  name,
  config, # The current SUBMODULE config
  systemConfig ? config, # The OUTER persistence block config
  homeDir,
  usersOpts ? false, # Are the options used as users.<username> submodule options?
  user, # Default user name
  group, # Default user group
}: let
  inherit
    (lib)
    mkOption
    mkDefault
    mkIf
    mapAttrsToList
    types
    mapAttrs
    optionals
    optionalAttrs
    mkRemovedOptionModule
    ;

  inherit
    (pkgs.callPackage ./lib.nix {})
    concatPaths
    ;

  inherit
    (types)
    bool
    listOf
    submodule
    nullOr
    path
    enum
    str
    coercedTo
    unspecified
    ;

  defaultPerms = {
    mode = "0755";
    inherit user group;
  };

  commonOpts = {
    options = {
      persistentStoragePath = mkOption {
        type = path;
        default = systemConfig.persistentStoragePath;
        defaultText = "environment.persistence.‹name›.persistentStoragePath";
        description = ''
          The path to persistent storage where the real
          file or directory should be stored.
        '';
      };
      home = mkOption {
        type = nullOr path;
        default = null;
        internal = true;
        description = ''
          The path to the home directory the file or
          directory is placed within.
        '';
      };
      removePrefixDirectory = mkOption {
        type = bool;
        default = systemConfig.removePrefixDirectory or false;
        defaultText = "environment.persistence.‹name›.removePrefixDirectory";
        description = ''
          Whether to remove the first component of the path when deciding where to put the links.
        '';
      };
      enableDebugging = mkOption {
        type = bool;
        default = systemConfig.enableDebugging;
        defaultText = "environment.persistence.‹name›.enableDebugging";
        internal = true;
        description = ''
          Enable debug trace output when running
          scripts. You only need to enable this if asked
          to.
        '';
      };
      assertions = mkOption {
        type = listOf unspecified;
        internal = true;
        default = [];
      };
    };
  };
  dirPermsOpts = {
    user = mkOption {
      type = str;
      description = ''
        If the directory doesn't exist in persistent
        storage it will be created and owned by the user
        specified by this option.
      '';
    };
    group = mkOption {
      type = nullOr str;
      description = ''
        If the directory doesn't exist in persistent
        storage it will be created and owned by the
        group specified by this option.
      '';
    };
    mode = mkOption {
      type = str;
      example = "0700";
      description = ''
        If the directory doesn't exist in persistent
        storage it will be created with the mode
        specified by this option.
      '';
    };
  };
  fileOpts = {
    options = {
      file = mkOption {
        type = str;
        description = ''
          The path to the file.
        '';
      };
      parentDirectory =
        commonOpts.options
        // mapAttrs
        (_: x:
          if x._type or null == "option"
          then x // {internal = true;}
          else x)
        dirOpts.options;
      method = mkOption {
        type = enum ["auto" "symlink" "bindfs"];
        default = "auto";
        description = ''
          The method used to link to the target file.
          `auto' will use the default system method (usually bind mount or systemd mount).
          `bindfs' will use a FUSE-based bind mount.
          `symlink' uses a symlink regardless.
        '';
      };
      filePath = mkOption {
        type = path;
        internal = true;
      };
    };
  };
  dirOpts = {
    options =
      {
        directory = mkOption {
          type = str;
          description = ''
            The path to the directory.
          '';
        };
        hideMount = mkOption {
          type = bool;
          default = systemConfig.hideMounts;
          defaultText = "environment.persistence.‹name›.hideMounts";
          example = true;
          description = ''
            Whether to hide bind mounts from showing up as
            mounted drives.
          '';
        };
        allowTrash = mkOption {
          type = bool;
          default = systemConfig.allowTrash;
          defaultText = "environment.persistence.‹name›.allowTrash";
          example = true;
          description = ''
            Whether to allow newer GIO-based applications to trash files.
          '';
        };
        method = mkOption {
          type = enum ["bind" "bindfs" "symlink"];
          default = "bind";
          description = ''
            The method used to link to the target directory.
            `bind' uses a native systemd bind mount.
            `bindfs' uses a FUSE-based bind mount (useful for allowOther).
            `symlink' uses a symlink.
          '';
        };
        allowOther = mkOption {
          type = bool;
          default = false;
          description = ''
            Whether to allow other users to access the directory (only works with bindfs).
          '';
        };
        # Save the default permissions at the level the
        # directory resides. This used when creating its
        # parent directories, giving them reasonable
        # default permissions unaffected by the
        # directory's own.
        defaultPerms = mapAttrs (_: x: x // {internal = true;}) dirPermsOpts;
        dirPath = mkOption {
          type = path;
          internal = true;
        };
      }
      // dirPermsOpts;
  };
  file = submodule [
    commonOpts
    fileOpts
    (mkIf (homeDir != null) {home = homeDir;})
    {
      parentDirectory = mkDefault defaultPerms;
    }
    ({config, ...}: let
      parentPath =
        if config.home != null
        then config.home
        else "/";
      directory = dirOf config.file;
    in {
      parentDirectory = {
        dirPath = concatPaths [parentPath directory];
        inherit directory defaultPerms;
        inherit (config) home persistentStoragePath;
      };
      filePath = concatPaths [parentPath config.file];
    })
  ];
  dir = submodule ([
      commonOpts
      dirOpts
      (mkIf (homeDir != null) {home = homeDir;})
      ({config, ...}: let
        home =
          if config.home != null
          then config.home
          else "/";
      in {
        defaultPerms = mkDefault defaultPerms;
        dirPath = concatPaths [home config.directory];
      })
    ]
    ++ (mapAttrsToList (n: v: {${n} = mkDefault v;}) defaultPerms));
in {
  options =
    {
      files = mkOption {
        type = listOf (coercedTo str (f: {file = f;}) file);
        default = [];
        example = [
          "/etc/machine-id"
          "/etc/nix/id_rsa"
        ];
        description = ''
          Files that should be stored in persistent storage.
        '';
      };

      directories = mkOption {
        type = listOf (coercedTo str (d: {directory = d;}) dir);
        default = [];
        example = [
          "/var/log"
          "/var/lib/bluetooth"
          "/var/lib/nixos"
          "/var/lib/systemd/coredump"
          "/etc/NetworkManager/system-connections"
        ];
        description = ''
          Directories to bind mount to persistent storage.
        '';
      };

      assertions = mkOption {
        type = listOf unspecified;
        internal = true;
        default = [];
      };
      allowOther = mkOption {
        type = bool;
        default = false;
        description = "Allow other users to access the persisted files.";
      };
      removePrefixDirectory = mkOption {
        type = bool;
        default = false;
        description = "Whether to remove the home directory prefix from the on-disk path.";
      };
    }
    // optionalAttrs (!usersOpts)
    {
      enable = mkOption {
        type = bool;
        default = true;
        description = "Whether to enable this persistent storage location.";
      };

      persistentStoragePath = mkOption {
        type = path;
        default = name;
        defaultText = "‹name›";
        description = ''
          The path to persistent storage where the real
          files and directories should be stored.
        '';
      };

      hideMounts = mkOption {
        type = bool;
        default = false;
        example = true;
        description = ''
          Whether to hide bind mounts from showing up as mounted drives.
        '';
      };

      allowTrash = mkOption {
        type = bool;
        default = false;
        example = true;
        description = ''
          Whether to allow newer GIO-based applications to trash files.
        '';
      };

      enableDebugging = mkOption {
        type = bool;
        default = false;
        internal = true;
        description = ''
          Enable debug trace output when running
          scripts. You only need to enable this if asked
          to.
        '';
      };

      enableWarnings = mkOption {
        type = bool;
        default = true;
        description = ''
          Enable non-critical warnings.
        '';
      };
    };
}
