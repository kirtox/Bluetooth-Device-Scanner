"""
get_bluetooth_devices.py
Enumerates connected Bluetooth devices on Windows and resolves
Brand + DeviceCategory for each one.

Requires:
  pip install requests pyyaml
  Windows only (uses winreg + subprocess/PowerShell for PnP queries)
"""

import csv
import os
import re
import subprocess
import time
import winreg
from dataclasses import dataclass, field
from typing import Optional

import requests

# ---------------------------------------------------------------------------
# Paths (same directory as this script)
# ---------------------------------------------------------------------------
_DIR = os.path.dirname(os.path.abspath(__file__))
VID_YAML_PATH  = os.path.join(_DIR, "data", "company_identifiers.yaml")
USB_IDS_PATH   = os.path.join(_DIR, "data", "usb.ids")

PROXY = "http://proxy-dmz.intel.com:912"

# ---------------------------------------------------------------------------
# 1. Table loaders
# ---------------------------------------------------------------------------

def _download(url: str, dest: str) -> bool:
    print(f"[INFO] Downloading {url} ...")
    try:
        r = requests.get(url, timeout=30, proxies={"http": PROXY, "https": PROXY})
        r.raise_for_status()
        with open(dest, "wb") as f:
            f.write(r.content)
        print(f"[INFO] Download complete: {dest}")
        return True
    except Exception as e:
        print(f"[WARN] Failed to download {url}: {e}")
        return False


