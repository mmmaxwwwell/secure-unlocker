# Secure Unlocker

A NixOS module for remotely unlocking LUKS-encrypted storage devices through a secure web API with Ed25519 public key authentication.

## Features

- Remote unlocking of LUKS-encrypted block devices and file-backed loop devices
- Ed25519 public key cryptography for authentication (secure to store in Nix store)
- Rate limiting to prevent brute force attacks
- Progressive Web App (PWA) for mobile access with automatic key pair generation
- Automatic systemd service management for encrypted mounts
- Secure password transmission through named pipes
- Clean mount/unmount with proper LUKS device cleanup

## Installation

### Using with Nix Flakes (Recommended)

Add this repository as a flake input in your `flake.nix`:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    secure-unlocker = {
      url = "github:mmmaxwwwell/secure-unlocker";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, secure-unlocker, ... }: {
    nixosConfigurations.your-hostname = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        secure-unlocker.nixosModules.default
        ./configuration.nix
      ];
    };
  };
}
```

Then in your `configuration.nix`, configure the module:

```nix
{ config, lib, pkgs, ... }:

{
  services.secure-unlocker = {
    enable = true;
    allowedPublicKeys = [
      "a1b2c3d4e5f6789..."  # Your public key from the PWA
    ];
    mounts = {
      my-backup-drive = {
        type = "block";
        source = "/dev/sdb1";
        mountPoint = "/mnt/backup";
        fsType = "ext4";  # Optional, defaults to ext4
      };
      # Multi-device btrfs with RAID1 for redundancy
      redundant-storage = {
        type = "block";
        source = "/dev/sdc1,/dev/sdd1";  # Comma-separated devices
        mountPoint = "/mnt/redundant";
        fsType = "btrfs";
      };
    };
  };
}
```

### Using without Flakes (Traditional Nix)

Add the module to your NixOS configuration using `fetchTarball`:

```nix
{ config, lib, pkgs, ... }:

{
  imports = [
    "${fetchTarball "https://github.com/mmmaxwwwell/secure-unlocker/archive/main.tar.gz"}/module.nix"
  ];

  services.secure-unlocker = {
    enable = true;
    allowedPublicKeys = [
      "a1b2c3d4e5f6789..."  # Your public key from the PWA
    ];
    mounts = {
      my-backup-drive = {
        type = "block";
        source = "/dev/sdb1";
        mountPoint = "/mnt/backup";
        fsType = "ext4";  # Optional, defaults to ext4
      };
      # Multi-device btrfs with RAID1 for redundancy
      redundant-storage = {
        type = "block";
        source = "/dev/sdc1,/dev/sdd1";  # Comma-separated devices
        mountPoint = "/mnt/redundant";
        fsType = "btrfs";
      };
    };
  };
}
```

For more reproducibility, you can pin to a specific commit:

```nix
imports = [
  "${fetchTarball "https://github.com/mmmaxwwwell/secure-unlocker/archive/COMMIT_HASH.tar.gz"}/module.nix"
];
```

After adding the module, rebuild your system:

```bash
sudo nixos-rebuild switch
```

## Architecture

The module consists of:
- **Express API Server**: Handles authentication and mount/unmount requests
- **Systemd Services**: One service per mount that waits for passwords via named pipes
- **Init Script**: `secure-unlocker-init` for setting up encrypted devices
- **Web Interface**: PWA for remote access

## Quick Start

### 1. Initialize an Encrypted Device

Run `secure-unlocker-init` on your NixOS machine as root to create a LUKS-encrypted device:

#### For a block device (e.g., external drive):

```bash
sudo secure-unlocker-init --source /dev/sdb1 --type block
```

This will:
1. Check if the device exists
2. Warn that all data will be destroyed
3. Prompt for confirmation
4. Ask you to set a LUKS password
5. Format the device with LUKS2 encryption
6. Create an ext4 filesystem inside (default)

To use btrfs instead:
```bash
sudo secure-unlocker-init --source /dev/sdb1 --type block --fsType btrfs
```

To use btrfs with multiple devices for redundancy (RAID1):
```bash
sudo secure-unlocker-init --source /dev/sdb1,/dev/sdc1 --type block --fsType btrfs
```

This will create a btrfs filesystem with RAID1 profiles (default for multi-device). You can customize the RAID profiles:
```bash
sudo secure-unlocker-init --source /dev/sdb1,/dev/sdc1 --type block --fsType btrfs --data-profile raid1 --metadata-profile raid1
```

#### For a file-backed loop device:

```bash
sudo secure-unlocker-init --source /var/encrypted/storage.img --type loop --size 10G
```

This will:
1. Create parent directories if needed
2. Create a sparse file of the specified size
3. Initialize LUKS2 encryption
4. Create an ext4 filesystem inside (default)

To use btrfs instead:
```bash
sudo secure-unlocker-init --source /var/encrypted/storage.img --type loop --size 10G --fsType btrfs
```

To use btrfs with multiple loop devices for redundancy:
```bash
sudo secure-unlocker-init --source /var/encrypted/storage1.img,/var/encrypted/storage2.img --type loop --size 10G --fsType btrfs
```

#### Adding additional passwords to existing devices:

If you run `secure-unlocker-init` on an already-initialized device, it will detect this and offer to add an additional password:

```bash
sudo secure-unlocker-init --source /dev/sdb1 --type block
# Detects existing LUKS device and prompts: "Do you want to add a new password?"
```

### 2. Generate Authentication Key Pair

The PWA automatically generates an Ed25519 key pair for you on first use. To get your public key:

1. Open the web interface in your browser (requires HTTPS or localhost)
2. Click the settings gear icon in the bottom right corner of the page
3. Your public key will be displayed (64-character hex string)
4. Click "Copy to Clipboard" to copy it

**Note:** The private key stays securely in your browser's localStorage and never leaves your device. Only the public key needs to be added to your server configuration.

### 3. Configure the NixOS Module

See the [Installation](#installation) section above for how to add the module to your system. Configure your encrypted mounts in your `configuration.nix`:

```nix
services.secure-unlocker = {
  enable = true;
  listenAddress = "127.0.0.1";  # Only listen on localhost (default)
  port = 3456;                   # Default port

  # Add the public keys from your PWA clients
  allowedPublicKeys = [
    "a1b2c3d4e5f6789..."  # 64-character hex string from your PWA
  ];

  # Define your encrypted mounts
  mounts = {
    my-backup-drive = {
      type = "block";
      source = "/dev/sdb1";
      mountPoint = "/mnt/backup";
      fsType = "ext4";  # Optional, defaults to ext4
    };

    secret-storage = {
      type = "loop";
      source = "/var/encrypted/storage.img";
      mountPoint = "/mnt/secrets";
      fsType = "btrfs";  # Use btrfs filesystem
    };
  };
};
```

Rebuild your system:
```bash
sudo nixos-rebuild switch
```

### 4. Configure Nginx for SSL (Optional but Recommended)

To access the secure-unlocker from outside localhost, wrap it with nginx for SSL:

```nix
services.nginx = {
  enable = true;
  recommendedGzipSettings = true;
  recommendedOptimisation = true;
  recommendedProxySettings = true;
  recommendedTlsSettings = true;

  virtualHosts = {
    "unlocker.example.com" = {
      # Listen on standard HTTPS port
      listen = [
        {
          ssl = true;
          port = 443;
          addr = "0.0.0.0";  # Or your specific IP
        }
      ];

      forceSSL = true;

      # Use your SSL certificates
      sslCertificate = "/path/to/fullchain.pem";
      sslCertificateKey = "/path/to/privkey.pem";

      # Or use Let's Encrypt (recommended)
      enableACME = true;

      # Proxy to the local secure-unlocker service
      locations = {
        "/" = {
          proxyPass = "http://127.0.0.1:${toString config.services.secure-unlocker.port}";
          proxyWebsockets = true;
        };
      };
    };
  };
}
```

For Let's Encrypt certificates:
```nix
security.acme = {
  acceptTerms = true;
  defaults.email = "your-email@example.com";
};
```

## Configuration Reference

### Module Options

#### `services.secure-unlocker.enable`
- Type: `boolean`
- Default: `false`
- Description: Enable the secure-unlocker service

#### `services.secure-unlocker.listenAddress`
- Type: `string`
- Default: `"127.0.0.1"`
- Description: IP address for the API server to bind to
- Example: `"0.0.0.0"` to listen on all interfaces (not recommended without nginx)

#### `services.secure-unlocker.port`
- Type: `port`
- Default: `3456`
- Description: Port for the API server to listen on

#### `services.secure-unlocker.allowedPublicKeys`
- Type: `list of string`
- Default: `[]`
- Description: List of allowed Ed25519 public keys (64-character hex strings)
- Each public key is a 32-byte Ed25519 public key encoded as hexadecimal
- Generated automatically by the PWA client (see settings gear icon)
- Safe to store in the Nix store and commit to version control
- Example:
  ```nix
  allowedPublicKeys = [
    "a1b2c3d4e5f6..."  # First authorized client (phone)
    "f6e5d4c3b2a1..."  # Second authorized client (laptop)
  ];
  ```

#### `services.secure-unlocker.mounts`
- Type: `attribute set of mount options`
- Default: `{}`
- Description: Encrypted mounts to manage
- Each mount has a unique name and configuration

##### Mount Options

###### `type`
- Type: `enum ["loop", "block"]`
- Required: Yes
- Description: Type of encrypted storage
  - `"block"`: Block device (e.g., `/dev/sdb1`)
  - `"loop"`: File-backed storage (e.g., `/var/storage.img`)

###### `source`
- Type: `string` (absolute path or comma-separated paths)
- Required: Yes
- Description: Path to the encrypted device or file
  - Single device: `"/dev/sdb1"` or `"/var/encrypted/storage.img"`
  - Multiple devices (btrfs only): `"/dev/sdb1,/dev/sdc1"` for redundancy
- Must be an absolute path (or paths) starting with `/`
- Multiple devices are only supported with `fsType = "btrfs"`
- For ext4, only a single device is allowed
- Examples: `"/dev/sdb1"`, `"/var/encrypted/storage.img"`, `"/dev/sdb1,/dev/sdc1"`

###### `mountPoint`
- Type: `string` (absolute path)
- Required: Yes
- Description: Where the decrypted filesystem will be mounted
- Must be an absolute path starting with `/`
- The directory will be created automatically if it doesn't exist
- Example: `"/mnt/backup"`

###### `fsType`
- Type: `enum ["ext4", "btrfs"]`
- Required: No
- Default: `"ext4"`
- Description: Filesystem type for the encrypted device
- Valid values:
  - `"ext4"`: ext4 filesystem (default)
  - `"btrfs"`: btrfs filesystem
- Example: `"btrfs"`

### Example Configuration

```nix
services.secure-unlocker = {
  enable = true;
  allowedPublicKeys = [
    "a1b2c3d4e5f6789..."  # Public key from PWA
  ];
  mounts = {
    external-backup = {
      type = "block";
      source = "/dev/disk/by-uuid/12345678-1234-1234-1234-123456789abc";
      mountPoint = "/mnt/external-backup";
      fsType = "ext4";  # Optional, defaults to ext4
    };

    encrypted-data = {
      type = "loop";
      source = "/var/lib/encrypted/data.img";
      mountPoint = "/mnt/encrypted-data";
      fsType = "btrfs";  # Use btrfs filesystem
    };

    # Btrfs with multiple devices for redundancy (RAID1)
    redundant-backup = {
      type = "block";
      source = "/dev/sdb1,/dev/sdc1";  # Comma-separated for multi-device
      mountPoint = "/mnt/redundant-backup";
      fsType = "btrfs";  # Required for multi-device
    };
  };
};
```

## API Reference

All API endpoints (except static files, `/health`, and `/`) require Ed25519 signature authentication.

### Rate Limiting

The API implements rate limiting to prevent brute force attacks:

- **Authentication failures**: Limited to 20 failed authentication attempts per IP per 15 minutes
  - Only counts failed signature verifications
  - Successful authentication does not count against this limit
- **Mount/unmount operations**: Strictly limited to 10 failed mount attempts per IP per 15 minutes
  - Only counts failed mount operations (wrong password, errors, etc.)
  - Successful mounts do not count against this limit

Rate limit headers are included in responses:
- `RateLimit-Limit`: Maximum number of requests allowed
- `RateLimit-Remaining`: Number of requests remaining in current window
- `RateLimit-Reset`: Time when the rate limit window resets (Unix timestamp)

When rate limited, you'll receive a `429 Too Many Requests` response for authentication failures:
```json
{
  "error": "Too many failed authentication attempts, please try again later"
}
```

or for mount operations:
```json
{
  "error": "Too many failed mount attempts, please try again later"
}
```

### Authentication

The API uses Ed25519 digital signatures for authentication.

Required headers:
- `X-Signature`: Ed25519 signature (64-byte signature encoded as hex)
- `X-Timestamp`: Unix timestamp when the request was created
- `X-Public-Key`: Ed25519 public key (32-byte key encoded as hex)

The signature is computed over the message:
```
METHOD:PATH:TIMESTAMP:BODYHASH
```

Where:
- `METHOD`: HTTP method (GET, POST, etc.)
- `PATH`: Request path (e.g., `/list`, `/mount/my-drive`)
- `TIMESTAMP`: Unix timestamp from the `X-Timestamp` header
- `BODYHASH`: SHA-256 hex hash of the request body (empty string if no body)

The server verifies:
1. The public key is in the `allowedPublicKeys` list
2. The timestamp is within 5 minutes of server time (prevents replay attacks)
3. The Ed25519 signature is valid for the message

Signatures expire after 5 minutes to prevent replay attacks.

### Endpoints

#### `GET /health`
Health check endpoint (no authentication required).

**Response:**
```json
{
  "status": "ok"
}
```

#### `GET /list`
List all configured mounts and their status.

**Response:**
```json
{
  "my-backup-drive": "mounted",
  "secret-storage": "unmounted"
}
```

#### `POST /mount/:name`
Mount an encrypted device.

**Parameters:**
- `name` (path parameter): Name of the mount as defined in configuration
- Must match `^[a-zA-Z0-9._-]+$`

**Request body:**
```json
{
  "password": "your-luks-password"
}
```

**Success response:**
```json
{
  "success": true
}
```

**Error responses:**
- `400`: Invalid name format, missing password, or already mounted
- `401`: Authentication failed
- `500`: Failed to mount (wrong password, device error, etc.)

#### `POST /unmount/:name`
Unmount an encrypted device.

**Parameters:**
- `name` (path parameter): Name of the mount to unmount

**Success response:**
```json
{
  "success": true
}
```

**Error responses:**
- `400`: Invalid name format or mount not active
- `401`: Authentication failed
- `500`: Failed to unmount

## Using the Web Interface

The module includes a Progressive Web App (PWA) that can be installed on mobile devices:

1. Navigate to `https://unlocker.example.com` (or your configured domain)
2. Tap "Install" or "Add to Home Screen" when prompted
3. The PWA automatically generates an Ed25519 key pair on first use
4. View your public key by clicking the gear icon in the bottom right
5. Copy the public key and add it to your NixOS config's `allowedPublicKeys` list
6. The private key is stored securely in your browser/app and never leaves your device
7. Select mounts and enter passwords to unlock them

