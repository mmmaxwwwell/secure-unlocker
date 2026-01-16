#!/usr/bin/env bash
set -euo pipefail

# Integration test for secure-unlocker
# This script runs a modular test that can be called with different options
# to test various configurations (e.g., different filesystems in the future)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test configuration
TEST_DIR="${TEST_DIR:-/tmp/secure-unlocker-test}"
TEST_NAME="${TEST_NAME:-test-mount}"
# LUKS2 requires ~16MB for headers, so we need at least 32M for a usable device
TEST_SIZE="${TEST_SIZE:-32M}"
TEST_PORT="${TEST_PORT:-13456}"
INIT_SCRIPT="${INIT_SCRIPT:-./result/bin/init-encrypted}"
SERVER_SCRIPT="${SERVER_SCRIPT:-}"

# Parse command line arguments for modularity
EXTRA_INIT_ARGS=""

show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --test-dir <path>       Directory for test files (default: /tmp/secure-unlocker-test)"
    echo "  --test-name <name>      Name for the test mount (default: test-mount)"
    echo "  --test-size <size>      Size of loop device (default: 4M)"
    echo "  --test-port <port>      Port for test server (default: 13456)"
    echo "  --init-script <path>    Path to init script (default: ./result/bin/init-encrypted)"
    echo "  --init-args <args>      Extra arguments to pass to init script"
    echo "  --help                  Show this help"
    echo ""
    echo "Example:"
    echo "  $0 --test-size 10M --init-args '--some-future-option value'"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --test-dir)
            TEST_DIR="$2"
            shift 2
            ;;
        --test-name)
            TEST_NAME="$2"
            shift 2
            ;;
        --test-size)
            TEST_SIZE="$2"
            shift 2
            ;;
        --test-port)
            TEST_PORT="$2"
            shift 2
            ;;
        --init-script)
            INIT_SCRIPT="$2"
            shift 2
            ;;
        --init-args)
            EXTRA_INIT_ARGS="$2"
            shift 2
            ;;
        --help)
            show_usage
            ;;
        *)
            echo "Unknown option: $1"
            show_usage
            ;;
    esac
done

# Derived paths
SOURCE_FILE="${TEST_DIR}/encrypted.img"
MOUNT_POINT="${TEST_DIR}/mnt"
PIPES_DIR="${TEST_DIR}/pipes"
PIPE_PATH="${PIPES_DIR}/${TEST_NAME}"
TEST_FILE_NAME="test-data.txt"
TEST_FILE_CONTENT="secure-unlocker-test-$(date +%s)-$RANDOM"

# Cleanup function
cleanup() {
    local exit_code=$?
    echo -e "${YELLOW}Cleaning up...${NC}"

    # Kill server if running
    if [ -n "${SERVER_PID:-}" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "Stopping test server (PID: $SERVER_PID)..."
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi

    # Unmount if mounted
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        echo "Unmounting $MOUNT_POINT..."
        umount "$MOUNT_POINT" 2>/dev/null || true
    fi

    # Close LUKS device if open
    if [ -e "/dev/mapper/secure-unlocker-${TEST_NAME}" ]; then
        echo "Closing LUKS device..."
        cryptsetup luksClose "secure-unlocker-${TEST_NAME}" 2>/dev/null || true
    fi

    # Detach loop devices
    if [ -f "$SOURCE_FILE" ]; then
        for loop in $(losetup -j "$SOURCE_FILE" 2>/dev/null | cut -d: -f1); do
            echo "Detaching loop device $loop..."
            losetup -d "$loop" 2>/dev/null || true
        done
    fi

    # Remove test directory
    if [ -d "$TEST_DIR" ]; then
        echo "Removing test directory..."
        rm -rf "$TEST_DIR"
    fi

    if [ $exit_code -eq 0 ]; then
        echo -e "${GREEN}Cleanup complete${NC}"
    else
        echo -e "${RED}Cleanup complete (test failed with exit code $exit_code)${NC}"
    fi

    exit $exit_code
}

trap cleanup EXIT

log_step() {
    echo -e "${GREEN}==>${NC} $1"
}

log_error() {
    echo -e "${RED}ERROR:${NC} $1" >&2
}

log_warning() {
    echo -e "${YELLOW}WARNING:${NC} $1"
}

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This test must be run as root (use sudo)"
        exit 1
    fi
}

# Generate a random password
generate_password() {
    # Generate a 32-character random password
    head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 32
}

