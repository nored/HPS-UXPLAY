#!/bin/sh
# =============================================================================
# UxPlay Fleet - Unified Provisioning Script
# =============================================================================
# Single config file handles everything:
#   - Network (WiFi or LAN-only)
#   - UxPlay settings (room name, PIN, resolution)
#   - MQTT broker
#   - OTA updates
#   - Splash screen
#
# Place settings.cfg on boot partition, device auto-configures on first boot

CONFIG_FILE="/etc/settings.cfg"
TMP_CONFIG_FILE="/tmp/settings.cfg"
UPDATE_CONF_FILE="/etc/settings_upd.cfg"
BOOT_CONFIG_FILE="/boot/settings.cfg"
LOCK_FILE="/etc/preparesettings.lock"

# iwd
IWD_DIR="/var/lib/iwd"
GEN_CONF_SCRIPT="/usr/bin/gen_conf"
IWD_INIT="/etc/init.d/S40iwd"
IWD_DISABLED="/root/S40iwd.disabled"

# Output configs
UXPLAY_CONFIG="/etc/uxplay/config.json"
MQTT_CONFIG="/etc/uxplay/mqtt.conf"
UPDATE_CONFIG="/etc/update.conf"

POLL_INTERVAL=5

# Check if already configured
if [ -f "$LOCK_FILE" ]; then
    echo "Already configured. Exiting."
    exit 0
fi

