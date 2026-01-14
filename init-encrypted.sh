#!/usr/bin/env bash
set -euo pipefail

# Script to initialize encrypted storage using systemd-cryptenroll

# Parse arguments
show_usage() {
    echo "Usage: $0 --source <path> --type <type> [--size <size>]"
    echo ""
    echo "Arguments:"
    echo "  --source <path>   Path to block device or file"
    echo "  --type <type>     Type: 'block' or 'loop'"
    echo "  --size <size>     Size (required for loop type, e.g., 10G, 500M)"
    echo ""
    echo "Examples:"
    echo "  $0 --source /dev/sdb1 --type block"
    echo "  $0 --source /var/encrypted/storage.img --type loop --size 10G"
    exit 1
}

# Parse command line arguments
SOURCE=""
TYPE=""
SIZE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --source)
            SOURCE="$2"
            shift 2
            ;;
        --type)
            TYPE="$2"
            shift 2
            ;;
        --size)
            SIZE="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            show_usage
            ;;
    esac
done

# Validate required arguments
if [ -z "$SOURCE" ] || [ -z "$TYPE" ]; then
    echo "Error: --source and --type are required"
    show_usage
fi

if [ "$TYPE" != "block" ] && [ "$TYPE" != "loop" ]; then
    echo "Error: --type must be 'block' or 'loop'"
    exit 1
fi

if [ "$TYPE" = "loop" ] && [ -z "$SIZE" ]; then
    echo "Error: --size is required when --type is 'loop'"
    exit 1
fi

if [ "$TYPE" = "block" ] && [ -n "$SIZE" ]; then
    echo "Error: --size should not be specified when --type is 'block'"
    exit 1
fi

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run as root (use sudo)"
    exit 1
fi

echo "Source: $SOURCE"
echo "Type: $TYPE"
if [ -n "$SIZE" ]; then
    echo "Size: $SIZE"
fi
echo ""

# Check if source already exists and is initialized
if [ -e "$SOURCE" ]; then
    echo "Source $SOURCE already exists."
    echo ""

    # For block devices, check if it's a block device
    if [ "$TYPE" = "block" ] && [ ! -b "$SOURCE" ]; then
        echo "Error: $SOURCE exists but is not a block device"
        exit 1
    fi

    # Check if it's a LUKS device
    if cryptsetup isLuks "$SOURCE" 2>/dev/null; then
        echo "Source is already initialized as a LUKS device."
        echo ""

        # Show current LUKS information
        echo "Current LUKS information:"
        cryptsetup luksDump "$SOURCE" | head -n 20
        echo ""

        read -p "Do you want to add a new password to this device? (yes/no): " ADD_PASSWORD

        if [ "$ADD_PASSWORD" = "yes" ]; then
            echo ""
            echo "Adding new password to existing LUKS device..."
            cryptsetup luksAddKey "$SOURCE"
            echo ""
            echo "Password added successfully!"
        else
            echo "No changes made."
        fi
        exit 0
    else
        if [ "$TYPE" = "block" ]; then
            echo "Warning: Block device exists but is not a LUKS device."
            echo "Proceeding will DESTROY all data on this device!"
        else
            echo "File exists but is not a LUKS device."
            echo "Please remove it first or choose a different path."
            exit 1
        fi
    fi
fi

# Type-specific initialization
if [ "$TYPE" = "block" ]; then
    # Block device initialization
    if [ ! -b "$SOURCE" ]; then
        echo "Error: Block device $SOURCE does not exist"
        exit 1
    fi

    echo "Initializing block device $SOURCE with LUKS2 encryption..."
    echo "WARNING: This will DESTROY all data on $SOURCE!"
    echo ""
    read -p "Are you sure you want to continue? (type 'yes' to confirm): " CONFIRM

    if [ "$CONFIRM" != "yes" ]; then
        echo "Aborted."
        exit 0
    fi

    echo ""
    echo "Initializing LUKS2 encryption..."
    echo ""

    # Read password once and reuse it
    read -s -p "Enter new LUKS password: " LUKS_PASSWORD
    echo ""
    read -s -p "Confirm LUKS password: " LUKS_PASSWORD_CONFIRM
    echo ""

    if [ "$LUKS_PASSWORD" != "$LUKS_PASSWORD_CONFIRM" ]; then
        echo "Error: Passwords do not match"
        exit 1
    fi

    # Format the device with LUKS2
    echo -n "$LUKS_PASSWORD" | cryptsetup luksFormat --type luks2 "$SOURCE" -

    if [ $? -ne 0 ]; then
        echo "Error: Failed to format device with LUKS2"
        exit 1
    fi

