# Bluetooth Device Scanner

Enumerates paired/connected Bluetooth devices on Windows and resolves **Brand** and **Device Category** for each one.

## Requirements

- Windows 10/11
- Python 3.10+
- PowerShell 5.1+ (built-in on Windows)

```
pip install requests
```

## Files

```
UX_Lab/
├── get_bluetooth_devices.py      # Main scanner (Python)
├── Get-BluetoothDevices.ps1      # Equivalent PowerShell script
├── data/
│   ├── company_identifiers.yaml  # Bluetooth SIG vendor ID table
│   └── usb.ids                   # USB-IF vendor ID table
└── README.md
```

`data/` files are downloaded automatically on first run if missing.

## Usage

### Run standalone

```
python get_bluetooth_devices.py
```

Output:
```
Device Name                      Category           Type                   Brand
-----------                      --------           ----                   -----
MX Anywhere 3                    Mouse              LE                     Logitech
MX Keys                          Keyboard           LE                     Logitech
Xbox Wireless Headset            Headset            Classic                Microsoft
```

### Import as module

```python
from get_bluetooth_devices import scan_bluetooth_devices

devices = scan_bluetooth_devices(debug=False)
for d in devices:
    print(d.name, d.device_category, d.brand)
```

### `BtDevice` dataclass fields

| Field | Type | Description |
|---|---|---|
| `name` | `str` | Device friendly name |
| `protocols` | `list[str]` | `["LE"]`, `["Classic"]`, or `["Classic", "LE"]` |
| `macs` | `list[str]` | MAC address(es), 12 hex chars, uppercase |
| `brand` | `str` | Normalized brand name (e.g. `"Logitech"`) |
| `brand_method` | `str` | How brand was resolved (for debug) |
| `audio_mode` | `str` | `"Classic"` / `"LE"` / `""` (non-audio) |
| `device_category` | `str` | See categories below |
| `instance_id` | `str` | Windows PnP InstanceId |

### Device categories

`Mouse` · `Keyboard` · `Headset` · `Headphones` · `Earbuds` · `Speaker` · `Controller` · `Wearable` · `Phone` · `Computer` · `Stylus` · `HID` · `Audio` · `Unknown`

---

## How it works

### Brand detection (3-method cascade)

1. **VID lookup** — Extracts `VID&xxxxxx` from the PnP InstanceId.
   - Prefix `0001`/`01` → BT SIG namespace (`company_identifiers.yaml`)
   - Prefix `0002`/`02` → USB-IF namespace (`usb.ids`)
   - When prefix is BT SIG, both tables are tried; the one that matches a known brand wins. This handles cases like Xbox Wireless Headset where Microsoft's USB-IF VID (`045E`) is embedded in the BT SIG namespace field.
2. **FriendlyName keyword** — Regex match against the device name (e.g. `"MX Keys"` → Logitech).
3. **Unknown** — Fallback if neither method resolves.

### Category detection (4-method priority chain)

| Priority | Method | Source | Notes |
|---|---|---|---|
| A0 | `DEVPKEY_DeviceContainer_Category` | Windows HID stack | Most reliable; set after HID driver loads |
| A | Class of Device (CoD) registry | `HKLM\...\BTHPORT\...\ClassOfDevice` | Classic BT only |
| B | UUID profiles in PnP children | HFP `0000111E`, A2DP `0000110B`, HID `00001124`/`00001812` | |
| C | FriendlyName keyword | Regex match | Last resort |

### VID namespace note

BT SIG and USB-IF maintain **independent** vendor ID registries. The same 16-bit hex value can mean different vendors in each table. Some devices (notably Xbox peripherals) embed their USB-IF VID in the BT SIG field — the code handles this by checking both tables and preferring whichever resolves to a recognized brand.

---

## Configuration

**Proxy** — Edit the `PROXY` constant at the top of the script if downloads fail:

```python
PROXY = "http://your-proxy:port"
```

Set to `""` to disable proxy.

**Refresh data files** — Delete `data/company_identifiers.yaml` or `data/usb.ids` to force re-download on next run.