# Set up test environment
setup_test_env() {
    log_step "Setting up test environment in $TEST_DIR"

    mkdir -p "$TEST_DIR"
    mkdir -p "$MOUNT_POINT"
    mkdir -p "$PIPES_DIR"

    # Create named pipe for test
    if [ ! -p "$PIPE_PATH" ]; then
        mkfifo "$PIPE_PATH"
    fi
    chmod 660 "$PIPE_PATH"
}

# Initialize encrypted loop device using the init script
init_encrypted_device() {
    local password="$1"

    log_step "Initializing encrypted loop device ($TEST_SIZE)"

    # Build the init command with any extra args
    local init_cmd="$INIT_SCRIPT --source $SOURCE_FILE --type loop --size $TEST_SIZE"
    if [ -n "$EXTRA_INIT_ARGS" ]; then
        init_cmd="$init_cmd $EXTRA_INIT_ARGS"
    fi

    # Run init script non-interactively by piping responses
    # The script expects: confirmation "yes", then password twice
    {
        echo "yes"      # Confirmation
        echo "$password" # Password
        echo "$password" # Password confirmation
    } | $init_cmd

    if [ $? -ne 0 ]; then
        log_error "Failed to initialize encrypted device"
        return 1
    fi

    log_step "Encrypted device initialized successfully"
}

# Create a minimal test server that mimics the real server behavior
# This allows testing without the full NixOS module infrastructure
start_test_server() {
    local password="$1"

    log_step "Starting test server on port $TEST_PORT"

    # Create a simple test server script
    cat > "${TEST_DIR}/test-server.sh" << 'SERVEREOF'
#!/usr/bin/env bash
set -euo pipefail

PORT="$1"
PIPES_DIR="$2"
MOUNT_POINT="$3"
SOURCE_FILE="$4"
TEST_NAME="$5"

MAPPER_NAME="secure-unlocker-${TEST_NAME}"
PIPE_PATH="${PIPES_DIR}/${TEST_NAME}"

# Simple HTTP server using netcat/bash
handle_request() {
    local request_line
    local content_length=0
    local body=""

    # Read request line
    read -r request_line
    request_line=$(echo "$request_line" | tr -d '\r')

    # Read headers
    while read -r header; do
        header=$(echo "$header" | tr -d '\r')
        [ -z "$header" ] && break
        if [[ "$header" =~ ^Content-Length:\ *([0-9]+) ]]; then
            content_length="${BASH_REMATCH[1]}"
        fi
    done

    # Read body if present
    if [ "$content_length" -gt 0 ]; then
        body=$(head -c "$content_length")
    fi

    # Parse request
    local method path
    read -r method path _ <<< "$request_line"

    case "$method $path" in
        "GET /health")
            echo -e "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"status\":\"ok\"}"
            ;;
        "POST /mount/${TEST_NAME}")
            # Extract password from JSON body
            local password
            password=$(echo "$body" | grep -oP '"password"\s*:\s*"\K[^"]+' || echo "")

            if [ -z "$password" ]; then
                echo -e "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\n\r\n{\"error\":\"Password required\"}"
                return
            fi

            # Check if already mounted
            if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
                echo -e "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\n\r\n{\"error\":\"Already mounted\"}"
                return
            fi

            # Set up loop device
            local loop_device
            loop_device=$(losetup --find --show "$SOURCE_FILE")

            # Unlock LUKS
            if ! echo -n "$password" | cryptsetup luksOpen "$loop_device" "$MAPPER_NAME" -; then
                losetup -d "$loop_device"
                echo -e "HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\n\r\n{\"error\":\"Failed to unlock\"}"
                return
            fi

            # Mount
            if ! mount "/dev/mapper/$MAPPER_NAME" "$MOUNT_POINT"; then
                cryptsetup luksClose "$MAPPER_NAME"
                losetup -d "$loop_device"
                echo -e "HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\n\r\n{\"error\":\"Failed to mount\"}"
                return
            fi

            echo -e "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"success\":true}"
            ;;
        "POST /unmount/${TEST_NAME}")
            # Check if mounted
            if ! mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
                echo -e "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\n\r\n{\"error\":\"Not mounted\"}"
                return
            fi

            # Unmount
            umount "$MOUNT_POINT"

            # Close LUKS
            cryptsetup luksClose "$MAPPER_NAME" 2>/dev/null || true

            # Detach loop devices
            for loop in $(losetup -j "$SOURCE_FILE" 2>/dev/null | cut -d: -f1); do
                losetup -d "$loop" 2>/dev/null || true
            done

            echo -e "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"success\":true}"
            ;;
        *)
            echo -e "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\n\r\n{\"error\":\"Not found\"}"
            ;;
    esac
}

