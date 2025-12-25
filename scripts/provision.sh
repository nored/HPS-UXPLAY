#!/bin/bash
# =============================================================================
# UxPlay Device Provisioning Script
# =============================================================================
# Run this on your admin machine to push initial config to a device
#
# Usage:
#   ./provision.sh <device_id> <room_name> [pin]
#
# Example:
#   ./provision.sh a1b2c3d4e5f6 "Ballroom A" 1234
#   ./provision.sh a1b2c3d4e5f6 "Boardroom 1"

set -e

# Configuration
BROKER="${MQTT_BROKER:-localhost}"
PORT="${MQTT_PORT:-1883}"

# Check arguments
if [ $# -lt 2 ]; then
    echo "Usage: $0 <device_id> <room_name> [pin]"
    echo ""
    echo "Arguments:"
    echo "  device_id   - Device MAC address without colons (e.g., a1b2c3d4e5f6)"
    echo "  room_name   - Display name for the room (e.g., 'Conference Room A')"
    echo "  pin         - Optional 4-digit PIN code (enables fixed PIN mode)"
    echo ""
    echo "Environment:"
    echo "  MQTT_BROKER - Broker hostname (default: localhost)"
    echo "  MQTT_PORT   - Broker port (default: 1883)"
    echo ""
    echo "Examples:"
    echo "  $0 a1b2c3d4e5f6 'Ballroom A' 1234"
    echo "  $0 dcf637abc123 'Meeting Room 101'"
    exit 1
fi

DEVICE_ID="$1"
ROOM_NAME="$2"
PIN="${3:-}"

# Determine PIN mode
if [ -n "$PIN" ]; then
    PIN_MODE="fixed"
else
    PIN_MODE="none"
    PIN="0000"
fi

# Generate hostname from room name (lowercase, no spaces)
HOSTNAME=$(echo "$ROOM_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | sed 's/[^a-z0-9-]//g')
HOSTNAME="uxplay-${HOSTNAME}"

# Build config JSON
CONFIG=$(cat <<EOF
{
  "room_name": "$ROOM_NAME",
  "hostname": "$HOSTNAME",
  "pin_mode": "$PIN_MODE",
  "pin": "$PIN",
  "password": "",
  "resolution": "1920x1080",
  "fps": 30,
  "fullscreen": true,
  "videosink": "autovideosink",
  "audiosink": "autoaudiosink",
  "vsync": "yes",
  "port_base": 7000,
  "enabled": true,
  "extra_args": [],
  "config_version": "$(date -Iseconds)"
}
EOF
)

TOPIC="uxplay/devices/${DEVICE_ID}/config"

echo "Provisioning device: $DEVICE_ID"
echo "  Room Name: $ROOM_NAME"
echo "  Hostname:  $HOSTNAME"
echo "  PIN Mode:  $PIN_MODE"
[ "$PIN_MODE" = "fixed" ] && echo "  PIN:       $PIN"
echo ""
echo "Publishing to: $TOPIC"
echo "Broker: $BROKER:$PORT"
echo ""

# Check if mosquitto_pub is available
if ! command -v mosquitto_pub &> /dev/null; then
    echo "Error: mosquitto_pub not found. Install mosquitto-clients:"
    echo "  sudo apt install mosquitto-clients"
    exit 1
fi

# Publish config (retained)
echo "$CONFIG" | mosquitto_pub -h "$BROKER" -p "$PORT" -t "$TOPIC" -r -s

echo "✓ Configuration published successfully!"
echo ""
echo "The device will apply the new config automatically."
echo "If the device is offline, it will receive the config when it connects."
