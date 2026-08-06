# Web-888 Configuration System

## Overview

The Web-888 uses a JSON-based configuration system with multiple configuration files serving different purposes. This document describes the complete configuration architecture, file formats, and available options.

## Configuration Files

### 1. websdr.json - Main SDR Configuration

**Location:** `/etc/websdr.json` (overlay on read-only rootfs)

**Purpose:** Contains receiver identification, location, and operational settings.

```json
{
    "inactivity_timeout_mins": 0,
    "status_msg": "Find out more information: <a href='http://www.rx-888.com' target='_blank'>www.rx-888.com</a>",
    "index_html_params": {
        "PAGE_TITLE": "WEB-888",
        "RX_PHOTO_FILE": "kiwi/pcb.jpg",
        "RX_PHOTO_HEIGHT": "350",
        "RX_PHOTO_TITLE": "WEB-888: Single Board Web SDR",
        "RX_PHOTO_DESC": "First production PCB",
        "RX_TITLE": "WEB-888: Single Board Web SDR",
        "RX_LOC": "Tauranga, New Zealand",
        "RX_QRA": "RF82ci",
        "RX_ASL": "30m",
        "RX_GMAP": "Tauranga/@-37.7039674,176.1586309,12z"
    },
    "init": {
        "cw_offset": 500
    },
    "rx_name": "0-30 MHz SDR",
    "rx_device": "WEB-888",
    "rx_location": "Tauranga, New Zealand",
    "rx_grid": "ON44",
    "rx_asl": 30,
    "rx_antenna": "Mini-Whip",
    "rx_gps": "(-37.631120, 176.172210)",
    "server_url": "web888.example.com",
    "admin_email": "your_email@example.com"
}
```

**Configuration Options:**

| Key | Type | Description |
|-----|------|-------------|
| `inactivity_timeout_mins` | integer | Auto-disconnect idle users (0 = disabled) |
| `status_msg` | string | HTML message displayed on web interface |
| `index_html_params` | object | Web UI customization parameters |
| `init.cw_offset` | integer | CW offset in Hz (default: 500Hz) |
| `rx_name` | string | Receiver name displayed in UI |
| `rx_device` | string | Device model identifier |
| `rx_location` | string | Physical location string |
| `rx_grid` | string | Maidenhead grid locator |
| `rx_asl` | integer | Antenna height above sea level (meters) |
| `rx_antenna` | string | Antenna description |
| `rx_gps` | string | GPS coordinates (lat, lon) |
| `server_url` | string | Public server URL |
| `admin_email` | string | Administrator contact email |

#### index_html_params Options

| Key | Description |
|-----|-------------|
| `PAGE_TITLE` | Browser tab title |
| `RX_PHOTO_FILE` | Path to receiver photo |
| `RX_PHOTO_HEIGHT` | Photo display height (px) |
| `RX_PHOTO_TITLE` | Photo caption title |
| `RX_PHOTO_DESC` | Photo description |
| `RX_TITLE` | Main page title |
| `RX_LOC` | Location string |
| `RX_QRA` | Grid square locator |
| `RX_ASL` | Height above sea level |
| `RX_GMAP` | Google Maps link |

### 2. admin.json - Administrative Settings

**Location:** `/etc/admin.json`

**Purpose:** Contains administrative access control and server settings.

```json
{
    "cfg": "pwd",
    "user_password": "",
    "user_auto_login": true,
    "admin_password": "",
    "admin_auto_login": true,
    "port": 8073,
    "enable_gps": true,
    "update_check": true,
    "update_install": true,
    "sdr_hu_register": false,
    "api_key": "",
    "ip_address": {
        "use_static": false,
        "ip": "",
        "netmask": "",
        "gateway": "",
        "dns1": "",
        "dns2": ""
    }
}
```

**Configuration Options:**

| Key | Type | Description |
|-----|------|-------------|
| `cfg` | string | Configuration protection mode ("pwd" = password required) |
| `user_password` | string | User access password (empty = no password) |
| `user_auto_login` | boolean | Allow auto-login from local network |
| `admin_password` | string | Administrator password (empty = no password) |
| `admin_auto_login` | boolean | Allow admin auto-login from local network |
| `port` | integer | Web server port (default: 8073) |
| `enable_gps` | boolean | Enable GPS/GPSDO functionality |
| `update_check` | boolean | Check for firmware updates |
| `update_install` | boolean | Auto-install firmware updates |
| `sdr_hu_register` | boolean | Register on sdr.hu directory |
| `api_key` | string | API key for external services |
| `ip_address.use_static` | boolean | Use static IP instead of DHCP |
| `ip_address.ip` | string | Static IP address |
| `ip_address.netmask` | string | Network mask |
| `ip_address.gateway` | string | Default gateway |
| `ip_address.dns1` | string | Primary DNS server |
| `ip_address.dns2` | string | Secondary DNS server |