# Main server loop
while true; do
    handle_request | nc -l -p "$PORT" -q 1 > /dev/null
done
SERVEREOF

    chmod +x "${TEST_DIR}/test-server.sh"

    # Start server in background
    "${TEST_DIR}/test-server.sh" "$TEST_PORT" "$PIPES_DIR" "$MOUNT_POINT" "$SOURCE_FILE" "$TEST_NAME" &
    SERVER_PID=$!

    # Wait for server to be ready
    local retries=10
    while [ $retries -gt 0 ]; do
        if curl -s "http://127.0.0.1:${TEST_PORT}/health" > /dev/null 2>&1; then
            log_step "Test server started (PID: $SERVER_PID)"
            return 0
        fi
        sleep 0.5
        retries=$((retries - 1))
    done

    log_error "Server failed to start"
    return 1
}

# Mount the encrypted device via HTTP API
mount_device() {
    local password="$1"

    log_step "Mounting encrypted device via API"

    local response
    response=$(curl -s -X POST "http://127.0.0.1:${TEST_PORT}/mount/${TEST_NAME}" \
        -H "Content-Type: application/json" \
        -d "{\"password\":\"${password}\"}")

    if echo "$response" | grep -q '"success":true'; then
        log_step "Mount successful"
        return 0
    else
        log_error "Mount failed: $response"
        return 1
    fi
}

# Unmount the encrypted device via HTTP API
unmount_device() {
    log_step "Unmounting encrypted device via API"

    local response
    response=$(curl -s -X POST "http://127.0.0.1:${TEST_PORT}/unmount/${TEST_NAME}" \
        -H "Content-Type: application/json")

    if echo "$response" | grep -q '"success":true'; then
        log_step "Unmount successful"
        return 0
    else
        log_error "Unmount failed: $response"
        return 1
    fi
}

# Write test file to mounted device
write_test_file() {
    log_step "Writing test file to mounted device"

    if ! mountpoint -q "$MOUNT_POINT"; then
        log_error "Mount point is not mounted"
        return 1
    fi

    echo "$TEST_FILE_CONTENT" > "${MOUNT_POINT}/${TEST_FILE_NAME}"

    if [ -f "${MOUNT_POINT}/${TEST_FILE_NAME}" ]; then
        log_step "Test file written successfully"
        return 0
    else
        log_error "Failed to write test file"
        return 1
    fi
}

# Verify test file content
verify_test_file() {
    log_step "Verifying test file content"

    if ! mountpoint -q "$MOUNT_POINT"; then
        log_error "Mount point is not mounted"
        return 1
    fi

    local content
    content=$(cat "${MOUNT_POINT}/${TEST_FILE_NAME}" 2>/dev/null || echo "")

    if [ "$content" = "$TEST_FILE_CONTENT" ]; then
        log_step "Test file content verified successfully"
        return 0
    else
        log_error "Test file content mismatch"
        log_error "Expected: $TEST_FILE_CONTENT"
        log_error "Got: $content"
        return 1
    fi
}

# Main test flow
main() {
    echo ""
    echo "========================================"
    echo "  Secure Unlocker Integration Test"
    echo "========================================"
    echo ""
    echo "Configuration:"
    echo "  Test directory: $TEST_DIR"
    echo "  Test name: $TEST_NAME"
    echo "  Loop device size: $TEST_SIZE"
    echo "  Server port: $TEST_PORT"
    echo "  Init script: $INIT_SCRIPT"
    if [ -n "$EXTRA_INIT_ARGS" ]; then
        echo "  Extra init args: $EXTRA_INIT_ARGS"
    fi
    echo ""

    check_root

    # Generate random password for this test
    local password
    password=$(generate_password)
    echo "Generated random password for test"
    echo ""

    # Run test steps
    setup_test_env
    init_encrypted_device "$password"
    start_test_server "$password"

    # Test 1: Mount, write file, unmount
    log_step "=== Test Phase 1: Initial mount and write ==="
    mount_device "$password"
    write_test_file
    unmount_device

    # Test 2: Remount and verify file persisted
    log_step "=== Test Phase 2: Remount and verify persistence ==="
    mount_device "$password"
    verify_test_file
    unmount_device

    echo ""
    echo -e "${GREEN}========================================"
    echo "  All tests passed!"
    echo "========================================${NC}"
    echo ""

    return 0
}

main "$@"
