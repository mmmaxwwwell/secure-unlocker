# Integration tests for secure-unlocker
# Can be run with:
#   nix-build tests.nix                           # Run all tests
#   nix-build tests.nix -A integration-test       # Run specific test
#
# Or with flakes:
#   nix flake check
#   nix build .#checks.x86_64-linux.integration-test

{ pkgs ? import <nixpkgs> {}
, nixosModule ? import ./module.nix
}:

let
  # Helper to create a test with specific init options
  # This makes it easy to add tests for different filesystem types (ext4, btrfs, etc.)
  mkIntegrationTest = { name, extraInitArgs ? "", testSize ? "32M" }:
    pkgs.testers.nixosTest {
      name = "secure-unlocker-${name}";

      nodes.machine = { config, pkgs, ... }: {
        imports = [ nixosModule ];

        # Enable the secure-unlocker service for testing
        services.secure-unlocker = {
          enable = true;
          port = 13456;
          listenAddress = "127.0.0.1";
          # No public keys needed - we test the init script and manual mount/unmount
          mounts = {};
        };

        # Packages needed for the test
        environment.systemPackages = with pkgs; [
          cryptsetup
          util-linux
          curl
          netcat
        ];

        # Ensure we have enough disk space for test files
        virtualisation.diskSize = 1024;
        virtualisation.memorySize = 512;
      };

      testScript = let
        initScript = pkgs.writeShellScript "init-encrypted-test" ''
          export PATH=${pkgs.lib.makeBinPath [ pkgs.cryptsetup pkgs.util-linux pkgs.e2fsprogs pkgs.btrfs-progs ]}:$PATH
          ${builtins.readFile ./secure-unlocker-init.sh}
        '';
      in ''
        import random
        import string

        def generate_password():
            """Generate a random 32-character password"""
            chars = string.ascii_letters + string.digits
            return "".join(random.choice(chars) for _ in range(32))

        machine.start()
        machine.wait_for_unit("multi-user.target")

        # Test configuration
        test_dir = "/tmp/secure-unlocker-test"
        test_name = "test-mount"
        test_size = "${testSize}"
        source_file = test_dir + "/encrypted.img"
        mount_point = test_dir + "/mnt"
        mapper_name = "secure-unlocker-" + test_name
        test_file = "test-data.txt"
        test_content = "secure-unlocker-test-" + str(random.randint(1000000, 9999999))
        password = generate_password()
        extra_init_args = "${extraInitArgs}"
        init_script = "${initScript}"

        print("Test configuration:")
        print("  Test directory: " + test_dir)
        print("  Test size: " + test_size)
        print("  Extra init args: " + (extra_init_args or "(none)"))
        print("  Generated password: " + password[:4] + "...")

        # Setup test environment
        print("=== Setting up test environment ===")
        machine.succeed("mkdir -p " + test_dir)
        machine.succeed("mkdir -p " + mount_point)

        # Initialize encrypted device
        print("=== Initializing encrypted device ===")
        init_cmd = init_script + " --source " + source_file + " --type loop --size " + test_size
        if extra_init_args:
            init_cmd = init_cmd + " " + extra_init_args

        # Run init script with automated input
        machine.succeed("echo -e 'yes\\n" + password + "\\n" + password + "' | " + init_cmd)

        # Verify LUKS device was created
        machine.succeed("cryptsetup isLuks " + source_file)
        print("LUKS device created successfully")

        # Manual mount test (without the full API server)
        print("=== Test Phase 1: Mount, write file, unmount ===")

        # Set up loop device and mount
        loop_device = machine.succeed("losetup --find --show " + source_file).strip()
        print("Loop device: " + loop_device)

        machine.succeed("echo -n '" + password + "' | cryptsetup luksOpen " + loop_device + " " + mapper_name + " -")
        machine.succeed("mount /dev/mapper/" + mapper_name + " " + mount_point)
        print("Device mounted successfully")

        # Write test file
        machine.succeed("echo '" + test_content + "' > " + mount_point + "/" + test_file)
        print("Test file written")

        # Verify file exists
        result = machine.succeed("cat " + mount_point + "/" + test_file).strip()
        assert result == test_content, "Content mismatch: expected '" + test_content + "', got '" + result + "'"
        print("Test file verified")

        # Unmount
        machine.succeed("umount " + mount_point)
        machine.succeed("cryptsetup luksClose " + mapper_name)
        machine.succeed("losetup -d " + loop_device)
        print("Device unmounted successfully")

        # Test Phase 2: Remount and verify persistence
        print("=== Test Phase 2: Remount and verify persistence ===")

        loop_device = machine.succeed("losetup --find --show " + source_file).strip()
        machine.succeed("echo -n '" + password + "' | cryptsetup luksOpen " + loop_device + " " + mapper_name + " -")
        machine.succeed("mount /dev/mapper/" + mapper_name + " " + mount_point)
        print("Device remounted successfully")

        # Verify file persisted
        result = machine.succeed("cat " + mount_point + "/" + test_file).strip()
        assert result == test_content, "Persistence check failed: expected '" + test_content + "', got '" + result + "'"
        print("File persistence verified!")

        # Cleanup
        machine.succeed("umount " + mount_point)
        machine.succeed("cryptsetup luksClose " + mapper_name)
        machine.succeed("losetup -d " + loop_device)
        machine.succeed("rm -rf " + test_dir)

        print("=== All tests passed! ===")
      '';
    };

in {
  # Default integration test with ext4
  # LUKS2 requires ~16MB for headers, so we need at least 32M for a usable device
  integration-test = mkIntegrationTest {
    name = "ext4";
    testSize = "32M";
  };

  # Integration test with btrfs filesystem
  # btrfs needs more space than ext4 for its metadata structures
  integration-test-btrfs = mkIntegrationTest {
    name = "btrfs";
    extraInitArgs = "--fsType btrfs";
    testSize = "128M";  # btrfs needs more space
  };

  # Export the helper for use in flake.nix
  inherit mkIntegrationTest;
}