### 3. config.js - Band Definitions

**Location:** `/etc/config/config.js`

**Purpose:** Defines frequency bands, services, and default receiver settings.

```javascript
// Service types for band coloring
var svc = {
    B: { name:'Broadcast', color:'red' },
    U: { name:'Utility', color:'green' },
    A: { name:'Amateur', color:'blue' },
    L: { name:'Beacons', color:'blue' },
    I: { name:'Industrial/Scientific', color:'orange' },
    M: { name:'Markers', color:'purple' },
    X: { name:'', color:'red' },
};

// Band definition format
bands.push({
    s: svc.B,           // Service type (from svc object)
    min: 530,           // Lower frequency bound (kHz)
    max: 1700,          // Upper frequency bound (kHz)
    sel: "1000am",      // Default frequency and mode
    chan: 10,           // Channel spacing (kHz)
    region: ">2",       // ITU region (1, 2, 3, *, >, m)
    name: "MW"          // Display name
});
```

**Band Definition Parameters:**

| Key | Type | Description |
|-----|------|-------------|
| `s` | object | Service type (reference to svc object) |
| `min` | integer | Lower frequency bound in kHz |
| `max` | integer | Upper frequency bound in kHz |
| `sel` | string | Default frequency and mode (e.g., "7020cw") |
| `chan` | integer | Channel spacing in kHz |
| `region` | string | ITU region or special marker |
| `name` | string | Display name in band selector |

**Region Codes:**

| Code | Description |
|------|-------------|
| `1` | Europe, Africa |
| `2` | North & South America |
| `3` | Asia / Pacific |
| `*` | All regions |
| `>` | Default region when multiple present |
| `m` | Menu only (not shown on band scale) |
| `E` | Europe only |
| `U` | USA only |

### 4. dx.json / dx_config.json - DX Station Database

**Location:** `/etc/dx.json`, `/etc/dx_config.json`

**Purpose:** Station database for marking known transmitters on the waterfall.

**Format:**
```json
{
    "dx": [
        {
            "f": 7020000,       // Frequency in Hz
            "lo": 300,          // Lower filter bound (Hz offset)
            "hi": 2700,         // Upper filter bound (Hz offset)
            "o": 0,             // Marker offset (Hz)
            "s": 2700,          // Signal bandwidth (Hz)
            "fl": "lsb",        // Mode/flags
            "b": 0,             // Begin time (0-2400)
            "e": 2400,          // End time (0-2400)
            "i": "Station ID",  // Identification
            "n": "Notes",       // Additional notes
            "p": ""             // Parameters
        }
    ]
}
```

## Configuration API

### Server-Side (C++)

```cpp
// Include configuration header
#include "config.h"

// Initialize configuration
cfg_init();

// Read integer value
int timeout = cfg_int("inactivity_timeout_mins", NULL, CFG_REQUIRED);

// Read boolean value
bool gps_enabled = cfg_bool("enable_gps", NULL, CFG_REQUIRED);

// Read string value
const char* location = cfg_string("rx_location", NULL, CFG_REQUIRED);

// Save configuration
cfg_save_json(cfg, "/etc/websdr.json");
```

### Client-Side (JavaScript)

```javascript
// Request current configuration
ext_send('SET GET_CONFIG');

// Handle configuration response
function handleMessage(msg) {
    if (msg.startsWith('MSG config=')) {
        var config = JSON.parse(msg.substring(11));
        console.log('Receiver:', config.rx_name);
        console.log('Location:', config.rx_location);
    }
}

// Update configuration
var newConfig = {
    rx_name: 'My Web-888',
    rx_location: 'New York, USA',
    rx_antenna: 'Dipole'
};
ext_send('SET save_cfg=' + encodeURIComponent(JSON.stringify(newConfig)));
```

## Configuration Persistence

### Overlay Filesystem

