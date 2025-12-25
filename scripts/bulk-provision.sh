#!/bin/bash
# =============================================================================
# UxPlay Bulk Device Provisioning
# =============================================================================
# Configure multiple devices from a CSV file
#
# Usage:
#   ./bulk-provision.sh rooms.csv
#
# CSV Format (no header):
#   device_id,room_name,pin
#
# Example rooms.csv:
#   a1b2c3d4e5f6,Ballroom A,1234
#   b2c3d4e5f6a1,Ballroom B,2345
#   c3d4e5f6a1b2,Boardroom 1,3456
#   d4e5f6a1b2c3,Meeting Room 101,

set -e

BROKER="${MQTT_BROKER:-localhost}"
PORT="${MQTT_PORT:-1883}"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <rooms.csv>"
    echo ""
    echo "CSV Format (no header):"
    echo "  device_id,room_name,pin"
    echo ""
    echo "The PIN field is optional. Leave empty for no PIN."
    exit 1
fi

CSV_FILE="$1"

if [ ! -f "$CSV_FILE" ]; then
    echo "Error: File not found: $CSV_FILE"
    exit 1
fi

# Check if mosquitto_pub is available
if ! command -v mosquitto_pub &> /dev/null; then
    echo "Error: mosquitto_pub not found. Install mosquitto-clients:"
    echo "  sudo apt install mosquitto-clients"
    exit 1
fi

echo "=== UxPlay Bulk Provisioning ==="
echo "Broker: $BROKER:$PORT"
echo "Config file: $CSV_FILE"
echo ""

COUNT=0
ERRORS=0

while IFS=',' read -r device_id room_name pin || [ -n "$device_id" ]; do
    # Skip empty lines and comments
    [[ -z "$device_id" || "$device_id" =~ ^# ]] && continue
    
    # Trim whitespace
    device_id=$(echo "$device_id" | xargs)
    room_name=$(echo "$room_name" | xargs)
    pin=$(echo "$pin" | xargs)
    
    # Determine PIN mode
    if [ -n "$pin" ]; then
        pin_mode="fixed"
    else
        pin_mode="none"
        pin="0000"
    fi
    
    # Generate hostname
    hostname=$(echo "$room_name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | sed 's/[^a-z0-9-]//g')
    hostname="uxplay-${hostname}"
    
    # Build config
    config=$(cat <<EOF
{
  "room_name": "$room_name",
  "hostname": "$hostname",
  "pin_mode": "$pin_mode",
  "pin": "$pin",
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
    
    topic="uxplay/devices/${device_id}/config"
    
    echo -n "Provisioning $room_name ($device_id)... "
    
    if echo "$config" | mosquitto_pub -h "$BROKER" -p "$PORT" -t "$topic" -r -s 2>/dev/null; then
        echo "✓"
        ((COUNT++))
    else
        echo "✗ FAILED"
        ((ERRORS++))
    fi
    
done < "$CSV_FILE"

echo ""
echo "=== Complete ==="
echo "Provisioned: $COUNT devices"
[ $ERRORS -gt 0 ] && echo "Errors: $ERRORS"
exit $ERRORS
