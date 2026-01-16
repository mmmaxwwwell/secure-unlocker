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

  # Multi-device test helper
  mkMultiDeviceTest = { name, extraInitArgs ? "", testSize ? "128M", numDevices ? 2 }:
    pkgs.testers.nixosTest {
      name = "secure-unlocker-${name}";

      nodes.machine = { config, pkgs, ... }: {
        imports = [ nixosModule ];

        services.secure-unlocker = {
          enable = true;
          port = 13456;
          listenAddress = "127.0.0.1";
          mounts = {};
        };

        environment.systemPackages = with pkgs; [
          cryptsetup
          util-linux
          curl
          netcat
          btrfs-progs
        ];

        virtualisation.diskSize = 2048;
        virtualisation.memorySize = 1024;
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
        num_devices = ${toString numDevices}
        mount_point = test_dir + "/mnt"
        test_file = "test-data.txt"
        test_content = "secure-unlocker-test-" + str(random.randint(1000000, 9999999))
        password = generate_password()
        extra_init_args = "${extraInitArgs}"
        init_script = "${initScript}"

        # Build source file list
        source_files = [test_dir + "/encrypted-" + str(i) + ".img" for i in range(num_devices)]
        source_paths = ",".join(source_files)

        # Build mapper names
        mapper_base = "secure-unlocker-" + test_name
        mapper_names = [mapper_base + "-" + str(i) for i in range(num_devices)]

        print("Test configuration:")
        print("  Test directory: " + test_dir)
        print("  Number of devices: " + str(num_devices))
        print("  Test size per device: " + test_size)
        print("  Extra init args: " + (extra_init_args or "(none)"))

        # Setup test environment
        print("=== Setting up test environment ===")
        machine.succeed("mkdir -p " + test_dir)
        machine.succeed("mkdir -p " + mount_point)

        # Initialize encrypted devices
        print("=== Initializing encrypted devices ===")
        init_cmd = init_script + " --source " + source_paths + " --type loop --size " + test_size
        if extra_init_args:
            init_cmd = init_cmd + " " + extra_init_args

        # Run init script with automated input
        machine.succeed("echo -e 'yes\\n" + password + "\\n" + password + "' | " + init_cmd)

        # Verify all LUKS devices were created
        for source_file in source_files:
            machine.succeed("cryptsetup isLuks " + source_file)
        print("All LUKS devices created successfully")

        # Test Phase 1: Mount, write file, unmount
        print("=== Test Phase 1: Mount, write file, unmount ===")

        # Set up loop devices and unlock all
        loop_devices = []
        for i, source_file in enumerate(source_files):
            loop_device = machine.succeed("losetup --find --show " + source_file).strip()
            loop_devices.append(loop_device)
            print("Loop device " + str(i) + ": " + loop_device)
            machine.succeed("echo -n '" + password + "' | cryptsetup luksOpen " + loop_device + " " + mapper_names[i] + " -")

        # Mount (btrfs should auto-detect all devices)
        machine.succeed("mount /dev/mapper/" + mapper_names[0] + " " + mount_point)
        print("Multi-device btrfs mounted successfully")

        # Verify btrfs sees all devices
        btrfs_info = machine.succeed("btrfs filesystem show " + mount_point)
        print("Btrfs filesystem info:")
        print(btrfs_info)

        # Write test file
        machine.succeed("echo '" + test_content + "' > " + mount_point + "/" + test_file)
        print("Test file written")

        # Verify file exists
        result = machine.succeed("cat " + mount_point + "/" + test_file).strip()
        assert result == test_content, "Content mismatch"
        print("Test file verified")

        # Unmount and close all devices
        machine.succeed("umount " + mount_point)
        for mapper in mapper_names:
            machine.succeed("cryptsetup luksClose " + mapper)
        for loop_device in loop_devices:
            machine.succeed("losetup -d " + loop_device)
        print("All devices unmounted and closed")

        # Test Phase 2: Remount and verify persistence
        print("=== Test Phase 2: Remount and verify persistence ===")

        # Re-open all devices
        loop_devices = []
        for i, source_file in enumerate(source_files):
            loop_device = machine.succeed("losetup --find --show " + source_file).strip()
            loop_devices.append(loop_device)
            machine.succeed("echo -n '" + password + "' | cryptsetup luksOpen " + loop_device + " " + mapper_names[i] + " -")

        machine.succeed("mount /dev/mapper/" + mapper_names[0] + " " + mount_point)
        print("Multi-device btrfs remounted successfully")

        # Verify file persisted
        result = machine.succeed("cat " + mount_point + "/" + test_file).strip()
        assert result == test_content, "Persistence check failed"
        print("File persistence verified!")

        # Cleanup
        machine.succeed("umount " + mount_point)
        for mapper in mapper_names:
            machine.succeed("cryptsetup luksClose " + mapper)
        for loop_device in loop_devices:
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

  # Integration test with btrfs multi-device RAID1
  # Note: Each device needs to be at least 125MB for btrfs RAID1, plus ~16MB for LUKS2 headers
  integration-test-btrfs-raid1 = mkMultiDeviceTest {
    name = "btrfs-raid1";
    extraInitArgs = "--fsType btrfs --data-profile raid1 --metadata-profile raid1";
    testSize = "256M";  # Increased from 128M to accommodate LUKS2 headers + btrfs minimum size
    numDevices = 2;
  };

  # Block device tests using virtual disks
  # Test with ext4 on a block device
  integration-test-ext4-block = pkgs.testers.nixosTest {
    name = "secure-unlocker-ext4-block";

    nodes.machine = { config, pkgs, ... }: {
      imports = [ nixosModule ];

      services.secure-unlocker = { 
        enable = true;
        port = 13456;
        listenAddress = "127.0.0.1";
        mounts = {};
      };

      environment.systemPackages = with pkgs; [
        cryptsetup
        util-linux
        curl
        netcat
      ];

      virtualisation.diskSize = 1024;
      virtualisation.memorySize = 512;
      # Add a virtual disk for block device testing
      virtualisation.emptyDiskImages = [ 512 ];
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
      block_device = "/dev/vdb"
      mount_point = test_dir + "/mnt"
      mapper_name = "secure-unlocker-" + test_name
      test_file = "test-data.txt"
      test_content = "secure-unlocker-test-" + str(random.randint(1000000, 9999999))
      password = generate_password()
      init_script = "${initScript}"

      print("Test configuration:")
      print("  Block device: " + block_device)
      print("  Mount point: " + mount_point)

      # Setup test environment
      print("=== Setting up test environment ===")
      machine.succeed("mkdir -p " + mount_point)

      # Verify block device exists
      machine.succeed("test -b " + block_device)
      print("Block device " + block_device + " exists")

      # Initialize encrypted device
      print("=== Initializing encrypted block device ===")
      init_cmd = init_script + " --source " + block_device + " --type block"

      # Run init script with automated input
      machine.succeed("echo -e 'yes\\n" + password + "\\n" + password + "' | " + init_cmd)

      # Verify LUKS device was created
      machine.succeed("cryptsetup isLuks " + block_device)
      print("LUKS device created successfully on block device")

      # Manual mount test
      print("=== Test Phase 1: Mount, write file, unmount ===")

      machine.succeed("echo -n '" + password + "' | cryptsetup luksOpen " + block_device + " " + mapper_name + " -")
      machine.succeed("mount /dev/mapper/" + mapper_name + " " + mount_point)
      print("Block device mounted successfully")

      # Write test file
      machine.succeed("echo '" + test_content + "' > " + mount_point + "/" + test_file)
      print("Test file written")

      # Verify file exists
      result = machine.succeed("cat " + mount_point + "/" + test_file).strip()
      assert result == test_content, "Content mismatch"
      print("Test file verified")

      # Unmount
      machine.succeed("umount " + mount_point)
      machine.succeed("cryptsetup luksClose " + mapper_name)
      print("Block device unmounted successfully")

      # Test Phase 2: Remount and verify persistence
      print("=== Test Phase 2: Remount and verify persistence ===")

      machine.succeed("echo -n '" + password + "' | cryptsetup luksOpen " + block_device + " " + mapper_name + " -")
      machine.succeed("mount /dev/mapper/" + mapper_name + " " + mount_point)
      print("Block device remounted successfully")

      # Verify file persisted
      result = machine.succeed("cat " + mount_point + "/" + test_file).strip()
      assert result == test_content, "Persistence check failed"
      print("File persistence verified!")

      # Cleanup
      machine.succeed("umount " + mount_point)
      machine.succeed("cryptsetup luksClose " + mapper_name)

      print("=== All tests passed! ===")
    '';
  };

  # Test with btrfs on a block device
  integration-test-btrfs-block = pkgs.testers.nixosTest {
    name = "secure-unlocker-btrfs-block";

    nodes.machine = { config, pkgs, ... }: {
      imports = [ nixosModule ];

      services.secure-unlocker = {
        enable = true;
        port = 13456;
        listenAddress = "127.0.0.1";
        mounts = {};
      };

      environment.systemPackages = with pkgs; [
        cryptsetup
        util-linux
        curl
        netcat
      ];

      virtualisation.diskSize = 1024;
      virtualisation.memorySize = 512;
      # Add a virtual disk for block device testing
      virtualisation.emptyDiskImages = [ 512 ];
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
      block_device = "/dev/vdb"
      mount_point = test_dir + "/mnt"
      mapper_name = "secure-unlocker-" + test_name
      test_file = "test-data.txt"
      test_content = "secure-unlocker-test-" + str(random.randint(1000000, 9999999))
      password = generate_password()
      init_script = "${initScript}"

      print("Test configuration:")
      print("  Block device: " + block_device)
      print("  Mount point: " + mount_point)
      print("  Filesystem: btrfs")

      # Setup test environment
      print("=== Setting up test environment ===")
      machine.succeed("mkdir -p " + mount_point)

      # Verify block device exists
      machine.succeed("test -b " + block_device)
      print("Block device " + block_device + " exists")

      # Initialize encrypted device with btrfs
      print("=== Initializing encrypted block device with btrfs ===")
      init_cmd = init_script + " --source " + block_device + " --type block --fsType btrfs"

      # Run init script with automated input
      machine.succeed("echo -e 'yes\\n" + password + "\\n" + password + "' | " + init_cmd)

      # Verify LUKS device was created
      machine.succeed("cryptsetup isLuks " + block_device)
      print("LUKS device created successfully on block device")

      # Manual mount test
      print("=== Test Phase 1: Mount, write file, unmount ===")

      machine.succeed("echo -n '" + password + "' | cryptsetup luksOpen " + block_device + " " + mapper_name + " -")
      machine.succeed("mount /dev/mapper/" + mapper_name + " " + mount_point)
      print("Btrfs block device mounted successfully")

      # Write test file
      machine.succeed("echo '" + test_content + "' > " + mount_point + "/" + test_file)
      print("Test file written")

      # Verify file exists
      result = machine.succeed("cat " + mount_point + "/" + test_file).strip()
      assert result == test_content, "Content mismatch"
      print("Test file verified")

      # Unmount
      machine.succeed("umount " + mount_point)
      machine.succeed("cryptsetup luksClose " + mapper_name)
      print("Btrfs block device unmounted successfully")

      # Test Phase 2: Remount and verify persistence
      print("=== Test Phase 2: Remount and verify persistence ===")

      machine.succeed("echo -n '" + password + "' | cryptsetup luksOpen " + block_device + " " + mapper_name + " -")
      machine.succeed("mount /dev/mapper/" + mapper_name + " " + mount_point)
      print("Btrfs block device remounted successfully")

      # Verify file persisted
      result = machine.succeed("cat " + mount_point + "/" + test_file).strip()
      assert result == test_content, "Persistence check failed"
      print("File persistence verified!")

      # Cleanup
      machine.succeed("umount " + mount_point)
      machine.succeed("cryptsetup luksClose " + mapper_name)

      print("=== All tests passed! ===")
    '';
  };

  # Test with btrfs RAID1 on multiple block devices
  integration-test-btrfs-raid1-block = pkgs.testers.nixosTest {
    name = "secure-unlocker-btrfs-raid1-block";

    nodes.machine = { config, pkgs, ... }: {
      imports = [ nixosModule ];

      services.secure-unlocker = {
        enable = true;
        port = 13456;
        listenAddress = "127.0.0.1";
        mounts = {};
      };

      environment.systemPackages = with pkgs; [
        cryptsetup
        util-linux
        curl
        netcat
        btrfs-progs
      ];

      virtualisation.diskSize = 2048;
      virtualisation.memorySize = 1024;
      # Add two virtual disks for RAID1 testing
      virtualisation.emptyDiskImages = [ 512 512 ];
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
      block_devices = ["/dev/vdb", "/dev/vdc"]
      block_devices_str = ",".join(block_devices)
      mount_point = test_dir + "/mnt"
      mapper_names = ["secure-unlocker-" + test_name + "-0", "secure-unlocker-" + test_name + "-1"]
      test_file = "test-data.txt"
      test_content = "secure-unlocker-test-" + str(random.randint(1000000, 9999999))
      password = generate_password()
      init_script = "${initScript}"

      print("Test configuration:")
      print("  Block devices: " + str(block_devices))
      print("  Mount point: " + mount_point)
      print("  Filesystem: btrfs RAID1")

      # Setup test environment
      print("=== Setting up test environment ===")
      machine.succeed("mkdir -p " + mount_point)

      # Verify block devices exist
      for device in block_devices:
          machine.succeed("test -b " + device)
          print("Block device " + device + " exists")

      # Initialize encrypted devices with btrfs RAID1
      print("=== Initializing encrypted block devices with btrfs RAID1 ===")
      init_cmd = init_script + " --source " + block_devices_str + " --type block --fsType btrfs --data-profile raid1 --metadata-profile raid1"

      # Run init script with automated input
      machine.succeed("echo -e 'yes\\n" + password + "\\n" + password + "' | " + init_cmd)

      # Verify LUKS devices were created
      for device in block_devices:
          machine.succeed("cryptsetup isLuks " + device)
      print("All LUKS devices created successfully on block devices")

      # Manual mount test
      print("=== Test Phase 1: Mount, write file, unmount ===")

      # Open all LUKS devices
      for i, device in enumerate(block_devices):
          machine.succeed("echo -n '" + password + "' | cryptsetup luksOpen " + device + " " + mapper_names[i] + " -")
          print("Opened " + device + " as " + mapper_names[i])

      # Mount (btrfs should auto-detect all devices)
      machine.succeed("mount /dev/mapper/" + mapper_names[0] + " " + mount_point)
      print("Btrfs RAID1 mounted successfully")

      # Verify btrfs sees all devices
      btrfs_info = machine.succeed("btrfs filesystem show " + mount_point)
      print("Btrfs filesystem info:")
      print(btrfs_info)

      # Write test file
      machine.succeed("echo '" + test_content + "' > " + mount_point + "/" + test_file)
      print("Test file written")

      # Verify file exists
      result = machine.succeed("cat " + mount_point + "/" + test_file).strip()
      assert result == test_content, "Content mismatch"
      print("Test file verified")

      # Unmount and close all devices
      machine.succeed("umount " + mount_point)
      for mapper in mapper_names:
          machine.succeed("cryptsetup luksClose " + mapper)
      print("All devices unmounted and closed")

      # Test Phase 2: Remount and verify persistence
      print("=== Test Phase 2: Remount and verify persistence ===")

      # Re-open all devices
      for i, device in enumerate(block_devices):
          machine.succeed("echo -n '" + password + "' | cryptsetup luksOpen " + device + " " + mapper_names[i] + " -")

      machine.succeed("mount /dev/mapper/" + mapper_names[0] + " " + mount_point)
      print("Btrfs RAID1 remounted successfully")

      # Verify file persisted
      result = machine.succeed("cat " + mount_point + "/" + test_file).strip()
      assert result == test_content, "Persistence check failed"
      print("File persistence verified!")

      # Cleanup
      machine.succeed("umount " + mount_point)
      for mapper in mapper_names:
          machine.succeed("cryptsetup luksClose " + mapper)

      print("=== All tests passed! ===")
    '';
  };

  # Export the helpers for use in flake.nix
  inherit mkIntegrationTest mkMultiDeviceTest;
}
