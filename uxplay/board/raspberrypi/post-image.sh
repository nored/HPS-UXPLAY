#!/bin/bash
set -e

BOARD_DIR="$(dirname $0)"
BOARD_NAME="$(basename ${BOARD_DIR})"
GENIMAGE_CFG="${BOARD_DIR}/genimage-${BOARD_NAME}.cfg"
GENIMAGE_TMP="${BUILD_DIR}/genimage.tmp"

# =============================================================================
# OTA Update Configuration
# =============================================================================
# Private key location - check multiple places
if [ -f "${BOARD_DIR}/private_key.pem" ]; then
    SERVER_PRIVATE_KEY="${BOARD_DIR}/private_key.pem"
elif [ -f "${BR2_EXTERNAL_UXPLAY_PATH}/private_key.pem" ]; then
    SERVER_PRIVATE_KEY="${BR2_EXTERNAL_UXPLAY_PATH}/private_key.pem"
elif [ -f "$HOME/.ssh/private_key.pem" ]; then
    SERVER_PRIVATE_KEY="$HOME/.ssh/private_key.pem"
else
    SERVER_PRIVATE_KEY=""
fi

UPDATE_DIR="${BINARIES_DIR}/update"

# =============================================================================
# Copy fleet boot files to BINARIES_DIR (included in boot partition)
# =============================================================================
BOOT_FILES_DIR="${BOARD_DIR}/boot-files"
if [ -d "${BOOT_FILES_DIR}" ]; then
    echo "Copying fleet boot files from ${BOOT_FILES_DIR}..."
    cp -v "${BOOT_FILES_DIR}"/* "${BINARIES_DIR}/" 2>/dev/null || true
fi

# =============================================================================
# Create A/B root filesystem images
# =============================================================================
if [ -f "${BINARIES_DIR}/rootfs.ext4" ]; then
    echo "Creating A/B partition images..."
    cp "${BINARIES_DIR}/rootfs.ext4" "${BINARIES_DIR}/rootfsA.ext4"
    cp "${BINARIES_DIR}/rootfs.ext4" "${BINARIES_DIR}/rootfsB.ext4"
else
    echo "Error: rootfs.ext4 not found in ${BINARIES_DIR}. Aborting."
    exit 1
fi

# =============================================================================
# Generate genimage config from template
# =============================================================================
if [ ! -e "${GENIMAGE_CFG}" ]; then
    GENIMAGE_CFG="${BINARIES_DIR}/genimage.cfg"
    FILES=()
    
    for i in "${BINARIES_DIR}"/*.dtb "${BINARIES_DIR}"/rpi-firmware/*; do
        [ -e "$i" ] && FILES+=( "${i#${BINARIES_DIR}/}" )
    done
    
    KERNEL=$(sed -n 's/^kernel=//p' "${BINARIES_DIR}/rpi-firmware/config.txt")
    FILES+=( "${KERNEL}" )
    
    # Add fleet config files to boot partition
    [ -f "${BINARIES_DIR}/settings.cfg.example" ] && FILES+=( "settings.cfg.example" )
    [ -f "${BINARIES_DIR}/splash-template.png" ] && FILES+=( "splash-template.png" )
    
    BOOT_FILES=$(printf '\\t\\t\\t"%s",\\n' "${FILES[@]}")
    sed "s|#BOOT_FILES#|${BOOT_FILES}|" "${BOARD_DIR}/genimage.cfg.in" \
        > "${GENIMAGE_CFG}"
fi

# =============================================================================
# Generate SD card image
# =============================================================================
trap 'rm -rf "${ROOTPATH_TMP}"' EXIT
ROOTPATH_TMP="$(mktemp -d)"
rm -rf "${GENIMAGE_TMP}"

genimage \
    --rootpath "${ROOTPATH_TMP}"   \
    --tmppath "${GENIMAGE_TMP}"    \
    --inputpath "${BINARIES_DIR}"  \
    --outputpath "${BINARIES_DIR}" \
    --config "${GENIMAGE_CFG}"

echo "========================================"
echo "SD card image created: ${BINARIES_DIR}/sdcard.img"
echo "========================================"

# =============================================================================
# Create OTA Update Package (only if private key exists)
# =============================================================================
if [ -n "$SERVER_PRIVATE_KEY" ] && [ -f "$SERVER_PRIVATE_KEY" ]; then
    echo ""
    echo "Creating OTA update package..."
    rm -rf "$UPDATE_DIR"
    mkdir -p "$UPDATE_DIR"
    
    # Copy rootfs.ext4 for update
    cp "${BINARIES_DIR}/rootfs.ext4" "${UPDATE_DIR}/rootfs.ext4"
    
    # Generate SHA-256 checksum
    sha256sum "${UPDATE_DIR}/rootfs.ext4" | awk '{print $1}' > "${UPDATE_DIR}/rootfs.sha256"
    
    # Create compressed archive
    echo "Compressing update (this may take a while)..."
    tar -czf "${UPDATE_DIR}/update.tar.gz" -C "$UPDATE_DIR" rootfs.ext4 rootfs.sha256
    
    # Sign the package with the private key
    echo "Signing update package..."
    openssl dgst -sha256 -sign "$SERVER_PRIVATE_KEY" -out "${UPDATE_DIR}/signed_update.sig" "${UPDATE_DIR}/update.tar.gz"
    
    # Generate a symmetric key for encryption
    openssl rand 32 > "${UPDATE_DIR}/symmetric_key.txt"
    
    # Encrypt the update using AES-256 with the symmetric key
    echo "Encrypting update..."
    openssl enc -aes-256-cbc -salt -in "${UPDATE_DIR}/update.tar.gz" -out "${UPDATE_DIR}/update.enc.gz" -pass file:"${UPDATE_DIR}/symmetric_key.txt"
    
    # Combine: checksum (65 bytes) + symmetric key (32 bytes) + encrypted data
    cat "${UPDATE_DIR}/rootfs.sha256" "${UPDATE_DIR}/symmetric_key.txt" "${UPDATE_DIR}/update.enc.gz" > "${UPDATE_DIR}/signed_encrypted_update.pkg"
    
    # Copy final artifacts to BINARIES_DIR
    cp "${UPDATE_DIR}/signed_encrypted_update.pkg" "${BINARIES_DIR}/"
    cp "${UPDATE_DIR}/signed_update.sig" "${BINARIES_DIR}/"
    
    # Cleanup intermediate files
    rm -rf "$UPDATE_DIR"
    
    echo "========================================"
    echo "OTA Update package created:"
    echo "  ${BINARIES_DIR}/signed_encrypted_update.pkg"
    echo "  ${BINARIES_DIR}/signed_update.sig"
    echo ""
    echo "Upload both files to your update server/GitHub release"
    echo "========================================"
else
    echo ""
    echo "========================================"
    echo "Skipping OTA package creation (no private key found)"
    echo "To enable, place private_key.pem in one of:"
    echo "  - ${BOARD_DIR}/private_key.pem"
    echo "  - ${BR2_EXTERNAL_UXPLAY_PATH}/private_key.pem"
    echo "  - ~/.ssh/private_key.pem"
    echo "========================================"
fi

exit 0