elif [ "$TYPE" = "loop" ]; then
    # Loop device (file-backed) initialization

    # Create parent directory if it doesn't exist
    PARENT_DIR=$(dirname "$SOURCE")
    if [ ! -d "$PARENT_DIR" ]; then
        echo "Creating parent directory: $PARENT_DIR"
        mkdir -p "$PARENT_DIR"
    fi

    echo "Creating encrypted file-backed storage..."
    echo "This will create a $SIZE file at $SOURCE"
    echo ""
    read -p "Are you sure you want to continue? (type 'yes' to confirm): " CONFIRM

    if [ "$CONFIRM" != "yes" ]; then
        echo "Aborted."
        exit 0
    fi

    echo ""
    echo "Step 1: Creating sparse file of size $SIZE..."
    truncate -s "$SIZE" "$SOURCE"

    if [ $? -ne 0 ]; then
        echo "Error: Failed to create file"
        exit 1
    fi

    echo ""
    echo "Step 2: Initializing LUKS2 encryption..."
    echo ""

    # Read password once and reuse it
    read -s -p "Enter new LUKS password: " LUKS_PASSWORD
    echo ""
    read -s -p "Confirm LUKS password: " LUKS_PASSWORD_CONFIRM
    echo ""

    if [ "$LUKS_PASSWORD" != "$LUKS_PASSWORD_CONFIRM" ]; then
        echo "Error: Passwords do not match"
        rm -f "$SOURCE"
        exit 1
    fi

    # Format the file with LUKS2
    echo -n "$LUKS_PASSWORD" | cryptsetup luksFormat --type luks2 "$SOURCE" -

    if [ $? -ne 0 ]; then
        echo "Error: Failed to format file with LUKS2"
        rm -f "$SOURCE"
        exit 1
    fi
fi

echo ""
echo "LUKS2 encryption initialized successfully!"
echo ""

# Create filesystem on the encrypted device
echo "Creating ext4 filesystem..."
echo "Opening the encrypted device temporarily..."

# Generate a temporary mapper name
TEMP_MAPPER="temp-init-$(basename "$SOURCE" | sed 's/[^a-zA-Z0-9]/-/g')"

echo -n "$LUKS_PASSWORD" | cryptsetup luksOpen "$SOURCE" "$TEMP_MAPPER" -

if [ $? -ne 0 ]; then
    echo "Error: Failed to open encrypted device"
    exit 1
fi

# Clear password from memory
unset LUKS_PASSWORD LUKS_PASSWORD_CONFIRM

# Create the filesystem
mkfs.ext4 "/dev/mapper/$TEMP_MAPPER"

if [ $? -ne 0 ]; then
    echo "Error: Failed to create filesystem"
    cryptsetup luksClose "$TEMP_MAPPER"
    exit 1
fi

# Close the device
cryptsetup luksClose "$TEMP_MAPPER"

echo ""
echo "Initialization complete!"
echo ""
echo "Source: $SOURCE"
echo "Type: $TYPE"
if [ -n "$SIZE" ]; then
    echo "Size: $SIZE"
fi
echo "Encryption: LUKS2"
echo "Filesystem: ext4"
echo ""
echo "You can now use systemd-cryptenroll to add additional unlock methods:"
echo "  systemd-cryptenroll --tpm2-device=auto $SOURCE"
echo "  systemd-cryptenroll --fido2-device=auto $SOURCE"
echo ""
echo "To open the device:"
echo "  cryptsetup luksOpen $SOURCE <name>"
echo "  mount /dev/mapper/<name> /mount/point"
echo ""
echo "To close the device:"
echo "  umount /mount/point"
echo "  cryptsetup luksClose <name>"
