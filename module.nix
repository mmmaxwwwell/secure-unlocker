{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.secure-unlocker;
  pipesDir = "/var/lib/secure-unlocker/pipes";

  initScript = pkgs.writeShellScriptBin "secure-unlocker-init" ''
    export PATH=${lib.makeBinPath [ pkgs.cryptsetup pkgs.util-linux pkgs.e2fsprogs ]}:$PATH
    ${builtins.readFile ./init-encrypted.sh}
  '';

  # Build the express server with esbuild
  serverApp = pkgs.buildNpmPackage {
    pname = "secure-unlocker-server";
    version = "1.0.0";

    src = ./.;

    # Build once to get correct hash, then replace this placeholder
    # Updated hash for @types/node v24
    npmDepsHash = "sha256-A0kidXkJucaFKZuLgzYTqGtUffUvcknClbHeSyGouK4=";

    buildPhase = ''
      runHook preBuild

      # Build with esbuild for production
      ${pkgs.esbuild}/bin/esbuild src/index.ts \
        --bundle \
        --platform=node \
        --target=node24 \
        --outfile=dist/index.js \
        --minify \
        --tree-shaking=true \
        --external:express

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out/bin $out/lib $out/share/public
      cp -r dist $out/lib/
      cp -r node_modules $out/lib/
      cp -r public/* $out/share/public/

      makeWrapper ${pkgs.nodejs_24}/bin/node $out/bin/secure-unlocker-server \
        --add-flags "$out/lib/dist/index.js" \
        --set PUBLIC_DIR "$out/share/public"

      runHook postInstall
    '';

    nativeBuildInputs = [ pkgs.esbuild pkgs.makeWrapper ];

    dontNpmBuild = true;
  };

  # Script to unmount and close LUKS device
  mkCleanupScript = name: mount: pkgs.writeShellScript "secure-unlocker-cleanup-${name}" ''
    set -euo pipefail

    MAPPER_NAME="secure-unlocker-${name}"
    MOUNT_POINT="${mount.mountPoint}"
    MOUNT_TYPE="${mount.type}"

    echo "Cleaning up $MAPPER_NAME..."

    # Unmount if mounted
    if ${pkgs.util-linux}/bin/mountpoint -q "$MOUNT_POINT"; then
      echo "Unmounting $MOUNT_POINT..."
      ${pkgs.util-linux}/bin/umount "$MOUNT_POINT" || true
    fi

    # Close LUKS device if open
    if [ -e "/dev/mapper/$MAPPER_NAME" ]; then
      echo "Closing LUKS device $MAPPER_NAME..."
      ${pkgs.cryptsetup}/bin/cryptsetup luksClose "$MAPPER_NAME" || true
    fi

    # Detach loop device if needed
    if [ "$MOUNT_TYPE" = "loop" ]; then
      # Find and detach any loop devices for this source
      for LOOP in $(${pkgs.util-linux}/bin/losetup -j "${mount.source}" | cut -d: -f1); do
        echo "Detaching loop device $LOOP..."
        ${pkgs.util-linux}/bin/losetup -d "$LOOP" || true
      done
    fi

    echo "Cleanup complete for $MAPPER_NAME"
  '';

  # Script to continuously read from pipe and unlock/mount
  mkUnlockScript = name: mount: pkgs.writeShellScript "secure-unlocker-${name}" ''
    set -euo pipefail

    PIPE_PATH="${pipesDir}/${name}"
    MAPPER_NAME="secure-unlocker-${name}"
    SOURCE="${mount.source}"
    MOUNT_POINT="${mount.mountPoint}"
    MOUNT_TYPE="${mount.type}"

    echo "Waiting for password on pipe: $PIPE_PATH"

    # Loop to continuously wait for passwords
    while true; do
      # Read password from pipe (blocks until data arrives)
      PASSWORD=$(cat "$PIPE_PATH")

      # Skip empty passwords
      if [ -z "$PASSWORD" ]; then
        echo "Received empty password, ignoring..."
        continue
      fi

      echo "Password received, unlocking $SOURCE..."

      # Set up loop device if needed
      if [ "$MOUNT_TYPE" = "loop" ]; then
        LOOP_DEVICE=$(${pkgs.util-linux}/bin/losetup --find --show "$SOURCE")
        CRYPT_SOURCE="$LOOP_DEVICE"
      else
        CRYPT_SOURCE="$SOURCE"
      fi

      # Unlock with cryptsetup
      if echo -n "$PASSWORD" | ${pkgs.cryptsetup}/bin/cryptsetup luksOpen "$CRYPT_SOURCE" "$MAPPER_NAME" -; then
        # Create mount point if needed
        mkdir -p "$MOUNT_POINT"

        # Mount the decrypted device
        ${pkgs.util-linux}/bin/mount "/dev/mapper/$MAPPER_NAME" "$MOUNT_POINT"

        echo "Successfully mounted $MAPPER_NAME at $MOUNT_POINT"

        # Exit after successful mount - service will remain active due to RemainAfterExit
        exit 0
      else
        echo "Failed to unlock $SOURCE, waiting for retry..."
      fi
    done
  '';

  mountOptions = types.submodule ({ config, ... }: {
    options = {
      type = mkOption {
        type = types.enum [ "loop" "block" ];
        description = "Type of encrypted storage: loop (file-backed) or block (device)";
        example = "loop";
      };

      source = mkOption {
        type = types.str;
        description = "Path to the encrypted block device or file";
        example = "/dev/sda1";
      };

      mountPoint = mkOption {
        type = types.str;
        description = "Path where the device should be mounted";
        example = "/mnt/encrypted";
      };
    };
  });
in
{
  options.services.secure-unlocker = {
    enable = mkEnableOption "secure-unlocker service";

    listenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Address for the API server to listen on";
      example = "0.0.0.0";
    };

    port = mkOption {
      type = types.port;
      default = 3456;
      description = "Port for the API server to listen on";
    };

    allowedPublicKeys = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "List of allowed Ed25519 public keys (hex-encoded) for authentication";
      example = literalExpression ''
        [
          "a1b2c3d4e5f6..."  # 64-character hex string (32 bytes Ed25519 public key)
        ]
      '';
    };

    mounts = mkOption {
      type = types.attrsOf mountOptions;
      default = {};
      description = "Encrypted mounts to manage";
      example = literalExpression ''
        {
          my-loop-drive = {
            type = "loop";
            source = "/var/encrypted/storage.img";
            mountPoint = "/mnt/encrypted";
          };
          my-block-drive = {
            type = "block";
            source = "/dev/sda1";
            mountPoint = "/mnt/external";
          };
        }
      '';
    };
  };

  config = mkIf cfg.enable {
    # Validate all mounts
    assertions = flatten (mapAttrsToList (name: mount: [
      {
        assertion = builtins.match "^/.*" mount.source != null;
        message = "Mount '${name}': source must be an absolute path";
      }
      {
        assertion = builtins.match "^/.*" mount.mountPoint != null;
        message = "Mount '${name}': mountPoint must be an absolute path";
      }
    ]) cfg.mounts);

    # Create dedicated user and group
    users.users.secure-unlocker = {
      description = "Secure Unlocker API Server user";
      isSystemUser = true;
      group = "secure-unlocker";
    };

    users.groups.secure-unlocker = {};

    # Allow secure-unlocker user to run specific privileged commands via sudo
    security.sudo.extraRules = [{
      users = [ "secure-unlocker" ];
      commands = [
        {
          command = "/run/current-system/sw/bin/systemctl is-active secure-unlocker-*";
          options = [ "NOPASSWD" ];
        }
        {
          command = "/run/current-system/sw/bin/systemctl reset-failed secure-unlocker-*";
          options = [ "NOPASSWD" ];
        }
        {
          command = "/run/current-system/sw/bin/systemctl stop secure-unlocker-*";
          options = [ "NOPASSWD" ];
        }
        {
          command = "/run/current-system/sw/bin/systemctl start secure-unlocker-*";
          options = [ "NOPASSWD" ];
        }
        {
          command = "/run/current-system/sw/bin/systemctl restart secure-unlocker-*";
          options = [ "NOPASSWD" ];
        }
        {
          command = "/run/wrappers/bin/umount /dev/mapper/secure-unlocker-*";
          options = [ "NOPASSWD" ];
        }
        {
          command = "/run/current-system/sw/bin/cryptsetup luksClose secure-unlocker-*";
          options = [ "NOPASSWD" ];
        }
      ];
    }];

    environment.systemPackages = [ initScript serverApp ];

    # Create pipes directory and named pipes for each mount
    # The directory is owned by root:secure-unlocker with 0770 permissions
    # This allows both root and secure-unlocker group to access pipes
    systemd.tmpfiles.rules = [
      "d ${pipesDir} 0770 root secure-unlocker -"
    ] ++ (mapAttrsToList (name: mount:
      # Pipes are owned by root:secure-unlocker with 0660 permissions
      # This allows secure-unlocker group to write, and root to read
      "p ${pipesDir}/${name} 0660 root secure-unlocker -"
    ) cfg.mounts);

    # Create a systemd service for each mount that waits for password on pipe
    systemd.services = mapAttrs' (name: mount: nameValuePair "secure-unlocker-${name}" {
      description = "Secure Unlocker for ${name}";
      wantedBy = [ "multi-user.target" ];
      before = [ "secure-unlocker-${name}-mounted.target" ];
      after = [ "local-fs.target" ];

      serviceConfig = {
        Type = "exec";
        ExecStart = mkUnlockScript name mount;
        # Use ExecStopPost to ensure cleanup runs even if no process is running
        ExecStopPost = mkCleanupScript name mount;
        # Mark as active even after the script exits
        RemainAfterExit = true;
        # Only restart on failure (not on success)
        Restart = "on-failure";
        RestartSec = "5s";
        # Timeout for the unlock operation
        TimeoutStartSec = "infinity";
        TimeoutStopSec = "30s";
      };

      # Check at runtime if already mounted - skip starting if it is
      unitConfig = {
        ConditionPathIsMountPoint = "!${mount.mountPoint}";
      };
    }) cfg.mounts // {
      # Express server service
      secure-unlocker-server = {
        description = "Secure Unlocker API Server";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];

        serviceConfig = {
          Type = "simple";
          ExecStart = "${serverApp}/bin/secure-unlocker-server";
          Restart = "always";
          RestartSec = "10s";

          # Run as dedicated user with minimal privileges
          DynamicUser = false;
          User = "secure-unlocker";
          Group = "secure-unlocker";

          # Security hardening
          # NoNewPrivileges must be false to allow sudo
          NoNewPrivileges = false;
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          ReadWritePaths = [ pipesDir ];
          # Need access to /dev/mapper for umount operations
          PrivateDevices = false;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
          RestrictNamespaces = true;
          LockPersonality = true;
          RestrictRealtime = true;
          # Must be false to allow sudo (SUID binary) to work
          RestrictSUIDSGID = false;
          # MemoryDenyWriteExecute cannot be used with Node.js due to JIT compilation
          # Allow @privileged and @resources syscalls for sudo/PAM to work
          # @network-io needed for networkInterfaces() to query network stack
          SystemCallFilter = [ "@system-service" "@network-io" ];

          # Minimal capabilities needed for sudo to work
          # CAP_SYS_RESOURCE needed for PAM to set process limits
          CapabilityBoundingSet = [ "CAP_SETUID" "CAP_SETGID" "CAP_SYS_RESOURCE" ];
          AmbientCapabilities = [ "" ];

          # Environment
          Environment = [
            "PORT=${toString cfg.port}"
            "LISTEN_ADDRESS=${cfg.listenAddress}"
            "NODE_ENV=production"
            "ALLOWED_PUBLIC_KEYS=${builtins.concatStringsSep "," cfg.allowedPublicKeys}"
          ];
        };
      };
    };

    # Create a target for each mount that activates when mounted
    systemd.targets = mapAttrs' (name: mount: nameValuePair "secure-unlocker-${name}-mounted" {
      description = "Secure Unlocker ${name} Mounted";
      requires = [ "secure-unlocker-${name}.service" ];
      after = [ "secure-unlocker-${name}.service" ];
    }) cfg.mounts;
  };
}
