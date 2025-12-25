#!/bin/sh
set -u
set -e

# =============================================================================
# UxPlay Fleet - Post Build Script
# =============================================================================

# Cleanup default consoles
sed -i '31,34d' ${TARGET_DIR}/etc/inittab
echo >> ${TARGET_DIR}/etc/inittab

# -----------------------------------------------------------------------------
# Fleet Mode vs Debug Mode
# -----------------------------------------------------------------------------
# FLEET_MODE=true  → Production with MQTT management
# FLEET_MODE=false → Console/debug mode

export FLEET_MODE=${FLEET_MODE:-true}
export CONSOLE=${CONSOLE:-false}

if [ "$FLEET_MODE" = "true" ]; then
    # ==========================================================================
    # FLEET MODE: UxPlay managed by MQTT agent
    # ==========================================================================
    echo "# Fleet Mode - MQTT Agent manages UxPlay" >> ${TARGET_DIR}/etc/inittab
    
    # Initial provisioning (runs once, then lockfile prevents re-run)
    echo "::respawn:/usr/bin/preparesettings.sh" >> ${TARGET_DIR}/etc/inittab
    
    # UxPlay agent (respawns if it dies)
    echo "::respawn:/usr/bin/uxplay-agent" >> ${TARGET_DIR}/etc/inittab
    
    # Optional: console for maintenance
    if [ "$CONSOLE" = "true" ]; then
        echo "tty1::respawn:/sbin/getty -L tty1 0 vt100" >> ${TARGET_DIR}/etc/inittab
    fi
    
elif [ "$CONSOLE" = "true" ]; then
    # ==========================================================================
    # DEBUG MODE: Console access, manual UxPlay
    # ==========================================================================
    echo "# Debug Mode - Console access" >> ${TARGET_DIR}/etc/inittab
    echo "console::respawn:/sbin/getty -L console 0 vt100" >> ${TARGET_DIR}/etc/inittab
    echo "tty1::respawn:/sbin/getty -L tty1 0 vt100" >> ${TARGET_DIR}/etc/inittab
    
else
    # ==========================================================================
    # STANDALONE MODE: Direct UxPlay (original behavior)
    # ==========================================================================
    echo "# Standalone Mode - Direct UxPlay" >> ${TARGET_DIR}/etc/inittab
    echo "::respawn:/usr/bin/uxplay -nh -n UXPLAY" >> ${TARGET_DIR}/etc/inittab
fi

echo >> ${TARGET_DIR}/etc/inittab

# -----------------------------------------------------------------------------
# Boot partition mounting
# -----------------------------------------------------------------------------
echo "# Mount boot partition" >> ${TARGET_DIR}/etc/inittab
echo "::sysinit:/bin/sh -c 'mkdir -p /boot && mount /dev/disk/by-label/bootfs /boot'" >> ${TARGET_DIR}/etc/inittab

# Copy splash template from boot partition
echo "::sysinit:/bin/sh -c 'mkdir -p /usr/share/uxplay && cp /boot/splash-template.png /usr/share/uxplay/ 2>/dev/null || true'" >> ${TARGET_DIR}/etc/inittab

# -----------------------------------------------------------------------------
# Network DHCP
# -----------------------------------------------------------------------------
# Ethernet: wait for interface then run udhcpc (USB adapters take time to enumerate)
# WiFi: iwd handles DHCP via EnableNetworkConfiguration=true in /etc/iwd/main.conf
echo "# DHCP for USB Ethernet (waits for interface)" >> ${TARGET_DIR}/etc/inittab
echo "::respawn:/bin/sh -c 'while ! ip link show eth0 2>/dev/null; do sleep 2; done; exec udhcpc -i eth0 -R -f'" >> ${TARGET_DIR}/etc/inittab

# -----------------------------------------------------------------------------
# Create required directories
# -----------------------------------------------------------------------------
mkdir -p ${TARGET_DIR}/etc/uxplay
mkdir -p ${TARGET_DIR}/etc/apserver
mkdir -p ${TARGET_DIR}/etc/iwd
mkdir -p ${TARGET_DIR}/usr/share/uxplay

# -----------------------------------------------------------------------------
# Default configs (used if no settings.cfg provided)
# These can be completely overridden by placing settings.cfg on boot partition
# -----------------------------------------------------------------------------

# Default UxPlay config
cat > ${TARGET_DIR}/etc/uxplay/config.json <<EOF
{
  "room_name": "Unconfigured",
  "hostname": "",
  "pin_mode": "none",
  "pin": "0000",
  "resolution": "1024x768",
  "fps": 30,
  "vsync": 0,
  "volume": 0.3,
  "videosink": "kmssink force_modesetting=true",
  "audiosink": "autoaudiosink",
  "color_space": "bt709",
  "extra_opts": "",
  "enabled": true,
  "config_version": "default",
  "splash": {
    "room_coords": "+100+650",
    "pin_coords": "+100+720",
    "font_size": 48,
    "font_color": "black"
  }
}
EOF

# Default MQTT config
cat > ${TARGET_DIR}/etc/uxplay/mqtt.conf <<EOF
MQTT_BROKER=mqtt.local
MQTT_PORT=1883
EOF

# Default OTA update config
cat > ${TARGET_DIR}/etc/update.conf <<EOF
UPDATE_MODE=github
REPO=nored/apserver
EOF

# -----------------------------------------------------------------------------
# Make scripts executable
# -----------------------------------------------------------------------------
chmod +x ${TARGET_DIR}/usr/bin/uxplay-agent 2>/dev/null || true
chmod +x ${TARGET_DIR}/usr/bin/uxplay-wrapper 2>/dev/null || true
chmod +x ${TARGET_DIR}/usr/bin/preparesettings.sh 2>/dev/null || true
chmod +x ${TARGET_DIR}/usr/bin/gen_conf 2>/dev/null || true
chmod +x ${TARGET_DIR}/usr/bin/update.sh 2>/dev/null || true

echo "Post-build complete. FLEET_MODE=$FLEET_MODE CONSOLE=$CONSOLE"