The PWA provides a mobile-friendly interface for managing your encrypted mounts.

## Security Considerations

### Public Key Cryptography

- Uses Ed25519 for digital signatures (modern, secure, and fast)
- Private keys never leave the client device (stored in browser localStorage)
- Public keys can be safely stored in the Nix store and version control
- No shared secrets means no risk from world-readable Nix store
- Multiple public keys can be configured to allow different clients/devices
- Compromised server cannot be used to impersonate clients

### Network Security

- Always use nginx with SSL/TLS to protect traffic
- The API server binds to `127.0.0.1` by default for security
- Use a VPN (like Tailscale/Headscale) or firewall rules to restrict access
- Consider using client certificates in nginx for additional security

### Password Handling

- Passwords are transmitted once via named pipes and not stored
- Pipes are owned by `root:secure-unlocker` with restricted permissions
- The server runs as a dedicated `secure-unlocker` user with minimal privileges
- Systemd security hardening is applied (PrivateTmp, ProtectSystem, etc.)

### Signature Verification

- Ed25519 signatures provide cryptographic proof of authenticity
- Signatures include timestamps to prevent replay attacks (5-minute window)
- The signature covers the entire request (method, path, timestamp, body hash)
- Public key must be in the authorized list
- Rate limiting prevents brute force attacks:
  - 20 failed authentication attempts per 15 minutes per IP
  - 10 failed mount attempts per 15 minutes per IP