def load_vid_table() -> dict:
    if not os.path.exists(VID_YAML_PATH):
        _download(
            "https://bitbucket.org/bluetooth-SIG/public/raw/HEAD/"
            "assigned_numbers/company_identifiers/company_identifiers.yaml",
            VID_YAML_PATH,
        )
    table = {}
    if os.path.exists(VID_YAML_PATH):
        with open(VID_YAML_PATH, encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
        i = 0
        while i < len(lines) - 1:
            m = re.search(r'\bvalue:\s*(0x[0-9a-fA-F]+)', lines[i])
            if m:
                key = "0x" + m.group(1)[2:].upper()   # normalise to "0xABCD"
                m2 = re.search(r"name:\s*['\"]?(.+?)['\"]?\s*$", lines[i + 1])
                if m2:
                    table[key] = m2.group(1).strip()
            i += 1
        print(f"[INFO] VID table loaded: {len(table)} entries")
    return table


def load_usb_vid_table() -> dict:
    if not os.path.exists(USB_IDS_PATH):
        _download("http://www.linux-usb.org/usb.ids", USB_IDS_PATH)
    table = {}
    if os.path.exists(USB_IDS_PATH):
        with open(USB_IDS_PATH, encoding="utf-8", errors="replace") as f:
            for line in f:
                m = re.match(r'^([0-9a-fA-F]{4})  (.+)$', line)
                if m:
                    table[m.group(1).upper()] = m.group(2).strip()
        print(f"[INFO] USB VID table loaded: {len(table)} entries")
    return table


# ---------------------------------------------------------------------------
# 2. Brand normalisation table (order matters — first match wins)
# ---------------------------------------------------------------------------
BRAND_NORMALIZE = [
    (r"apple",          "Apple"),
    (r"samsung",        "Samsung"),
    (r"sony",           "Sony"),
    (r"bose",           "Bose"),
    (r"gn audio",       "Jabra"),
    (r"jabra",          "Jabra"),
    (r"logitech",       "Logitech"),
    (r"plantronics",    "Plantronics/Poly"),
    (r"poly",           "Plantronics/Poly"),
    (r"beats",          "Beats"),
    (r"harman",         "JBL"),
    (r"sennheiser",     "Sennheiser"),
    (r"bang.*olufsen",  "Bang & Olufsen"),
    (r"anker",          "Anker/Soundcore"),
    (r"huawei",         "Huawei"),
    (r"razer",          "Razer"),
    (r"skullcandy",     "Skullcandy"),
    (r"steelseries",    "SteelSeries"),
    (r"corsair",        "Corsair"),
    (r"hyperx",         "HyperX"),
    (r"hewlett",        "HP"),
    (r"hp inc",         "HP"),
    (r"hp, inc",        "HP"),
    (r"jingxun",        "Dell"),
    (r"microsoft",      "Microsoft"),
    (r"google",         "Google"),
    (r"qualcomm",       "Qualcomm"),
]

NAME_BRAND_KEYWORDS = [
    (r"airpods|apple watch|iphone|ipad|macbook",           "Apple"),
    (r"galaxy buds|galaxy watch|samsung",                  "Samsung"),
    (r"\bwh-|\bwf-|\bxm[0-9]|\bsrs-|\bult ",              "Sony"),
    (r"\bbose\b",                                          "Bose"),
    (r"\bjabra\b",                                         "Jabra"),
    (r"logitech|\bmx \b|\bmx keys\b",                      "Logitech"),
    (r"plantronics|\bpoly\b|voyager",                      "Plantronics/Poly"),
    (r"\bbeats\b|powerbeats",                              "Beats"),
    (r"\bjbl\b",                                           "JBL"),
    (r"sennheiser|momentum|accentum",                      "Sennheiser"),
    (r"beoplay|bang.*olufsen|\bb&o\b",                     "Bang & Olufsen"),
    (r"soundcore|\banker\b",                               "Anker/Soundcore"),
    (r"freebuds|freelace|huawei",                          "Huawei"),
    (r"\brazer\b|barracuda",                               "Razer"),
    (r"skullcandy|crusher|hesh",                           "Skullcandy"),
    (r"steelseries|arctis",                                "SteelSeries"),
    (r"\bcorsair\b|virtuoso",                              "Corsair"),
    (r"\bhyperx\b|cloud alpha|cloud ii",                   "HyperX"),
    (r"surface|xbox",                                      "Microsoft"),
    (r"pixel buds|google",                                 "Google"),
    (r"\bhp\b|hewlett",                                    "HP"),
    (r"\bdell\b",                                          "Dell"),
    (r"emberton|stanmore|woburn|acton|kilburn",            "Marshall"),
]


def normalize_brand(raw: str) -> str:
    lower = raw.lower()
    for pattern, brand in BRAND_NORMALIZE:
        if re.search(pattern, lower):
            return brand
    return raw


def _is_known_brand(raw: str) -> bool:
    lower = raw.lower()
    return any(re.search(p, lower) for p, _ in BRAND_NORMALIZE)


# ---------------------------------------------------------------------------
# 3. PnP helpers (via PowerShell)
# ---------------------------------------------------------------------------

def _run_ps(script: str) -> str:
    result = subprocess.run(
        ["powershell", "-NoProfile", "-NonInteractive", "-Command", script],
        capture_output=True, text=True
    )
    return result.stdout.strip()


def get_all_pnp_devices() -> list[dict]:
    """Return list of {InstanceId, FriendlyName, Status} for all PnP devices."""
    ps = (
        "Get-PnpDevice | "
        "Select-Object InstanceId, FriendlyName, Status | "
        "ConvertTo-Csv -NoTypeInformation"
    )
    out = _run_ps(ps)
    devices = []
    for row in csv.DictReader(out.splitlines()):
        devices.append({
            "InstanceId":   row.get("InstanceId", "").strip('"'),
            "FriendlyName": row.get("FriendlyName", "").strip('"'),
            "Status":       row.get("Status", "").strip('"'),
        })
    return devices


def get_pnp_device_property(instance_id: str, key_name: str) -> Optional[list]:
    """Return .Data of a PnP device property, or None if not found."""
    ps = (
        f"$d = Get-PnpDeviceProperty -InstanceId '{instance_id}' "
        f"-KeyName '{key_name}' -ErrorAction SilentlyContinue; "
        f"if ($d) {{ $d.Data -join '|' }}"
    )
    out = _run_ps(ps)
    if out:
        return out.split("|")
    return None


def get_cod_from_registry(mac: str) -> Optional[int]:
    """Read ClassOfDevice DWORD from registry for a Classic BT device."""
    key_path = (
        r"SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Devices"
        rf"\{mac.lower()}"
    )
    try:
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, key_path) as k:
            val, _ = winreg.QueryValueEx(k, "ClassOfDevice")
            return int(val)
    except OSError:
        return None


# ---------------------------------------------------------------------------
# 4. Brand resolution
# ---------------------------------------------------------------------------

