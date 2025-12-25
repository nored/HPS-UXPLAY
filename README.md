# HPS-UXPLAY

AirPlay receiver fleet management system for Raspberry Pi Zero 2W. Designed for hotel conference rooms with centralized MQTT management, daily rotating passwords, branded splash screens, and secure OTA updates.

## Features

- **Single-file provisioning** — One `settings.cfg` per device
- **Daily rotating passwords** — Guests must be in the room to connect
- **Branded splash screen** — Your template with room name and password overlay
- **MQTT fleet management** — Central control of all devices
- **A/B OTA updates** — Secure, signed firmware updates
- **WiFi or Ethernet** — USB Ethernet adapter support (RTL8152)

## Quick Start

### Build

```bash
# Clone repository
git clone https://github.com/yourorg/HPS-UXPLAY.git
cd HPS-UXPLAY

# Build for Pi Zero 2W
docker compose run --rm rpi02w

# Output
ls images/sdcard-raspberrypizero2w.img.xz
```

### Flash & Configure

```bash
# Flash to SD card
xzcat images/sdcard-raspberrypizero2w.img.xz | sudo dd of=/dev/sdX bs=4M status=progress

# Mount boot partition and create config
sudo mount /dev/sdX1 /mnt
sudo cp /mnt/settings.cfg.example /mnt/settings.cfg
sudo nano /mnt/settings.cfg
sudo umount /mnt
```

### Boot

Insert SD card, connect power. Device auto-configures and reboots.

## Configuration

Create `settings.cfg` on the boot partition. Only `NAME` is required:

### Minimal (Ethernet + daily password)

```bash
NAME="Ballroom A"
PASSWORD_MODE="daily"
```

### WiFi Mode

```bash
NAME="Ballroom A"
PASSWORD_MODE="daily"
SSID="HPS-Protected"
PASSPHRASE="YourWiFiPassword"
```

### Full Configuration

```bash
# =============================================================================
# Device Identity (REQUIRED)
# =============================================================================
NAME="Ballroom A"

# =============================================================================
# Network
# =============================================================================
LANONLY="no"                    # "yes" for Ethernet only (disables WiFi)
SSID="HPS-Protected"            # WiFi network name
PASSPHRASE="YourWiFiPassword"   # WiFi password

# =============================================================================
# Authentication
# =============================================================================
# Daily rotating password (recommended for hotels)
PASSWORD_MODE="daily"           # "daily", "fixed", or "none"
# PASSWORD="secret123"          # Only used if PASSWORD_MODE="fixed"

# Alternative: PIN mode
# PIN_MODE="fixed"              # "fixed", "random", or "none"
# PIN="1234"                    # 4-digit PIN

# =============================================================================
# Display
# =============================================================================
RESOLUTION="1024x768"
FPS="30"
VSYNC="0"
VOLUME="0.3"
COLOR_SPACE="bt709"
VIDEOSINK="kmssink force_modesetting=true"
AUDIOSINK="autoaudiosink"
# UXPLAY_EXTRA="-p"             # Extra flags (e.g., -p for portrait)

# =============================================================================
# Fleet Management
# =============================================================================
MQTT_BROKER="mqtt.local"
MQTT_PORT="1883"
# MQTT_USER=""
# MQTT_PASS=""

# =============================================================================
# OTA Updates
# =============================================================================
UPDATE_MODE="github"            # "github" or "mirror"
UPDATE_REPO="yourorg/uxplay-releases"
# UPDATE_MIRROR_URL="https://updates.example.com/uxplay"

# =============================================================================
# Splash Screen
# =============================================================================
SPLASH_ROOM_COORDS="+100+650"   # ImageMagick format: +X+Y
SPLASH_PIN_COORDS="+100+720"
SPLASH_FONT_SIZE="48"
SPLASH_FONT_COLOR="black"
```

## Authentication Modes

| Mode | Config | Behavior | Use Case |
|------|--------|----------|----------|
| Daily Password | `PASSWORD_MODE="daily"` | Random 6-digit, changes daily | Hotels (recommended) |
| Fixed Password | `PASSWORD_MODE="fixed"` | Static password | Private offices |
| Fixed PIN | `PIN_MODE="fixed"` | 4-digit PIN, client remembers | Trusted environments |
| Random PIN | `PIN_MODE="random"` | New PIN each connection | High security |
| None | `PASSWORD_MODE="none"` | Open access | Internal use |

### Why Daily Passwords?

- Guest in Room A today enters password `847293`
- Tomorrow guest is in Room B
- Old password fails — must see new password on Room B's screen
- Ensures physical presence in room

## Splash Screen

Place your branded template at `uxplay/board/raspberrypi/boot-files/splash-template.png` (1920x1080 recommended).

The system overlays:
- Room name at `SPLASH_ROOM_COORDS`
- Password/PIN at `SPLASH_PIN_COORDS`

### Finding Coordinates

1. Open template in image editor (GIMP, Photoshop)
2. Find pixel position for text
3. Use `+X+Y` format (from top-left)

Example for text in bottom-left:
```bash
SPLASH_ROOM_COORDS="+100+650"
SPLASH_PIN_COORDS="+100+720"
```

## Build Commands

```bash
# Build Pi Zero 2W image
docker compose run --rm rpi02w

# Build other targets
docker compose run --rm rpi4
docker compose run --rm rpi3
docker compose run --rm rpi0w

# Clean all builds
docker compose run --rm clean

# Clean specific target
docker compose run --rm clean-rpi02w

# Interactive shell
docker compose run --rm bash
```