The Web-888 uses a read-only rootfs with an overlay for configuration persistence:

```
Root FS (read-only, squashfs)
    └── /etc/websdr.json (template)

Overlay (read-write, tmpfs/persistent)
    └── /etc/websdr.json (actual config)
```

**Boot Process:**
1. Root filesystem mounted read-only from SD card
2. Overlay mounted on top using overlayfs
3. Configuration changes written to overlay
4. On reboot, overlay re-applied

### Backup and Restore

**Create Backup:**
```bash
# Create configuration backup
tar czf /tmp/web888-config-backup.tar.gz /etc/websdr.json /etc/admin.json /etc/dx.json

# Copy to safe location
scp /tmp/web888-config-backup.tar.gz user@backup-server:
```

**Restore from Backup:**
```bash
# Extract backup
tar xzf web888-config-backup.tar.gz -C /

# Restart server
/etc/init.d/websdr restart
```

## Security Considerations

### Password Storage

- Passwords are stored as SHA-256 hashes
- No plaintext password storage
- Empty password = authentication disabled
- Auto-login only works from local network (RFC 1918 addresses)

### Access Control

**IP Restrictions:**
- Create `/etc/opt.admin_ip` to restrict admin access to specific IP
- Duplicate IP prevention via `no_dup_ip` setting
- Time limits per IP via `ip_limit_mins`

**Connection Limits:**
- Maximum concurrent users: 4 (user password set) or 13 (no password)
- Admin connection limited to 1 concurrent
- Inactivity timeout configurable

## Configuration Validation

### JSON Schema (Partial)

```json
{
    "type": "object",
    "required": ["rx_name", "rx_device"],
    "properties": {
        "inactivity_timeout_mins": {
            "type": "integer",
            "minimum": 0,
            "maximum": 1440
        },
        "rx_name": {
            "type": "string",
            "maxLength": 100
        },
        "rx_asl": {
            "type": "integer",
            "minimum": -500,
            "maximum": 9000
        },
        "port": {
            "type": "integer",
            "minimum": 1,
            "maximum": 65535
        },
        "enable_gps": {
            "type": "boolean"
        }
    }
}
```

### Validation Rules

1. **Frequency Ranges:** Must be within hardware capabilities (0-62 MHz HF, 118-150 MHz VHF)
2. **GPS Coordinates:** Valid latitude (-90 to 90), longitude (-180 to 180)
3. **Port Numbers:** Valid TCP port (1-65535, not privileged <1024 recommended)
4. **Grid Square:** Valid Maidenhead locator format
5. **Email:** Valid email format for admin contact

## Default Configuration Values

| Parameter | Default Value |
|-----------|---------------|
| Port | 8073 |
| Inactivity Timeout | 0 (disabled) |
| CW Offset | 500 Hz |
| GPS Enabled | true |
| Auto-login | true (local network) |
| Update Check | true |
| Bandwidth Options | 12, 24, 36 kHz |

## Configuration Migration

### From config.js to JSON

Legacy configurations in `config.js` format are automatically migrated:

```javascript
// Old format (config.js)
var bands = [
    { s:svc.A, min:3500, max:3800, region:"*", name:"80m" }
];

// New format (dx.json)
{
    "dx": [
        {"f": 3500000, "lo": 300, "hi": 2700, "s": 2700, "fl": "lsb", "i": "80m"}
    ]
}
```

Migration happens automatically on first admin page access.

## Troubleshooting

### Configuration Reset

If configuration becomes corrupted:

```bash
# Remove overlay (resets to defaults)
rm -rf /overlay/etc/websdr.json
rm -rf /overlay/etc/admin.json

# Reboot to apply
reboot
```

### Common Issues

| Issue | Cause | Solution |
|-------|-------|----------|
| Changes not saved | Overlay full | Check SD card space |
| Invalid JSON | Syntax error | Validate JSON syntax |
| Settings reset | Corruption | Restore from backup |
| Auth fails | Wrong password | Reset via admin page or config file |

## References

1. Source: `rx/rx_cmd.cpp` - Configuration command handling
2. Source: `rx/cfg.cpp` - Configuration file I/O
3. Web: `web/kiwi/admin.js` - Admin interface
4. Web: `web/kiwi/kiwi.js` - Client configuration handling

---

*Document Version: 1.0*
*Last Updated: March 2026*