def get_brand_by_vid(instance_id: str, vid_table: dict, usb_vid_table: dict) -> tuple[str, str]:
    """Returns (brand_raw, source_label)."""
    m = re.search(r'VID[&]([0-9a-fA-F]+)', instance_id, re.IGNORECASE)
    if not m:
        return "", ""
    full   = m.group(1).upper()
    vid_id = full[-4:]
    prefix = full[:-4]
    is_bt_sig = prefix in ("01", "0001")

    if is_bt_sig:
        bt_result  = vid_table.get(f"0x{vid_id}", "")
        usb_result = usb_vid_table.get(vid_id, "")
        if bt_result and _is_known_brand(bt_result):
            return bt_result, "BT-SIG"
        if usb_result and _is_known_brand(usb_result):
            return usb_result, f"USB-IF(prefix={prefix})"
        if bt_result:
            return bt_result, "BT-SIG"

    usb_result = usb_vid_table.get(vid_id, "")
    if usb_result:
        return usb_result, f"USB-IF(prefix={prefix})"
    return "", ""


# ---------------------------------------------------------------------------
# 5. Device category detection
# ---------------------------------------------------------------------------

# Method A0: DEVPKEY_DeviceContainer_Category patterns
_CAT_MAP = [
    (r'^Input\.Mouse',           "Mouse"),
    (r'^Input\.Keyboard',        "Keyboard"),
    (r'^Input\.Gamepad',         "Controller"),
    (r'^Input\.Joystick',        "Controller"),
    (r'^Audio\.Headset',         "Headset"),
    (r'^Communication\.Headset', "Headset"),
    (r'^Audio\.Headphones',      "Headphones"),
    (r'^Audio\.Earbuds',         "Earbuds"),
    (r'^Audio\.Speaker',         "Speaker"),
    (r'^Wearable',               "Wearable"),
    (r'^Phone',                  "Phone"),
    (r'^Computer',               "Computer"),
]

# Method C: FriendlyName keyword patterns
_NAME_CAT_KEYWORDS = [
    (r"earbuds?|earbud|tws|buds",                                              "Earbuds"),
    (r"headset|headphone|\bwh-|\bwf-|\bxm[0-9]",                              "Headset"),
    (r"speaker|soundbar|\bsrs-|\bult |stanmore|woburn|acton|kilburn|emberton", "Speaker"),
    (r"mouse|mice|trackball|trackpad|mx anywhere|mx master",                   "Mouse"),
    (r"keyboard|numpad|\bmx keys",                                             "Keyboard"),
    (r"gamepad|controller|joystick|xbox|dualshock|dualsense",                  "Controller"),
    (r"watch|band|tracker|fitness",                                            "Wearable"),
    (r"pen|stylus",                                                            "Stylus"),
]

# Method B: HID UUID sub-keywords
_HID_MOUSE_KW    = r"mouse|mice|trackball|trackpad|touchpad|mx anywhere|mx master|lift|pebble"
_HID_KEYBOARD_KW = r"keyboard|numpad|\bmx keys\b|\bk[0-9]{3}\b"