## Output Files

```
images/
└── sdcard-raspberrypizero2w.img.xz    # Compressed SD image

update/
└── raspberrypizero2w/
    ├── signed_encrypted_update.pkg     # OTA package
    └── signed_update.sig               # Signature
```

## MQTT Fleet Management

### Broker Setup

```bash
# Quick start with Docker
docker run -d --name mosquitto \
  -p 1883:1883 -p 9001:9001 \
  eclipse-mosquitto:2
```

### Topics

| Topic | Direction | Purpose |
|-------|-----------|---------|
| `uxplay/discover` | Device → | Announce on boot |
| `uxplay/devices/{id}/status` | Device → | Health status |
| `uxplay/devices/{id}/config` | → Device | Configuration |
| `uxplay/devices/{id}/command` | → Device | Commands |

### Commands

```bash
# Discover devices
mosquitto_sub -h mqtt.local -t 'uxplay/discover' -v

# Reboot device
mosquitto_pub -h mqtt.local -t 'uxplay/devices/DEVICE_ID/command' \
  -m '{"command":"reboot"}'

# Restart UxPlay
mosquitto_pub -h mqtt.local -t 'uxplay/devices/DEVICE_ID/command' \
  -m '{"command":"restart_uxplay"}'

# Check for updates
mosquitto_pub -h mqtt.local -t 'uxplay/devices/DEVICE_ID/command' \
  -m '{"command":"check_update"}'

# Update config
mosquitto_pub -h mqtt.local -t 'uxplay/devices/DEVICE_ID/config' -r \
  -m '{"room_name":"New Name","password_mode":"daily"}'
```

### Admin Console

Open `uxplay/admin-console/index.html` in a browser for a web-based dashboard.

## OTA Updates

### Setup Signing Keys

```bash
# Generate keypair (once)
openssl genrsa -out uxplay/board/raspberrypi/private_key.pem 4096
openssl rsa -in uxplay/board/raspberrypi/private_key.pem -pubout \
  -out uxplay/board/rootfs/etc/apserver/public_key.pem
```

### Build Creates Update Package

With `private_key.pem` in place, build automatically creates:
- `update/<board>/signed_encrypted_update.pkg`
- `update/<board>/signed_update.sig`

### Deploy Update

**GitHub Releases:**
1. Create release with new tag (e.g., `v1.2.0`)
2. Upload both files
3. Devices auto-check and update

**Mirror Server:**
```bash
# Server structure
/latest_version.txt          # Contains "v1.2.0"
/v1.2.0/signed_encrypted_update.pkg
/v1.2.0/signed_update.sig
```

Configure in `settings.cfg`:
```bash
UPDATE_MODE="mirror"
UPDATE_MIRROR_URL="https://updates.yourhotel.com/uxplay"
```

## Directory Structure

```
HPS-UXPLAY/
├── docker-compose.yml
├── Dockerfile
├── buildroot/                  # Buildroot source (submodule)
├── uxplay/                     # BR2_EXTERNAL tree
│   ├── board/
│   │   ├── raspberrypi/
│   │   │   ├── boot-files/
│   │   │   │   ├── settings.cfg.example
│   │   │   │   └── splash-template.png
│   │   │   ├── post-build.sh
│   │   │   ├── post-image.sh
│   │   │   ├── genimage.cfg.in
│   │   │   ├── cmdline.txt
│   │   │   └── linux-usb-ethernet.config
│   │   └── rootfs/             # Rootfs overlay
│   │       ├── etc/
│   │       │   ├── iwd/main.conf
│   │       │   └── apserver/public_key.pem
│   │       └── usr/bin/
│   │           ├── uxplay-agent
│   │           ├── uxplay-wrapper
│   │           ├── preparesettings.sh
│   │           ├── gen_conf
│   │           ├── update.sh
│   │           └── fbi
│   ├── configs/
│   │   └── raspberrypizero2w_defconfig
│   ├── package/uxplay/
│   │   ├── Config.in
│   │   └── uxplay.mk
│   ├── Config.in
│   ├── external.desc
│   └── external.mk
├── images/                     # Build output
└── update/                     # OTA packages
```

## Hardware Requirements

- Raspberry Pi Zero 2W
- MicroSD card (8GB+)
- HDMI cable
- Power supply (5V/2.5A)
- Optional: USB Ethernet adapter (RTL8152/8153)

## Network Requirements

- DHCP server
- mDNS/Bonjour (for AirPlay discovery)
- MQTT broker (for fleet management)
- Ports: 7000-7100 (AirPlay), 1883 (MQTT)

## Troubleshooting

### Device not booting
- Check `settings.cfg` syntax (no tabs, proper quotes)
- Verify SD card flashed correctly

### AirPlay not discovered
- Check WiFi/Ethernet connection: `ip addr`
- Verify Avahi running: `ps aux | grep avahi`
- Check firewall allows ports 7000-7100

### Splash not showing
- Verify `splash-template.png` on boot partition
- Check fbi binary exists: `which fbi`
- View logs: `cat /var/log/messages | grep uxplay`

### MQTT not connecting
- Verify broker address in config
- Test connectivity: `mosquitto_pub -h mqtt.local -t test -m hello`

### SSH Access

Default credentials:
- User: `root`
- Password: `toor`

```bash
ssh root@airplay-ballroom-a.local
```

## License

MIT

## Credits

- [UxPlay](https://github.com/FDH2/UxPlay) — Open-source AirPlay server
- [Buildroot](https://buildroot.org/) — Embedded Linux build system