#!/bin/sh
# =============================================================================
# UxPlay Fleet - OTA Update Script (A/B Partition)
# =============================================================================
# Checks for updates, downloads, verifies, and flashes to inactive partition
# Supports GitHub releases or custom mirror server

# =============================================================================
# Configuration - can be overridden by /boot/update.conf or /etc/update.conf
# =============================================================================
# Default: GitHub releases
UPDATE_MODE="github"
REPO="nored/apserver"

# Alternative: Custom mirror server
# UPDATE_MODE="mirror"
# MIRROR_URL="https://updates.example.com/uxplay"

# Load config from boot partition or /etc
if [ -f "/boot/update.conf" ]; then
    . /boot/update.conf
elif [ -f "/etc/update.conf" ]; then
    . /etc/update.conf
fi

# =============================================================================
# Paths and files
# =============================================================================
BOOT_PART_DEV="/dev/mmcblk0p1"
BOOT_MOUNT="/mnt/boot"
NEW_PART_MOUNT="/mnt/newpart"
CMDLINE_FILE="${BOOT_MOUNT}/cmdline.txt"
VERSION_FILE="${BOOT_MOUNT}/current_version"
PUBLIC_KEY="/etc/apserver/public_key.pem"
UPDATE_DIR="/tmp/update"
PACKAGE_FILE="${UPDATE_DIR}/signed_encrypted_update.pkg"
SIGNATURE_FILE="${UPDATE_DIR}/signed_update.sig"
SYMMETRIC_KEY_FILE="${UPDATE_DIR}/symmetric_key.txt"
DECRYPTED_UPDATE="${UPDATE_DIR}/update.tar.gz"

# =============================================================================
# Functions
# =============================================================================

get_latest_version_github() {
    LATEST_RELEASE_URL="https://api.github.com/repos/${REPO}/releases/latest"
    curl -s -k "$LATEST_RELEASE_URL" | grep '"tag_name":' | cut -d'"' -f4
}

get_latest_version_mirror() {
    curl -s -k "${MIRROR_URL}/latest_version.txt"
}

download_update_github() {
    local version="$1"
    echo "Downloading from GitHub release ${version}..."
    curl -k -L -o "$PACKAGE_FILE" "https://github.com/${REPO}/releases/download/${version}/signed_encrypted_update.pkg"
    curl -k -L -o "$SIGNATURE_FILE" "https://github.com/${REPO}/releases/download/${version}/signed_update.sig"
}

download_update_mirror() {
    local version="$1"
    echo "Downloading from mirror ${MIRROR_URL}..."
    curl -k -L -o "$PACKAGE_FILE" "${MIRROR_URL}/${version}/signed_encrypted_update.pkg"
    curl -k -L -o "$SIGNATURE_FILE" "${MIRROR_URL}/${version}/signed_update.sig"
}

cleanup() {
    echo "Cleaning up..."
    rm -rf "$UPDATE_DIR"
    umount "$BOOT_MOUNT" 2>/dev/null || true
    umount "$NEW_PART_MOUNT" 2>/dev/null || true
}

# =============================================================================
# Main Script
# =============================================================================

# Cleanup on exit
trap cleanup EXIT

# Create directories
rm -rf "$UPDATE_DIR"
mkdir -p "$UPDATE_DIR" "$BOOT_MOUNT" "$NEW_PART_MOUNT"

# Check for public key
if [ ! -f "$PUBLIC_KEY" ]; then
    echo "Error: Public key not found at $PUBLIC_KEY"
    echo "OTA updates require a public key for signature verification."
    exit 1
fi

# Get latest version based on update mode
echo "Checking for updates (mode: ${UPDATE_MODE})..."
case "$UPDATE_MODE" in
    github)
        LATEST_VERSION=$(get_latest_version_github)
        ;;
    mirror)
        LATEST_VERSION=$(get_latest_version_mirror)
        ;;
    *)
        echo "Error: Unknown UPDATE_MODE: $UPDATE_MODE"
        exit 1
        ;;
esac

if [ -z "$LATEST_VERSION" ]; then
    echo "Error: Could not determine latest version"
    exit 1
fi

echo "Latest version available: $LATEST_VERSION"

# Mount boot partition to check current version
mount "$BOOT_PART_DEV" "$BOOT_MOUNT"
CURRENT_VERSION=$(cat "$VERSION_FILE" 2>/dev/null || echo "none")

echo "Current version: $CURRENT_VERSION"

if [ "$LATEST_VERSION" = "$CURRENT_VERSION" ]; then
    echo "Already running the latest version. No update needed."
    exit 0
fi

echo ""
echo "New version available: $LATEST_VERSION"
echo "Downloading update package..."

# Download based on mode
case "$UPDATE_MODE" in
    github)
        download_update_github "$LATEST_VERSION"
        ;;
    mirror)
        download_update_mirror "$LATEST_VERSION"
        ;;
esac

# Verify downloads
if [ ! -f "$PACKAGE_FILE" ] || [ ! -f "$SIGNATURE_FILE" ]; then
    echo "Error: Failed to download update files"
    exit 1
fi

# =============================================================================
# Extract and decrypt package
# =============================================================================
echo "Extracting update package..."