def get_device_category(
    mac: str,
    friendly_name: str,
    children_ids: list[str],
    protocol: str,
    instance_id: str,
) -> tuple[str, str]:
    """Returns (category, source_label)."""

    # Method A0 — DEVPKEY_DeviceContainer_Category
    if instance_id:
        cats = get_pnp_device_property(instance_id, "DEVPKEY_DeviceContainer_Category")
        if cats:
            for cat in cats:
                for pattern, label in _CAT_MAP:
                    if re.match(pattern, cat, re.IGNORECASE):
                        return label, f"Method A0 (DeviceContainer_Category='{cat}')"

    # Method A — Class of Device (Classic BT only)
    if protocol == "Classic" and mac:
        cod = get_cod_from_registry(mac)
        if cod is not None:
            major = (cod >> 8) & 0x1F
            minor = (cod >> 2) & 0x3F
            source = f"Method A (CoD=0x{cod:06X} Major={major})"
            if major == 4:   # Audio/Video
                mapping = {1: "Headset", 2: "Headset", 5: "Speaker",
                           6: "Headphones", 7: "Speaker"}
                return mapping.get(minor, "Audio"), source
            if major == 5:   # Peripheral
                hid_bits = (minor >> 4) & 0x03
                mapping = {1: "Keyboard", 2: "Mouse", 3: "Keyboard+Mouse"}
                return mapping.get(hid_bits, "HID"), source
            if major == 2:
                return "Phone", source
            if major == 1:
                return "Computer", source

    # Method B — UUID profiles in children
    has_hfp  = any("0000111E" in iid for iid in children_ids)
    has_a2dp = any("0000110B" in iid for iid in children_ids)
    has_hogp = any("00001812" in iid for iid in children_ids)
    has_hid  = any(re.search(r"00001124|00001812", iid) for iid in children_ids)

    if has_hfp and has_a2dp:
        return "Headset", "Method B (UUID: HFP+A2DP)"
    if has_hfp:
        return "Headset", "Method B (UUID: HFP)"
    if has_a2dp:
        return "Headphones/Speaker", "Method B (UUID: A2DP)"
    if has_hid or has_hogp:
        hid_uuid = "00001812 HID-over-GATT" if has_hogp else "00001124 HID-Classic"
        nl = friendly_name.lower()
        if re.search(_HID_MOUSE_KW, nl):
            return "Mouse", f"Method B (UUID: {hid_uuid}) + name keyword"
        if re.search(_HID_KEYBOARD_KW, nl):
            return "Keyboard", f"Method B (UUID: {hid_uuid}) + name keyword"
        return "HID", f"Method B (UUID: {hid_uuid})"

    # Method C — FriendlyName keywords
    nl = friendly_name.lower()
    for pattern, label in _NAME_CAT_KEYWORDS:
        if re.search(pattern, nl):
            return label, "Method C (name keyword)"

    return "Unknown", "N/A"


# ---------------------------------------------------------------------------
# 6. Main scan
# ---------------------------------------------------------------------------

@dataclass
class BtDevice:
    name:            str
    protocols:       list[str]      = field(default_factory=list)
    macs:            list[str]      = field(default_factory=list)
    brand:           str            = ""
    brand_method:    str            = ""
    audio_mode:      str            = ""
    device_category: str            = ""
    instance_id:     str            = ""