- Only failed attempts count against rate limits
- Successful operations do not consume rate limit quota

## Troubleshooting

### Check service status

```bash
# Check the main API server
sudo systemctl status secure-unlocker-server

# Check a specific mount service
sudo systemctl status secure-unlocker-my-backup-drive
```

### View logs

```bash
# API server logs
sudo journalctl -u secure-unlocker-server -f

# Mount service logs
sudo journalctl -u secure-unlocker-my-backup-drive -f
```

### Common issues

#### "Address not available" errors
The service retries for 60 seconds if the listen address isn't available yet (common on boot). If it persists, check that the IP address is configured on your system.

#### Mount fails with "Already mounted"
The device is already mounted. Check with:
```bash
findmnt /mnt/your-mount-point
```

Unmount via the API or manually:
```bash
sudo systemctl stop secure-unlocker-my-backup-drive
```

#### "Invalid signature" errors
- Verify the public key is in the server's `allowedPublicKeys` list
- Check that system clocks are synchronized (timestamp validation requires 5-minute accuracy)
- Ensure you're accessing the site via HTTPS or localhost (required for Web Crypto API)
- Try regenerating your key pair if the private key was corrupted

#### "Too many failed authentication attempts" or "Too many failed mount attempts" errors
- You've hit one of the rate limits:
  - 20 failed authentication attempts per 15 minutes
  - 10 failed mount attempts per 15 minutes
