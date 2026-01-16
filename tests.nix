# Integration tests for secure-unlocker
# Can be run with:
#   nix-build tests.nix                                # Run all tests
#   nix-build tests.nix -A integration-test-ext4-loop  # Run specific test
#
# Or with flakes:
#   nix flake check                                              # Run all tests
#   nix build .#checks.x86_64-linux.integration-test-ext4-loop   # Run specific test
#
# Test matrix:
#   - integration-test-ext4-loop:        ext4 file-backed (loop) device
#   - integration-test-ext4-block:       ext4 block device
#   - integration-test-btrfs-loop:       btrfs single file-backed (loop) device
#   - integration-test-btrfs-block:      btrfs single block device
#   - integration-test-btrfs-raid1-loop: btrfs raid1 with 2 file-backed (loop) devices
#   - integration-test-btrfs-raid1-block: btrfs raid1 with 2 block devices

{ pkgs ? import <nixpkgs> {}
, nixosModule ? import ./module.nix
}:

let
  # Python helper module for Ed25519 signing - used by all integration tests
  # This creates signed HTTP requests compatible with the Express server's authentication
  signingHelperModule = ''
import hashlib
import time

class Ed25519Signer:
    """Helper class for Ed25519 request signing compatible with secure-unlocker server"""

    def __init__(self, key_dir="/tmp/test-keys"):
        self.key_dir = key_dir
        self.private_key_path = f"{key_dir}/test-key"
        self.public_key_hex = None

    def generate_keypair(self, machine):
        """Generate Ed25519 keypair and extract public key in hex format"""
        # Create key directory
        machine.succeed(f"mkdir -p {self.key_dir}")

        # Generate Ed25519 key with OpenSSL (produces raw Ed25519 keys)
        machine.succeed(f"openssl genpkey -algorithm Ed25519 -out {self.private_key_path}.pem")

        # Extract public key in DER format and get raw 32 bytes
        # The DER format has a 12-byte header for Ed25519 public keys
        machine.succeed(f"openssl pkey -in {self.private_key_path}.pem -pubout -outform DER -out {self.private_key_path}.pub.der")

        # Extract last 32 bytes (the raw public key) and convert to hex
        self.public_key_hex = machine.succeed(f"tail -c 32 {self.private_key_path}.pub.der | xxd -p -c 64").strip()

        print(f"Generated Ed25519 keypair, public key: {self.public_key_hex}")
        return self.public_key_hex

    def sign_request(self, machine, method, url, body=""):
        """Sign an HTTP request and return headers dict"""
        timestamp = str(int(time.time()))

        # Compute body hash
        if body:
            body_hash = hashlib.sha256(body.encode()).hexdigest()
        else:
            body_hash = hashlib.sha256(b"").hexdigest()

        # Build message to sign: METHOD:URL:TIMESTAMP:BODY_HASH
        message = f"{method}:{url}:{timestamp}:{body_hash}"

        # Write message to temp file for signing
        machine.succeed(f"echo -n '{message}' > /tmp/sign-message.txt")

        # Sign with OpenSSL and get hex signature
        # Ed25519 requires -rawin flag to sign arbitrary data (not a hash)
        signature = machine.succeed(
            f"openssl pkeyutl -sign -rawin -inkey {self.private_key_path}.pem -in /tmp/sign-message.txt | xxd -p -c 128"
        ).strip()

        return {
            "X-Signature": signature,
            "X-Timestamp": timestamp,
            "X-Public-Key": self.public_key_hex,
        }

    def make_signed_request(self, machine, method, url, body="", port=13456):
        """Make a signed HTTP request using curl"""
        headers = self.sign_request(machine, method, url, body)

        curl_headers = " ".join([f'-H "{k}: {v}"' for k, v in headers.items()])

        if body:
            cmd = f'curl -s -X {method} {curl_headers} -H "Content-Type: application/json" -d \'{body}\' "http://127.0.0.1:{port}{url}"'
        else:
            cmd = f'curl -s -X {method} {curl_headers} "http://127.0.0.1:{port}{url}"'

        return machine.succeed(cmd)