def scan_bluetooth_devices(debug: bool = True) -> list[BtDevice]:
    t0 = time.perf_counter()
    vid_table     = load_vid_table()
    usb_vid_table = load_usb_vid_table()
    t1 = time.perf_counter()
    print(f"[TIMING] Load tables      : {t1 - t0:.3f}s")

    all_pnp = get_all_pnp_devices()
    t2 = time.perf_counter()
    print(f"[TIMING] Get-PnpDevice    : {t2 - t1:.3f}s  ({len(all_pnp)} devices)")

    # --- Pass 1: collect root BT device nodes ---
    device_map: dict[str, BtDevice] = {}
    root_pattern = re.compile(r'BTH(ENUM|LE)\\DEV_([0-9a-fA-F]{12})', re.IGNORECASE)

    for dev in all_pnp:
        iid    = dev["InstanceId"]
        status = dev["Status"]
        if not root_pattern.search(iid) or status != "OK":
            continue

        name     = dev["FriendlyName"] or iid
        protocol = "LE" if re.search(r"BTHLE", iid, re.IGNORECASE) else "Classic"

        m = re.search(r'DEV_([0-9a-fA-F]{12})', iid, re.IGNORECASE)
        mac = m.group(1).upper() if m else ""

        if debug:
            print("=" * 65)
            print(f"[DEBUG] Device Name : {name}")
            print(f"[DEBUG] Protocol    : {protocol}")
            print(f"[DEBUG] InstanceId  : {iid}")

        if name not in device_map:
            device_map[name] = BtDevice(name=name, instance_id=iid)
        dev_entry = device_map[name]
        if protocol not in dev_entry.protocols:
            dev_entry.protocols.append(protocol)
        if mac and mac not in dev_entry.macs:
            dev_entry.macs.append(mac)

    print()
    t_pass2_start = time.perf_counter()
    print(f"[TIMING] Pass 1 (collect) : {t_pass2_start - t2:.3f}s  ({len(device_map)} devices found)")

    # --- Pass 2: profile + brand + category detection ---
    for name, entry in device_map.items():
        macs = entry.macs
        if not macs:
            continue

        # Collect children (all PnP nodes whose InstanceId contains any of the MACs)
        children = [d for d in all_pnp
                    if any(mac in d["InstanceId"].upper() for mac in macs)]
        children_ids = [d["InstanceId"] for d in children]

        if debug:
            print("=" * 65)
            print(f"[DEBUG] [{name}] children matched: {len(children)} "
                  f"(MACs={','.join(macs)})")

        has_a2dp    = any("0000110B" in iid for iid in children_ids)
        has_hfp     = any("0000111E" in iid for iid in children_ids)
        has_le_proxy = any("APXENUM" in iid.upper() for iid in children_ids)

        if debug:
            print(f"[DEBUG] [{name}] A2DP={has_a2dp} HFP={has_hfp} "
                  f"LEProxy={has_le_proxy}")

        # -- Brand detection (VID → FriendlyName keyword → OUI) --
        final_brand, final_method = "", ""

        vid_entry_id = next((iid for iid in children_ids
                             if re.search(r'VID[&]', iid, re.IGNORECASE)), None)
        if vid_entry_id:
            if debug:
                print(f"[DEBUG] [{name}] VID child  : {vid_entry_id}")
            raw_vid, vid_source = get_brand_by_vid(vid_entry_id, vid_table, usb_vid_table)
            m = re.search(r'VID[&]([0-9a-fA-F]+)', vid_entry_id, re.IGNORECASE)
            if m:
                full = m.group(1).upper()
                vid_id_str = f"0x{full[-4:]}"
                pfx = full[:-4]
                vs = "BT-SIG" if pfx in ("01", "0001") else f"USB-IF(prefix={pfx})"
                if debug:
                    print(f"[DEBUG] [{name}] VID        : {vid_id_str} (source={vs})")
            if raw_vid:
                if debug:
                    print(f"[DEBUG] [{name}] VID raw    : {raw_vid}")
                final_brand  = normalize_brand(raw_vid)
                final_method = f"Method 1 ({vid_source} VID)"

        if not final_brand:
            nl = name.lower()
            for pattern, brand_name in NAME_BRAND_KEYWORDS:
                if re.search(pattern, nl):
                    final_brand  = brand_name
                    final_method = f"Method 2 (FriendlyName keyword) matched: '{pattern}'"
                    break

        if not final_brand:
            final_brand, final_method = "Unknown", "N/A"

        if debug:
            print(f"[DEBUG] [{name}] Brand source: {final_method} -> {final_brand}")

        entry.brand        = final_brand
        entry.brand_method = final_method

        if has_a2dp or has_hfp:
            entry.audio_mode = "Classic"
        elif has_le_proxy:
            entry.audio_mode = "LE"

        # -- Device category --
        primary_mac      = macs[0] if macs else ""
        primary_protocol = entry.protocols[0] if entry.protocols else ""
        category, cat_source = get_device_category(
            mac=primary_mac,
            friendly_name=name,
            children_ids=children_ids,
            protocol=primary_protocol,
            instance_id=entry.instance_id,
        )
        if debug:
            print(f"[DEBUG] [{name}] DeviceCategory: {category} (source={cat_source})")
        entry.device_category = category

    t_end = time.perf_counter()
    print()
    print(f"[TIMING] Pass 2 (resolve) : {t_end - t_pass2_start:.3f}s")
    print(f"[TIMING] Total            : {t_end - t0:.3f}s")
    return list(device_map.values())


# ---------------------------------------------------------------------------
# 7. Entry point
# ---------------------------------------------------------------------------

def main():
    devices = scan_bluetooth_devices(debug=False)

    print()
    print(f"{'Device Name':<32} {'Category':<18} {'Type':<22} {'Brand'}")
    print(f"{'-----------':<32} {'--------':<18} {'----':<22} {'-----'}")
    for d in devices:
        if d.audio_mode:
            type_str = d.audio_mode
        elif len(d.protocols) == 2:
            type_str = "Dual Mode (Classic + LE)"
        else:
            type_str = d.protocols[0] if d.protocols else ""
        print(f"{d.name:<32} {d.device_category:<18} {type_str:<22} {d.brand}")


if __name__ == "__main__":
    main()
