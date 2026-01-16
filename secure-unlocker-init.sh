#!/usr/bin/env bash
set -euo pipefail

# Script to initialize encrypted storage using systemd-cryptenroll

# Parse arguments
show_usage() {
    echo "Usage: $0 --source <path> --type <type> [--size <size>] [--fsType <fsType>] [--data-profile <profile>] [--metadata-profile <profile>]"
    echo ""
    echo "Arguments:"
    echo "  --source <path>           Path to block device or file (comma-separated for multiple devices)"
    echo "  --type <type>             Type: 'block' or 'loop'"
    echo "  --size <size>             Size (required for loop type, e.g., 10G, 500M)"
    echo "  --fsType <fsType>         Filesystem type: 'ext4' or 'btrfs' (default: ext4)"
    echo "  --data-profile <profile>  Btrfs data profile: 'single', 'raid0', 'raid1', 'raid10' (default: raid1 for multi-device)"
    echo "  --metadata-profile <profile>  Btrfs metadata profile: 'single', 'raid0', 'raid1', 'raid10' (default: raid1 for multi-device)"
    echo ""
    echo "Examples:"
    echo "  $0 --source /dev/sdb1 --type block"
    echo "  $0 --source /dev/sdb1 --type block --fsType btrfs"
    echo "  $0 --source /dev/sdb1,/dev/sdc1 --type block --fsType btrfs"
    echo "  $0 --source /dev/sdb1,/dev/sdc1 --type block --fsType btrfs --data-profile raid1 --metadata-profile raid1"
    echo "  $0 --source /var/encrypted/storage.img --type loop --size 10G"
    echo "  $0 --source /var/encrypted/storage.img --type loop --size 10G --fsType btrfs"
    exit 1
}

# Parse command line arguments
SOURCE=""
TYPE=""
SIZE=""
FSTYPE="ext4"
DATA_PROFILE=""
METADATA_PROFILE=""

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
        --fsType)
            FSTYPE="$2"
            shift 2
            ;;
        --data-profile)
            DATA_PROFILE="$2"
            shift 2
            ;;
        --metadata-profile)
            METADATA_PROFILE="$2"
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

if [ "$FSTYPE" != "ext4" ] && [ "$FSTYPE" != "btrfs" ]; then
    echo "Error: --fsType must be 'ext4' or 'btrfs'"
    exit 1
fi