'';

  # Helper to create API tests that use the actual NixOS module's systemd units
  # This tests the real module.nix configuration with the Express server
  # For loop devices (file-backed encryption)
  mkLoopDeviceTest = { name, extraInitArgs ? "", testSize ? "32M", fsType ? "ext4", numDevices ? 1 }:
    let
      testName = "test-mount";
      testDir = "/tmp/secure-unlocker-test";
      # For multi-device, create comma-separated source paths
      sourceFiles = builtins.genList (i: "${testDir}/encrypted-${toString i}.img") numDevices;
      sourceFilesStr = builtins.concatStringsSep "," sourceFiles;
      mountPoint = "${testDir}/mnt";
    in pkgs.testers.nixosTest {
      name = "secure-unlocker-loop-${name}";

      nodes.machine = { config, pkgs, ... }: {
        imports = [ nixosModule ];

        # Enable the secure-unlocker service with actual mount configuration
        # The encrypted device will be created at test time at the configured path
        services.secure-unlocker = {
          enable = true;
          port = 13456;
          listenAddress = "127.0.0.1";
          # Public key will be injected via systemd drop-in at test time
          allowedPublicKeys = [];
          # Configure the actual mount - this creates the systemd unit
          mounts.${testName} = {
            type = "loop";
            source = sourceFilesStr;
            mountPoint = mountPoint;
            fsType = fsType;
          };
        };

        # Packages needed for the test
        environment.systemPackages = with pkgs; [
          cryptsetup
          util-linux
          curl
          netcat
          openssl
          xxd
          jq
        ];

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
import json

${signingHelperModule}

def generate_password():
    """Generate a random 32-character password"""
    chars = string.ascii_letters + string.digits
    return "".join(random.choice(chars) for _ in range(32))

machine.start()
machine.wait_for_unit("multi-user.target")

# Test configuration - must match the NixOS module config above
test_dir = "${testDir}"
test_name = "${testName}"
test_size = "${testSize}"
fs_type = "${fsType}"
source_files = "${sourceFilesStr}"
mount_point = "${mountPoint}"
extra_init_args = "${extraInitArgs}"
init_script = "${initScript}"
num_devices = ${toString numDevices}

test_file = "test-data.txt"
test_content = "secure-unlocker-loop-test-" + str(random.randint(1000000, 9999999))
password = generate_password()

print("=== Loop Device Integration Test: ${name} ===")
print("Test configuration:")
print("  Test directory: " + test_dir)
print("  Test size: " + test_size)
print("  Filesystem: " + fs_type)
print("  Number of devices: " + str(num_devices))
print("  Source files: " + source_files)
print("  Using actual NixOS module systemd units")

# Setup test environment - create directory for encrypted device
print("=== Setting up test environment ===")
machine.succeed("mkdir -p " + test_dir)
machine.succeed("mkdir -p " + mount_point)

# The module created the mount service, but it's waiting on the mount point
# condition (ConditionPathIsMountPoint=!mountPoint). First stop it so we can
# create the encrypted device.
machine.succeed("systemctl stop secure-unlocker-" + test_name + ".service 2>/dev/null || true")

# Generate Ed25519 keypair for signing
print("=== Generating Ed25519 keypair ===")
signer = Ed25519Signer()
public_key = signer.generate_keypair(machine)

# Update the server's allowed public keys by restarting with new env
print("=== Configuring server with test public key ===")
machine.succeed("systemctl stop secure-unlocker-server.service")
machine.succeed("mkdir -p /run/systemd/system/secure-unlocker-server.service.d")
drop_in_content = f'[Service]\nEnvironment="ALLOWED_PUBLIC_KEYS={public_key}"'
machine.succeed(f"cat > /run/systemd/system/secure-unlocker-server.service.d/test-key.conf << 'DROPINEOF'\n{drop_in_content}\nDROPINEOF")
machine.succeed("systemctl daemon-reload")
machine.succeed("systemctl start secure-unlocker-server.service")
machine.wait_for_unit("secure-unlocker-server.service")

# Initialize encrypted device at the path configured in the NixOS module
print("=== Initializing encrypted device(s) ===")
init_cmd = init_script + " --source " + source_files + " --type loop --size " + test_size
if extra_init_args:
    init_cmd = init_cmd + " " + extra_init_args
machine.succeed("echo -e 'yes\\n" + password + "\\n" + password + "' | " + init_cmd)

# Verify LUKS device was created (check first file)
first_source = source_files.split(",")[0]
machine.succeed("cryptsetup isLuks " + first_source)
print("LUKS device(s) created successfully at configured path(s)")

# Verify server is healthy
print("=== Verifying server health ===")
health = machine.succeed("curl -s http://127.0.0.1:13456/health")
assert '"status":"ok"' in health, f"Health check failed: {health}"
print("Server is healthy")

# Test the /list endpoint
print("=== Testing /list endpoint ===")
list_response = signer.make_signed_request(machine, "GET", "/list")
print(f"List response: {list_response}")
assert test_name in list_response, f"Mount '{test_name}' not found in list: {list_response}"
print("Mount found in /list endpoint")

# Test Phase 1: Mount via API using the actual module's systemd service
print("=== Test Phase 1: Mount via API (using module systemd unit) ===")

body = json.dumps({"password": password}, separators=(',', ':'))
response = signer.make_signed_request(machine, "POST", f"/mount/{test_name}", body)
print(f"Mount response: {response}")
assert '"success":true' in response, f"Mount failed: {response}"

# Wait for mount to complete - the module's actual service should handle this
machine.wait_until_succeeds(f"mountpoint -q {mount_point}", timeout=30)
print("Device mounted successfully via API using module's systemd unit")

# Verify the systemd service is active (RemainAfterExit=true)
service_status = machine.succeed(f"systemctl is-active secure-unlocker-{test_name}.service").strip()
assert service_status == "active", f"Service should be active after mount, got: {service_status}"
print("Module's systemd service is active after mount")

# Write test file
machine.succeed("echo '" + test_content + "' > " + mount_point + "/" + test_file)
print("Test file written")

# Verify file exists
result = machine.succeed("cat " + mount_point + "/" + test_file).strip()
assert result == test_content, f"Content mismatch: expected '{test_content}', got '{result}'"
print("Test file verified")

# Test Phase 2: Unmount via API
print("=== Test Phase 2: Unmount via API ===")

response = signer.make_signed_request(machine, "POST", f"/unmount/{test_name}")
print(f"Unmount response: {response}")
assert '"success":true' in response, f"Unmount failed: {response}"

# Wait for unmount to complete
machine.wait_until_fails(f"mountpoint -q {mount_point}", timeout=30)
print("Device unmounted successfully via API")

# Verify no LUKS device left behind (check all devices)
for i in range(num_devices):
    machine.succeed(f"test ! -e /dev/mapper/secure-unlocker-{test_name}-{i}")
print("LUKS device(s) correctly closed by module's cleanup script")

# Test Phase 3: Remount and verify persistence
print("=== Test Phase 3: Remount via API and verify persistence ===")

# Reset any failed state from the service
machine.succeed(f"systemctl reset-failed secure-unlocker-{test_name}.service 2>/dev/null || true")

body = json.dumps({"password": password}, separators=(',', ':'))
response = signer.make_signed_request(machine, "POST", f"/mount/{test_name}", body)
print(f"Remount response: {response}")
assert '"success":true' in response, f"Remount failed: {response}"

machine.wait_until_succeeds(f"mountpoint -q {mount_point}", timeout=30)
print("Device remounted successfully via API")

# Verify file persisted
result = machine.succeed("cat " + mount_point + "/" + test_file).strip()
assert result == test_content, f"Persistence check failed: expected '{test_content}', got '{result}'"
print("File persistence verified!")

# Test Phase 4: Final unmount
print("=== Test Phase 4: Final unmount via API ===")

response = signer.make_signed_request(machine, "POST", f"/unmount/{test_name}")
assert '"success":true' in response, f"Final unmount failed: {response}"
machine.wait_until_fails(f"mountpoint -q {mount_point}", timeout=30)
print("Final unmount successful")

# Test Phase 5: Test authentication failure
print("=== Test Phase 5: Verify authentication enforcement ===")

unauth_response = machine.succeed("curl -s -X POST -H 'Content-Type: application/json' "
                                  f"-d '{{\"password\":\"{password}\"}}' 'http://127.0.0.1:13456/mount/{test_name}'")
assert '"error"' in unauth_response and ('401' in unauth_response or 'Missing authentication' in unauth_response or 'Authentication' in unauth_response), \
    f"Unauthenticated request should have failed: {unauth_response}"
print("Authentication correctly enforced - unauthenticated request rejected")

# Cleanup
machine.succeed("rm -rf " + test_dir)

print("=== All Loop Device tests passed! ===")
      '';
    };

  # Helper to create API tests for block devices
  # Block devices are provided via virtualisation.emptyDiskImages in NixOS VM tests
  mkBlockDeviceTest = { name, extraInitArgs ? "", diskSizeMB ? 64, fsType ? "ext4", numDevices ? 1 }:
    let
      testName = "test-mount";
      testDir = "/tmp/secure-unlocker-test";
      mountPoint = "${testDir}/mnt";
      # In NixOS VM tests, emptyDiskImages creates /dev/vdb, /dev/vdc, etc.
      # Note: /dev/vda is the root disk
      blockDevices = builtins.genList (i: "/dev/vd${builtins.elemAt ["b" "c" "d" "e" "f" "g"] i}") numDevices;
      blockDevicesStr = builtins.concatStringsSep "," blockDevices;
      diskImages = builtins.genList (_: diskSizeMB) numDevices;
    in pkgs.testers.nixosTest {
      name = "secure-unlocker-block-${name}";

      nodes.machine = { config, pkgs, ... }: {
        imports = [ nixosModule ];

        # Enable the secure-unlocker service with actual mount configuration
        services.secure-unlocker = {
          enable = true;
          port = 13456;
          listenAddress = "127.0.0.1";
          # Public key will be injected via systemd drop-in at test time
          allowedPublicKeys = [];
          # Configure the actual mount - this creates the systemd unit
          mounts.${testName} = {
            type = "block";
            source = blockDevicesStr;
            mountPoint = mountPoint;
            fsType = fsType;
          };
        };

        # Packages needed for the test
        environment.systemPackages = with pkgs; [
          cryptsetup
          util-linux
          curl
          netcat
          openssl
          xxd
          jq
        ];

        # Add empty disk images that become /dev/vdb, /dev/vdc, etc.
        virtualisation.emptyDiskImages = diskImages;
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
import json

${signingHelperModule}

def generate_password():
    """Generate a random 32-character password"""
    chars = string.ascii_letters + string.digits
    return "".join(random.choice(chars) for _ in range(32))

machine.start()
machine.wait_for_unit("multi-user.target")

# Test configuration - must match the NixOS module config above
test_dir = "${testDir}"
test_name = "${testName}"
fs_type = "${fsType}"
block_devices = "${blockDevicesStr}"
mount_point = "${mountPoint}"
extra_init_args = "${extraInitArgs}"
init_script = "${initScript}"
num_devices = ${toString numDevices}

test_file = "test-data.txt"
test_content = "secure-unlocker-block-test-" + str(random.randint(1000000, 9999999))
password = generate_password()

print("=== Block Device Integration Test: ${name} ===")
print("Test configuration:")
print("  Test directory: " + test_dir)
print("  Filesystem: " + fs_type)
print("  Number of devices: " + str(num_devices))
print("  Block devices: " + block_devices)
print("  Using actual NixOS module systemd units")

# Verify block devices exist
print("=== Verifying block devices ===")
for dev in block_devices.split(","):
    machine.succeed(f"test -b {dev}")
    print(f"  Block device {dev} exists")

# Setup test environment
print("=== Setting up test environment ===")
machine.succeed("mkdir -p " + test_dir)
machine.succeed("mkdir -p " + mount_point)

# The module created the mount service, but it's waiting on the mount point
# condition (ConditionPathIsMountPoint=!mountPoint). First stop it so we can
# create the encrypted device.
machine.succeed("systemctl stop secure-unlocker-" + test_name + ".service 2>/dev/null || true")

# Generate Ed25519 keypair for signing
print("=== Generating Ed25519 keypair ===")
signer = Ed25519Signer()
public_key = signer.generate_keypair(machine)

# Update the server's allowed public keys by restarting with new env
print("=== Configuring server with test public key ===")
machine.succeed("systemctl stop secure-unlocker-server.service")
machine.succeed("mkdir -p /run/systemd/system/secure-unlocker-server.service.d")
drop_in_content = f'[Service]\nEnvironment="ALLOWED_PUBLIC_KEYS={public_key}"'
machine.succeed(f"cat > /run/systemd/system/secure-unlocker-server.service.d/test-key.conf << 'DROPINEOF'\n{drop_in_content}\nDROPINEOF")
machine.succeed("systemctl daemon-reload")
machine.succeed("systemctl start secure-unlocker-server.service")
machine.wait_for_unit("secure-unlocker-server.service")

# Initialize encrypted block device(s)
print("=== Initializing encrypted block device(s) ===")
init_cmd = init_script + " --source " + block_devices + " --type block"
if extra_init_args:
    init_cmd = init_cmd + " " + extra_init_args
machine.succeed("echo -e 'yes\\n" + password + "\\n" + password + "' | " + init_cmd)

# Verify LUKS device was created (check first device)
first_device = block_devices.split(",")[0]
machine.succeed("cryptsetup isLuks " + first_device)
print("LUKS device(s) created successfully on block device(s)")

# Verify server is healthy
print("=== Verifying server health ===")
health = machine.succeed("curl -s http://127.0.0.1:13456/health")
assert '"status":"ok"' in health, f"Health check failed: {health}"
print("Server is healthy")

# Test the /list endpoint
print("=== Testing /list endpoint ===")
list_response = signer.make_signed_request(machine, "GET", "/list")
print(f"List response: {list_response}")
assert test_name in list_response, f"Mount '{test_name}' not found in list: {list_response}"
print("Mount found in /list endpoint")

# Test Phase 1: Mount via API using the actual module's systemd service
print("=== Test Phase 1: Mount via API (using module systemd unit) ===")

body = json.dumps({"password": password}, separators=(',', ':'))
response = signer.make_signed_request(machine, "POST", f"/mount/{test_name}", body)
print(f"Mount response: {response}")
assert '"success":true' in response, f"Mount failed: {response}"

# Wait for mount to complete - the module's actual service should handle this
machine.wait_until_succeeds(f"mountpoint -q {mount_point}", timeout=30)
print("Device mounted successfully via API using module's systemd unit")

# Verify the systemd service is active (RemainAfterExit=true)
service_status = machine.succeed(f"systemctl is-active secure-unlocker-{test_name}.service").strip()
assert service_status == "active", f"Service should be active after mount, got: {service_status}"
print("Module's systemd service is active after mount")

# Write test file
machine.succeed("echo '" + test_content + "' > " + mount_point + "/" + test_file)
print("Test file written")

# Verify file exists
result = machine.succeed("cat " + mount_point + "/" + test_file).strip()
assert result == test_content, f"Content mismatch: expected '{test_content}', got '{result}'"
print("Test file verified")

# Test Phase 2: Unmount via API
print("=== Test Phase 2: Unmount via API ===")

response = signer.make_signed_request(machine, "POST", f"/unmount/{test_name}")
print(f"Unmount response: {response}")
assert '"success":true' in response, f"Unmount failed: {response}"

# Wait for unmount to complete
machine.wait_until_fails(f"mountpoint -q {mount_point}", timeout=30)
print("Device unmounted successfully via API")

# Verify no LUKS device left behind (check all devices)
for i in range(num_devices):
    machine.succeed(f"test ! -e /dev/mapper/secure-unlocker-{test_name}-{i}")
print("LUKS device(s) correctly closed by module's cleanup script")

# Test Phase 3: Remount and verify persistence
print("=== Test Phase 3: Remount via API and verify persistence ===")

# Reset any failed state from the service
machine.succeed(f"systemctl reset-failed secure-unlocker-{test_name}.service 2>/dev/null || true")

body = json.dumps({"password": password}, separators=(',', ':'))
response = signer.make_signed_request(machine, "POST", f"/mount/{test_name}", body)
print(f"Remount response: {response}")
assert '"success":true' in response, f"Remount failed: {response}"

machine.wait_until_succeeds(f"mountpoint -q {mount_point}", timeout=30)
print("Device remounted successfully via API")

# Verify file persisted
result = machine.succeed("cat " + mount_point + "/" + test_file).strip()
assert result == test_content, f"Persistence check failed: expected '{test_content}', got '{result}'"
print("File persistence verified!")

# Test Phase 4: Final unmount
print("=== Test Phase 4: Final unmount via API ===")

response = signer.make_signed_request(machine, "POST", f"/unmount/{test_name}")
assert '"success":true' in response, f"Final unmount failed: {response}"
machine.wait_until_fails(f"mountpoint -q {mount_point}", timeout=30)
print("Final unmount successful")

# Test Phase 5: Test authentication failure
print("=== Test Phase 5: Verify authentication enforcement ===")

unauth_response = machine.succeed("curl -s -X POST -H 'Content-Type: application/json' "
                                  f"-d '{{\"password\":\"{password}\"}}' 'http://127.0.0.1:13456/mount/{test_name}'")
assert '"error"' in unauth_response and ('401' in unauth_response or 'Missing authentication' in unauth_response or 'Authentication' in unauth_response), \
    f"Unauthenticated request should have failed: {unauth_response}"
print("Authentication correctly enforced - unauthenticated request rejected")

# Cleanup
machine.succeed("rm -rf " + test_dir)

print("=== All Block Device tests passed! ===")
      '';
    };

in {
  #
  # Loop device tests (file-backed encryption)
  #

  # 1. ext4 loop device - single file-backed encrypted storage
  # LUKS2 requires ~16MB for headers, so we need at least 32M for a usable device
  integration-test-ext4-loop = mkLoopDeviceTest {
    name = "ext4";
    testSize = "32M";
    fsType = "ext4";
    numDevices = 1;
  };

  # 2. btrfs single loop device - single file-backed encrypted storage with btrfs
  # btrfs needs more space than ext4 for its metadata structures
  # btrfs minimum is ~125MB, plus LUKS2 overhead (~16MB), so we need at least 150MB
  integration-test-btrfs-loop = mkLoopDeviceTest {
    name = "btrfs";
    extraInitArgs = "--fsType btrfs";
    testSize = "192M";
    fsType = "btrfs";
    numDevices = 1;
  };

  # 3. btrfs raid1 multi loop - two file-backed encrypted devices with btrfs raid1
  # This tests the multi-device btrfs functionality with loop devices
  # Each device needs ~125MB for btrfs + ~16MB LUKS2 overhead
  integration-test-btrfs-raid1-loop = mkLoopDeviceTest {
    name = "btrfs-raid1";
    extraInitArgs = "--fsType btrfs --data-profile raid1 --metadata-profile raid1";
    testSize = "192M";
    fsType = "btrfs";
    numDevices = 2;
  };

  #
  # Block device tests (using virtualisation.emptyDiskImages)
  #

  # 4. ext4 block device - single block device encrypted storage
  # Uses /dev/vdb provided by NixOS VM test infrastructure
  integration-test-ext4-block = mkBlockDeviceTest {
    name = "ext4";
    diskSizeMB = 64;
    fsType = "ext4";
    numDevices = 1;
  };

  # 5. btrfs single block device - single block device with btrfs
  # btrfs minimum is ~125MB, plus LUKS2 overhead (~16MB), so we need at least 150MB
  integration-test-btrfs-block = mkBlockDeviceTest {
    name = "btrfs";
    extraInitArgs = "--fsType btrfs";
    diskSizeMB = 192;
    fsType = "btrfs";
    numDevices = 1;
  };

  # 6. btrfs raid1 multi block device - two block devices with btrfs raid1
  # Uses /dev/vdb and /dev/vdc provided by NixOS VM test infrastructure
  # Each device needs ~125MB for btrfs + ~16MB LUKS2 overhead
  integration-test-btrfs-raid1-block = mkBlockDeviceTest {
    name = "btrfs-raid1";
    extraInitArgs = "--fsType btrfs --data-profile raid1 --metadata-profile raid1";
    diskSizeMB = 192;
    fsType = "btrfs";
    numDevices = 2;
  };

  # Export the helpers for use in flake.nix
  inherit mkLoopDeviceTest mkBlockDeviceTest;
}