# Package format: rootfs.sha256 (65 bytes) + symmetric_key (32 bytes) + encrypted data
# Extract rootfs.sha256 (64 hex chars + newline = 65 bytes)
dd if="$PACKAGE_FILE" of="${UPDATE_DIR}/rootfs.sha256" bs=1 count=65 2>/dev/null

# Extract symmetric_key.txt (32 bytes) - starts after SHA256
dd if="$PACKAGE_FILE" of="$SYMMETRIC_KEY_FILE" bs=1 count=32 skip=65 2>/dev/null

# Extract update.enc.gz (remaining data) - starts after SHA256 + key
dd if="$PACKAGE_FILE" of="${UPDATE_DIR}/update.enc.gz" bs=4096 skip=97 iflag=skip_bytes 2>/dev/null

# Cleanup package file
rm -f "$PACKAGE_FILE"

echo "Decrypting update..."
openssl enc -d -aes-256-cbc -in "${UPDATE_DIR}/update.enc.gz" -out "$DECRYPTED_UPDATE" -pass file:"$SYMMETRIC_KEY_FILE"
if [ $? -ne 0 ]; then
    echo "Error: Update decryption failed!"
    exit 1
fi

rm -f "${UPDATE_DIR}/update.enc.gz" "$SYMMETRIC_KEY_FILE"

# =============================================================================
# Verify signature
# =============================================================================
echo "Verifying package signature..."
openssl dgst -sha256 -verify "$PUBLIC_KEY" -signature "$SIGNATURE_FILE" "$DECRYPTED_UPDATE"
if [ $? -ne 0 ]; then
    echo "Error: Signature verification failed! Update may be tampered."
    exit 1
fi

rm -f "$SIGNATURE_FILE"
echo "Signature verified successfully."

# =============================================================================
# Extract rootfs
# =============================================================================
echo "Extracting root filesystem..."
gzip -d "$DECRYPTED_UPDATE"
tar -xf "${UPDATE_DIR}/update.tar" -C "$UPDATE_DIR" rootfs.ext4

rm -f "${UPDATE_DIR}/update.tar"

# =============================================================================
# Verify checksum
# =============================================================================
echo "Verifying rootfs checksum..."
CALCULATED_HASH=$(sha256sum "${UPDATE_DIR}/rootfs.ext4" | awk '{print $1}')
STORED_HASH=$(cat "${UPDATE_DIR}/rootfs.sha256" | tr -d '\n')

if [ "$CALCULATED_HASH" != "$STORED_HASH" ]; then
    echo "Error: Checksum verification failed!"
    echo "Expected: $STORED_HASH"
    echo "Got:      $CALCULATED_HASH"
    exit 1
fi

echo "Checksum verified successfully."

# =============================================================================
# Determine inactive partition and flash
# =============================================================================
CURRENT_PART=$(grep -o 'root=/dev/mmcblk0p[23]' "$CMDLINE_FILE" | cut -d'p' -f2)
if [ "$CURRENT_PART" = "2" ]; then
    INACTIVE_PART="/dev/mmcblk0p3"
    NEXT_CMDLINE="root=/dev/mmcblk0p3 rootwait loglevel=3 vt.global_cursor_default=0 console=tty3"
else
    INACTIVE_PART="/dev/mmcblk0p2"
    NEXT_CMDLINE="root=/dev/mmcblk0p2 rootwait loglevel=3 vt.global_cursor_default=0 console=tty3"
fi

echo ""
echo "Current partition: /dev/mmcblk0p${CURRENT_PART}"
echo "Flashing update to: $INACTIVE_PART"
echo ""

dd if="${UPDATE_DIR}/rootfs.ext4" of="$INACTIVE_PART" bs=4M status=progress
if [ $? -ne 0 ]; then
    echo "Error: Flashing failed!"
    exit 1
fi

sync

# =============================================================================
# Update boot config
# =============================================================================
echo "Updating boot configuration..."
echo "$NEXT_CMDLINE" > "$CMDLINE_FILE"
echo "$LATEST_VERSION" > "$VERSION_FILE"

# =============================================================================
# Preserve settings on new partition
# =============================================================================
echo "Preserving settings..."
mount "$INACTIVE_PART" "$NEW_PART_MOUNT"

# Copy settings to new partition (will be processed on next boot)
if [ -f "/etc/settings.cfg" ]; then
    cp /etc/settings.cfg "${NEW_PART_MOUNT}/etc/settings_upd.cfg"
fi

# Copy uxplay config
if [ -d "/etc/uxplay" ]; then
    mkdir -p "${NEW_PART_MOUNT}/etc/uxplay"
    cp -r /etc/uxplay/* "${NEW_PART_MOUNT}/etc/uxplay/" 2>/dev/null || true
fi

# Remove lockfile so preparesettings doesn't re-run unnecessarily
# (config already migrated)
touch "${NEW_PART_MOUNT}/etc/preparesettings.lock"

umount "$NEW_PART_MOUNT"
umount "$BOOT_MOUNT"

# =============================================================================
# Reboot
# =============================================================================
echo ""
echo "========================================"
echo "Update complete! Version: $LATEST_VERSION"
echo "Rebooting into updated system..."
echo "========================================"

sync
sync
sleep 2
echo 1 > /proc/sys/kernel/sysrq 2>/dev/null || true
echo b > /proc/sysrq-trigger

exit 0