# Parse comma-separated sources
IFS=',' read -ra SOURCES <<< "$SOURCE"
NUM_SOURCES=${#SOURCES[@]}

# Validate multiple devices
if [ $NUM_SOURCES -gt 1 ]; then
    if [ "$FSTYPE" != "btrfs" ]; then
        echo "Error: Multiple devices (comma-separated) are only supported with btrfs filesystem"
        exit 1
    fi

    # Set default profiles for multi-device btrfs
    if [ -z "$DATA_PROFILE" ]; then
        DATA_PROFILE="raid1"
    fi
    if [ -z "$METADATA_PROFILE" ]; then
        METADATA_PROFILE="raid1"
    fi
fi

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run as root (use sudo)"
    exit 1
fi

echo "Source(s): $SOURCE"
echo "Number of devices: $NUM_SOURCES"
echo "Type: $TYPE"
if [ -n "$SIZE" ]; then
    echo "Size: $SIZE"
fi
echo "Filesystem Type: $FSTYPE"
if [ "$FSTYPE" = "btrfs" ] && [ $NUM_SOURCES -gt 1 ]; then
    echo "Data Profile: $DATA_PROFILE"
    echo "Metadata Profile: $METADATA_PROFILE"
fi
echo ""

# Check if sources already exist and are initialized
ALL_EXIST=true
SOME_EXIST=false
FIRST_LUKS_SOURCE=""

for SRC in "${SOURCES[@]}"; do
    if [ -e "$SRC" ]; then
        SOME_EXIST=true

        # For block devices, check if it's a block device
        if [ "$TYPE" = "block" ] && [ ! -b "$SRC" ]; then
            echo "Error: $SRC exists but is not a block device"
            exit 1
        fi

        # Check if it's a LUKS device
        if cryptsetup isLuks "$SRC" 2>/dev/null; then
            if [ -z "$FIRST_LUKS_SOURCE" ]; then
                FIRST_LUKS_SOURCE="$SRC"
            fi
        fi
    else
        ALL_EXIST=false
    fi
done

# If all sources exist and at least one is LUKS, offer to add password
if [ "$SOME_EXIST" = true ] && [ -n "$FIRST_LUKS_SOURCE" ]; then
    echo "Found existing LUKS device(s)."
    echo ""

    # Show current LUKS information for first device
    echo "Current LUKS information for $FIRST_LUKS_SOURCE:"
    cryptsetup luksDump "$FIRST_LUKS_SOURCE" | head -n 20
    echo ""

    read -p "Do you want to add a new password to all devices? (yes/no): " ADD_PASSWORD

    if [ "$ADD_PASSWORD" = "yes" ]; then
        echo ""
        for SRC in "${SOURCES[@]}"; do
            if cryptsetup isLuks "$SRC" 2>/dev/null; then
                echo "Adding new password to $SRC..."
                cryptsetup luksAddKey "$SRC"
                echo ""
            fi
        done
        echo "Password(s) added successfully!"
        exit 0
    else
        echo "No changes made."
        exit 0
    fi
fi

# Check for mixed state (some exist, some don't)
if [ "$SOME_EXIST" = true ] && [ "$ALL_EXIST" = false ]; then
    echo "Error: Some sources exist and some don't. All sources must either exist or not exist."
    for SRC in "${SOURCES[@]}"; do
        if [ -e "$SRC" ]; then
            echo "  EXISTS: $SRC"
        else
            echo "  MISSING: $SRC"
        fi
    done
    exit 1
fi

# Warn about existing non-LUKS devices
if [ "$SOME_EXIST" = true ]; then
    if [ "$TYPE" = "block" ]; then
        echo "Warning: Block device(s) exist but are not LUKS devices."
        echo "Proceeding will DESTROY all data on these devices!"
        for SRC in "${SOURCES[@]}"; do
            echo "  - $SRC"
        done
    else
        echo "Error: File(s) exist but are not LUKS devices."
        echo "Please remove them first or choose different paths."
        for SRC in "${SOURCES[@]}"; do
            echo "  - $SRC"
        done
        exit 1
    fi
fi

# Type-specific initialization
if [ "$TYPE" = "block" ]; then
    # Block device initialization
    # Verify all devices exist
    for SRC in "${SOURCES[@]}"; do
        if [ ! -b "$SRC" ]; then
            echo "Error: Block device $SRC does not exist"
            exit 1
        fi
    done

    echo "Initializing block device(s) with LUKS2 encryption..."
    for SRC in "${SOURCES[@]}"; do
        echo "  - $SRC"
    done
    echo ""
    echo "WARNING: This will DESTROY all data on these devices!"
    echo ""
    read -p "Are you sure you want to continue? (type 'yes' to confirm): " CONFIRM

    if [ "$CONFIRM" != "yes" ]; then
        echo "Aborted."
        exit 0
    fi

    echo ""
    echo "Initializing LUKS2 encryption..."
    echo ""

    # Read password once and reuse it for all devices
    read -s -p "Enter new LUKS password (will be used for all devices): " LUKS_PASSWORD
    echo ""
    read -s -p "Confirm LUKS password: " LUKS_PASSWORD_CONFIRM
    echo ""

    if [ "$LUKS_PASSWORD" != "$LUKS_PASSWORD_CONFIRM" ]; then
        echo "Error: Passwords do not match"
        exit 1
    fi

    # Format all devices with LUKS2
    for i in "${!SOURCES[@]}"; do
        SRC="${SOURCES[$i]}"
        echo ""
        echo "Formatting device $((i+1))/$NUM_SOURCES: $SRC..."

        echo -n "$LUKS_PASSWORD" | cryptsetup luksFormat --type luks2 "$SRC" -

        if [ $? -ne 0 ]; then
            echo "Error: Failed to format device $SRC with LUKS2"
            exit 1
        fi
        echo "Successfully formatted $SRC"
    done

elif [ "$TYPE" = "loop" ]; then
    # Loop device (file-backed) initialization

    # Create parent directories if they don't exist
    for SRC in "${SOURCES[@]}"; do
        PARENT_DIR=$(dirname "$SRC")
        if [ ! -d "$PARENT_DIR" ]; then
            echo "Creating parent directory: $PARENT_DIR"
            mkdir -p "$PARENT_DIR"
        fi
    done

    echo "Creating encrypted file-backed storage..."
    echo "This will create $NUM_SOURCES file(s) of size $SIZE:"
    for SRC in "${SOURCES[@]}"; do
        echo "  - $SRC"
    done
    echo ""
    read -p "Are you sure you want to continue? (type 'yes' to confirm): " CONFIRM

    if [ "$CONFIRM" != "yes" ]; then
        echo "Aborted."
        exit 0
    fi

    echo ""
    echo "Step 1: Creating sparse files of size $SIZE..."
    for i in "${!SOURCES[@]}"; do
        SRC="${SOURCES[$i]}"
        echo "Creating file $((i+1))/$NUM_SOURCES: $SRC..."
        truncate -s "$SIZE" "$SRC"

        if [ $? -ne 0 ]; then
            echo "Error: Failed to create file $SRC"
            # Clean up any files we created
            for j in $(seq 0 $((i-1))); do
                rm -f "${SOURCES[$j]}"
            done
            exit 1
        fi
    done

    echo ""
    echo "Step 2: Initializing LUKS2 encryption..."
    echo ""

    # Read password once and reuse it for all files
    read -s -p "Enter new LUKS password (will be used for all files): " LUKS_PASSWORD
    echo ""
    read -s -p "Confirm LUKS password: " LUKS_PASSWORD_CONFIRM
    echo ""

    if [ "$LUKS_PASSWORD" != "$LUKS_PASSWORD_CONFIRM" ]; then
        echo "Error: Passwords do not match"
        # Clean up all files
        for SRC in "${SOURCES[@]}"; do
            rm -f "$SRC"
        done
        exit 1
    fi

    # Format all files with LUKS2
    for i in "${!SOURCES[@]}"; do
        SRC="${SOURCES[$i]}"
        echo ""
        echo "Formatting file $((i+1))/$NUM_SOURCES: $SRC..."

        echo -n "$LUKS_PASSWORD" | cryptsetup luksFormat --type luks2 "$SRC" -

        if [ $? -ne 0 ]; then
            echo "Error: Failed to format file $SRC with LUKS2"
            # Clean up all files
            for CLEANUP_SRC in "${SOURCES[@]}"; do
                rm -f "$CLEANUP_SRC"
            done
            exit 1
        fi
        echo "Successfully formatted $SRC"
    done
fi

echo ""
echo "LUKS2 encryption initialized successfully!"
echo ""

# Create filesystem on the encrypted devices
echo "Creating $FSTYPE filesystem..."
echo "Opening the encrypted device(s) temporarily..."

# Generate temporary mapper names and open all devices
TEMP_MAPPERS=()
for i in "${!SOURCES[@]}"; do
    SRC="${SOURCES[$i]}"
    TEMP_MAPPER="temp-init-$(basename "$SRC" | sed 's/[^a-zA-Z0-9]/-/g')-$i"
    TEMP_MAPPERS+=("$TEMP_MAPPER")

    echo "Opening device $((i+1))/$NUM_SOURCES: $SRC as $TEMP_MAPPER..."
    echo -n "$LUKS_PASSWORD" | cryptsetup luksOpen "$SRC" "$TEMP_MAPPER" -

    if [ $? -ne 0 ]; then
        echo "Error: Failed to open encrypted device $SRC"
        # Close any mappers we already opened
        for j in $(seq 0 $((i-1))); do
            cryptsetup luksClose "${TEMP_MAPPERS[$j]}" 2>/dev/null || true
        done
        exit 1
    fi
done

# Clear password from memory
unset LUKS_PASSWORD LUKS_PASSWORD_CONFIRM

# Create the filesystem
echo ""
if [ "$FSTYPE" = "ext4" ]; then
    echo "Creating ext4 filesystem..."
    mkfs.ext4 "/dev/mapper/${TEMP_MAPPERS[0]}"
elif [ "$FSTYPE" = "btrfs" ]; then
    echo "Creating btrfs filesystem..."

    # Build device list for mkfs.btrfs
    DEVICE_ARGS=()
    for MAPPER in "${TEMP_MAPPERS[@]}"; do
        DEVICE_ARGS+=("/dev/mapper/$MAPPER")
    done

    # Create btrfs with RAID profiles if multiple devices
    if [ $NUM_SOURCES -gt 1 ]; then
        echo "Data profile: $DATA_PROFILE"
        echo "Metadata profile: $METADATA_PROFILE"
        mkfs.btrfs -d "$DATA_PROFILE" -m "$METADATA_PROFILE" "${DEVICE_ARGS[@]}"
    else
        mkfs.btrfs "${DEVICE_ARGS[@]}"
    fi
fi

if [ $? -ne 0 ]; then
    echo "Error: Failed to create filesystem"
    # Close all mappers
    for MAPPER in "${TEMP_MAPPERS[@]}"; do
        cryptsetup luksClose "$MAPPER" 2>/dev/null || true
    done
    exit 1
fi

# Close all devices
for MAPPER in "${TEMP_MAPPERS[@]}"; do
    cryptsetup luksClose "$MAPPER"
done

echo ""
echo "Initialization complete!"
echo ""
echo "Source(s): $SOURCE"
echo "Number of devices: $NUM_SOURCES"
echo "Type: $TYPE"
if [ -n "$SIZE" ]; then
    echo "Size: $SIZE"
fi
echo "Encryption: LUKS2"
echo "Filesystem: $FSTYPE"
if [ "$FSTYPE" = "btrfs" ] && [ $NUM_SOURCES -gt 1 ]; then
    echo "Data Profile: $DATA_PROFILE"
    echo "Metadata Profile: $METADATA_PROFILE"
fi
echo ""
echo "You can now use systemd-cryptenroll to add additional unlock methods:"
if [ $NUM_SOURCES -eq 1 ]; then
    echo "  systemd-cryptenroll --tpm2-device=auto $SOURCE"
    echo "  systemd-cryptenroll --fido2-device=auto $SOURCE"
else
    echo "  # For each device:"
    for SRC in "${SOURCES[@]}"; do
        echo "  systemd-cryptenroll --tpm2-device=auto $SRC"
    done
fi
echo ""
echo "To open and mount the device(s) manually:"
if [ $NUM_SOURCES -eq 1 ]; then
    echo "  cryptsetup luksOpen $SOURCE <name>"
    echo "  mount /dev/mapper/<name> /mount/point"
else
    echo "  # Unlock all devices:"
    for i in "${!SOURCES[@]}"; do
        SRC="${SOURCES[$i]}"
        echo "  cryptsetup luksOpen $SRC <name>-$i"
    done
    echo "  # Mount (btrfs will auto-detect all devices):"
    echo "  mount /dev/mapper/<name>-0 /mount/point"
fi
echo ""
echo "To close the device(s):"
echo "  umount /mount/point"
if [ $NUM_SOURCES -eq 1 ]; then
    echo "  cryptsetup luksClose <name>"
else
    for i in "${!SOURCES[@]}"; do
        echo "  cryptsetup luksClose <name>-$i"
    done
fi