# -----------------------------------------------------------------------------
# Wait for config file
# -----------------------------------------------------------------------------
while true; do
    # Check boot partition first
    if [ -f "$BOOT_CONFIG_FILE" ]; then
        echo "Found config on boot partition"
        cp "$BOOT_CONFIG_FILE" "$TMP_CONFIG_FILE"
        rm "$BOOT_CONFIG_FILE"
    fi
    
    # Check for OTA-migrated config
    if [ -f "$UPDATE_CONF_FILE" ]; then
        mv "$UPDATE_CONF_FILE" "$TMP_CONFIG_FILE"
    fi
    
    if [ -f "$TMP_CONFIG_FILE" ]; then
        echo "Processing configuration..."
        mv "$TMP_CONFIG_FILE" "$CONFIG_FILE"
        
        # -----------------------------------------------------------------
        # Parse all configuration values with defaults
        # -----------------------------------------------------------------
        NAME=""
        LANONLY="no"
        SSID=""
        PASSPHRASE=""
        
        PIN="0000"
        PIN_MODE="none"
        PASSWORD=""
        PASSWORD_MODE="none"
        
        MQTT_BROKER="mqtt.local"
        MQTT_PORT="1883"
        MQTT_USER=""
        MQTT_PASS=""
        
        UPDATE_MODE="github"
        UPDATE_REPO="nored/apserver"
        UPDATE_MIRROR_URL=""
        
        RESOLUTION="1920x1080"
        FPS="30"
        VSYNC="0"
        VOLUME="0.3"
        VIDEOSINK="kmssink force_modesetting=true"
        AUDIOSINK="autoaudiosink"
        COLOR_SPACE="bt709"
        UXPLAY_EXTRA=""
        
        SPLASH_ROOM_COORDS="+100+650"
        SPLASH_PIN_COORDS="+100+720"
        SPLASH_FONT_SIZE="48"
        SPLASH_FONT_COLOR="black"
        
        while IFS='=' read -r key value; do
            # Skip comments and empty lines
            case "$key" in
                \#*|"") continue ;;
            esac
            # Remove quotes
            value=$(echo "$value" | sed 's/^"//; s/"$//' | sed "s/^'//; s/'$//")
            case "$key" in
                NAME) NAME="$value" ;;
                LANONLY) LANONLY="$value" ;;
                SSID) SSID="$value" ;;
                PASSPHRASE) PASSPHRASE="$value" ;;
                PIN) PIN="$value" ;;
                PIN_MODE) PIN_MODE="$value" ;;
                PASSWORD) PASSWORD="$value" ;;
                PASSWORD_MODE) PASSWORD_MODE="$value" ;;
                MQTT_BROKER) MQTT_BROKER="$value" ;;
                MQTT_PORT) MQTT_PORT="$value" ;;
                MQTT_USER) MQTT_USER="$value" ;;
                MQTT_PASS) MQTT_PASS="$value" ;;
                UPDATE_MODE) UPDATE_MODE="$value" ;;
                UPDATE_REPO) UPDATE_REPO="$value" ;;
                UPDATE_MIRROR_URL) UPDATE_MIRROR_URL="$value" ;;
                RESOLUTION) RESOLUTION="$value" ;;
                FPS) FPS="$value" ;;
                VSYNC) VSYNC="$value" ;;
                VOLUME) VOLUME="$value" ;;
                VIDEOSINK) VIDEOSINK="$value" ;;
                AUDIOSINK) AUDIOSINK="$value" ;;
                COLOR_SPACE) COLOR_SPACE="$value" ;;
                UXPLAY_EXTRA) UXPLAY_EXTRA="$value" ;;
                SPLASH_ROOM_COORDS) SPLASH_ROOM_COORDS="$value" ;;
                SPLASH_PIN_COORDS) SPLASH_PIN_COORDS="$value" ;;
                SPLASH_FONT_SIZE) SPLASH_FONT_SIZE="$value" ;;
                SPLASH_FONT_COLOR) SPLASH_FONT_COLOR="$value" ;;
            esac
        done < "$CONFIG_FILE"
        
        # -----------------------------------------------------------------
        # Validate required fields
        # -----------------------------------------------------------------
        if [ -z "$NAME" ]; then
            echo "Error: NAME is required in settings.cfg"
            rm -f "$CONFIG_FILE" "$LOCK_FILE"
            sync && sleep 2 && reboot
            exit 1
        fi
        
        # -----------------------------------------------------------------
        # Handle WiFi / LAN-only mode
        # -----------------------------------------------------------------
        if [ "$LANONLY" = "yes" ] || [ "$SSID" = "LAN_ONLY" ] || [ -z "$SSID" ]; then
            echo "LAN-only mode (Ethernet)"
            if [ -f "$IWD_INIT" ]; then
                mv "$IWD_INIT" "$IWD_DISABLED"
                echo "WiFi disabled"
            fi
        else
            echo "WiFi mode: $SSID"
            if [ -f "$IWD_DISABLED" ]; then
                mv "$IWD_DISABLED" "$IWD_INIT"
            fi
            
            if [ -z "$PASSPHRASE" ]; then
                echo "Error: PASSPHRASE required for WiFi"
                rm -f "$CONFIG_FILE" "$LOCK_FILE"
                sync && sleep 2 && reboot
                exit 1
            fi
            
            $GEN_CONF_SCRIPT "$SSID" "$PASSPHRASE"
        fi
        
        # -----------------------------------------------------------------
        # Set hostname from NAME
        # -----------------------------------------------------------------
        hostname_clean=$(echo "$NAME" | tr -d '"' | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-' | sed 's/^-*//;s/-*$//')
        
        if [ -z "$hostname_clean" ]; then
            hostname_clean="device"
        fi
        
        hostname="airplay-$hostname_clean"
        echo "$hostname" > /etc/hostname
        hostname "$hostname"
        
        cat > /etc/hosts <<EOF
127.0.0.1 localhost
127.0.1.1 $hostname
EOF
        echo "Hostname: $hostname"
        
        # -----------------------------------------------------------------
        # Generate UxPlay config
        # -----------------------------------------------------------------
        mkdir -p /etc/uxplay
        
        # Determine PIN mode
        if [ -n "$PIN" ] && [ "$PIN" != "none" ] && [ "$PIN" != "0" ]; then
            PIN_MODE="${PIN_MODE:-fixed}"
        else
            PIN_MODE="none"
            PIN="0000"
        fi
        
        cat > "$UXPLAY_CONFIG" <<EOF
{
  "room_name": "$NAME",
  "hostname": "$hostname",
  "pin_mode": "$PIN_MODE",
  "pin": "$PIN",
  "password": "$PASSWORD",
  "password_mode": "$PASSWORD_MODE",
  "resolution": "$RESOLUTION",
  "fps": $FPS,
  "vsync": $VSYNC,
  "volume": $VOLUME,
  "videosink": "$VIDEOSINK",
  "audiosink": "$AUDIOSINK",
  "color_space": "$COLOR_SPACE",
  "extra_opts": "$UXPLAY_EXTRA",
  "enabled": true,
  "config_version": "provisioned",
  "splash": {
    "room_coords": "$SPLASH_ROOM_COORDS",
    "pin_coords": "$SPLASH_PIN_COORDS",
    "font_size": $SPLASH_FONT_SIZE,
    "font_color": "$SPLASH_FONT_COLOR"
  }
}
EOF
        echo "UxPlay config: $UXPLAY_CONFIG"
        
        # -----------------------------------------------------------------
        # Generate MQTT config
        # -----------------------------------------------------------------
        cat > "$MQTT_CONFIG" <<EOF
MQTT_BROKER=$MQTT_BROKER
MQTT_PORT=$MQTT_PORT
EOF
        [ -n "$MQTT_USER" ] && echo "MQTT_USER=$MQTT_USER" >> "$MQTT_CONFIG"
        [ -n "$MQTT_PASS" ] && echo "MQTT_PASS=$MQTT_PASS" >> "$MQTT_CONFIG"
        echo "MQTT config: $MQTT_CONFIG"
        
        # -----------------------------------------------------------------
        # Generate OTA update config
        # -----------------------------------------------------------------
        cat > "$UPDATE_CONFIG" <<EOF
UPDATE_MODE=$UPDATE_MODE
EOF
        if [ "$UPDATE_MODE" = "github" ]; then
            echo "REPO=$UPDATE_REPO" >> "$UPDATE_CONFIG"
        elif [ "$UPDATE_MODE" = "mirror" ]; then
            echo "MIRROR_URL=$UPDATE_MIRROR_URL" >> "$UPDATE_CONFIG"
        fi
        echo "Update config: $UPDATE_CONFIG"
        
        # -----------------------------------------------------------------
        # Done - create lockfile and reboot
        # -----------------------------------------------------------------
        touch "$LOCK_FILE"
        echo ""
        echo "========================================"
        echo "Configuration complete!"
        echo "  Device: $NAME"
        echo "  Hostname: $hostname"
        echo "  Network: $([ "$LANONLY" = "yes" ] && echo "Ethernet" || echo "WiFi ($SSID)")"
        echo "  PIN: $([ "$PIN_MODE" = "none" ] && echo "disabled" || echo "$PIN")"
        echo "  MQTT: $MQTT_BROKER:$MQTT_PORT"
        echo "========================================"
        echo "Rebooting..."
        
        sync && sync && sleep 2
        echo 1 > /proc/sys/kernel/sysrq 2>/dev/null || true
        echo b > /proc/sysrq-trigger
        exit 0
    fi
    
    sleep "$POLL_INTERVAL"
done