- Only failed operations count against these limits
- Wait for the rate limit window to reset (check `RateLimit-Reset` header)
- If using nginx as a reverse proxy, ensure the real client IP is being forwarded correctly
- Rate limits are per IP address, so different clients/devices should not interfere with each other

#### Mount service stuck in failed state
Reset the service:
```bash
sudo systemctl reset-failed secure-unlocker-my-backup-drive
```

### Manual operations

If needed, you can manually interact with encrypted devices:

```bash
# Open a LUKS device
sudo cryptsetup luksOpen /dev/sdb1 my-device-name

# Mount it
sudo mount /dev/mapper/my-device-name /mnt/mountpoint

# Unmount
sudo umount /mnt/mountpoint

# Close LUKS device
sudo cryptsetup luksClose my-device-name
```

## Advanced Usage

### Multiple Client Devices

You can configure multiple public keys to allow different clients:

```nix
allowedPublicKeys = [
  "pubkey1..."  # Phone PWA
  "pubkey2..."  # Laptop browser
  "pubkey3..."  # Tablet
];
```

Each client device has its own Ed25519 key pair. To add a new device:
1. Open the PWA on the new device (generates a key pair automatically)
2. Copy the public key from the settings
3. Add it to `allowedPublicKeys` in your NixOS config
4. Rebuild the system

To revoke a device:
1. Remove its public key from `allowedPublicKeys`
2. Rebuild the system
3. The device will no longer be able to authenticate

### Adding Additional LUKS Passwords

LUKS supports up to 8 key slots. Add additional passwords:

```bash
sudo cryptsetup luksAddKey /dev/sdb1
```

Or using the init script on an existing device:
```bash
sudo secure-unlocker-init --source /dev/sdb1 --type block
```

### Btrfs Multi-Device Support for Redundancy

Btrfs supports using multiple block devices to provide data redundancy through RAID profiles. This is useful for protecting against drive failures.

#### Setting Up Multi-Device Btrfs

Use the init script to create a multi-device encrypted btrfs filesystem:

```bash
# Create RAID1 btrfs across two devices (data and metadata mirrored)
sudo secure-unlocker-init --source /dev/sdb1,/dev/sdc1 --type block --fsType btrfs

# Explicitly specify RAID profiles
sudo secure-unlocker-init --source /dev/sdb1,/dev/sdc1 --type block --fsType btrfs \
  --data-profile raid1 --metadata-profile raid1
```

Available RAID profiles:
- `single`: No redundancy (default for single device)
- `raid0`: Striping (improved performance, no redundancy)
- `raid1`: Mirroring (default for multi-device, can survive one drive failure)
- `raid10`: Striping + Mirroring (requires 4+ devices)

#### Configure in NixOS

```nix
services.secure-unlocker = {
  enable = true;
  mounts = {
    redundant-storage = {
      type = "block";
      source = "/dev/sdb1,/dev/sdc1";  # Comma-separated devices
      mountPoint = "/mnt/redundant";
      fsType = "btrfs";
    };
  };
};
```

#### Important Notes

- All devices must be LUKS-encrypted with the **same password**
- The init script will format all devices with LUKS2 and create a unified btrfs filesystem
- When mounting, all encrypted devices are unlocked automatically
- Btrfs will automatically detect and use all devices in the filesystem
- If one device fails (in RAID1), your data remains accessible on the other device
- Multiple devices are **only** supported with btrfs (ext4 requires a single device)

#### Loop Device Multi-Device Example

You can also use multiple loop devices (file-backed):

```bash
sudo secure-unlocker-init --source /var/encrypted/storage1.img,/var/encrypted/storage2.img \
  --type loop --size 10G --fsType btrfs
```

### Using with Tailscale/Headscale

Configure nginx to listen on your Tailscale IP:

```nix
virtualHosts."unlocker.example.com" = {
  listen = [{
    ssl = true;
    port = 443;
    addr = "100.64.x.x";  # Your Tailscale IP
  }];
  # ... rest of config
};
```

### Systemd Integration

Each mount gets its own systemd service (`secure-unlocker-<name>.service`) and target (`secure-unlocker-<name>-mounted.target`).

You can create dependent services:

```nix
systemd.services.my-backup-service = {
  after = [ "secure-unlocker-my-backup-drive-mounted.target" ];
  requires = [ "secure-unlocker-my-backup-drive-mounted.target" ];
  # ... service that needs the encrypted mount
};
```

## Development

### Running Integration Tests

The project includes integration tests that run in a NixOS VM. These tests verify the complete workflow: creating an encrypted loop device, mounting it, writing data, unmounting, remounting, and verifying data persistence.

Available tests:
- `integration-test`: Basic ext4 test
- `integration-test-btrfs`: Single-device btrfs test
- `integration-test-btrfs-raid1`: Multi-device btrfs with RAID1

#### Using Flakes

```bash
# Run all checks (includes all integration tests)
nix flake check

# Build and run a specific test
nix build .#checks.x86_64-linux.integration-test
nix build .#checks.x86_64-linux.integration-test-btrfs
nix build .#checks.x86_64-linux.integration-test-btrfs-raid1

# Run with verbose output
nix build .#checks.x86_64-linux.integration-test-btrfs-raid1 --print-build-logs
```

#### Without Flakes (Traditional Nix)

```bash
# Run all integration tests
nix-build tests.nix

# Run a specific test
nix-build tests.nix -A integration-test
nix-build tests.nix -A integration-test-btrfs
nix-build tests.nix -A integration-test-btrfs-raid1

# Run with verbose output
nix-build tests.nix -A integration-test-btrfs-raid1 2>&1 | tee test.log
```

#### Standalone Script

For quick local testing (requires root):

```bash
# Build the init script first
nix build

# Run the standalone test script
sudo ./integration-test.sh

# With custom options
sudo ./integration-test.sh --test-size 64M --init-args '--some-future-option'
```

### Adding New Tests

Tests are defined in `tests.nix` using the `mkIntegrationTest` helper function. This makes it easy to add tests for different configurations (e.g., different filesystem types):

```nix
# In tests.nix
{
  # Existing ext4 test
  integration-test = mkIntegrationTest {
    name = "ext4";
    testSize = "32M";
  };

  # Example: Add a btrfs test when filesystem option is implemented
  integration-test-btrfs = mkIntegrationTest {
    name = "btrfs";
    extraInitArgs = "--filesystem btrfs";
    testSize = "64M";  # btrfs needs more space
  };
}
```

Then add the new test to `flake.nix`:

```nix
checks = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] (system:
  let
    tests = import ./tests.nix { /* ... */ };
  in {
    inherit (tests) integration-test integration-test-btrfs;
  }
);
```

### Test Configuration

The `mkIntegrationTest` function accepts the following parameters:

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `name` | string | required | Test name suffix (e.g., "ext4" creates "secure-unlocker-ext4") |
| `testSize` | string | "32M" | Size of the test loop device (must be ≥32M for LUKS2 headers) |
| `extraInitArgs` | string | "" | Additional arguments passed to `secure-unlocker-init` |
