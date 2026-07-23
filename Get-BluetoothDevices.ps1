# 1b. Load Bluetooth SIG company identifiers (VID → company name)
$vidYamlPath = Join-Path $PSScriptRoot "data\company_identifiers.yaml"
if (-not (Test-Path $vidYamlPath)) {
    Write-Host "[INFO] company_identifiers.yaml not found. Downloading from Bluetooth SIG..."
    try {
        Invoke-WebRequest -Uri "https://bitbucket.org/bluetooth-SIG/public/raw/HEAD/assigned_numbers/company_identifiers/company_identifiers.yaml" `
            -OutFile $vidYamlPath -TimeoutSec 30 -ErrorAction Stop `
            -Proxy "http://proxy-dmz.intel.com:912" -ProxyUseDefaultCredentials `
            -UseBasicParsing
        Write-Host "[INFO] Download complete: $vidYamlPath"
    } catch {
        Write-Warning "Failed to download company_identifiers.yaml: $_"
    }
}

$vidTable = @{}
if (Test-Path $vidYamlPath) {
    $lines = Get-Content $vidYamlPath
    for ($i = 0; $i -lt $lines.Count - 1; $i++) {
        if ($lines[$i] -match '\bvalue:\s*(0x[0-9a-fA-F]+)') {
            $hexVal = $Matches[1].ToUpper()  # e.g. "0X0075"
            $key = $hexVal -replace '0X','0x'  # normalize to "0x0075"
            if ($lines[$i+1] -match 'name:\s*[''"]{0,1}(.+?)[''"]{0,1}\s*$') {
                $vidTable[$key] = $Matches[1].Trim()
            }
        }
    }
    Write-Host "[INFO] VID table loaded: $($vidTable.Count) entries"
}

function Get-BrandByVID {
    param([string]$instanceId)  # full InstanceId string
    # VID&[prefix][4-digit ID]: prefix can be 2 or 4 hex digits, ID is always last 4
    # Classic BT: prefix 01=BT SIG, 02=USB-IF
    # BLE:        prefix 0001=BT SIG, 0002=USB-IF
    # Strategy: if BT SIG prefix (01 or 0001), try both tables and prefer whichever
    #           matches a known brand in brandNormalize. This handles devices (e.g.
    #           Xbox Wireless Headset) that declare BT SIG source but embed a USB-IF VID.
    #           Otherwise go straight to USB-IF.
    if ($instanceId -match 'VID[&]([0-9a-fA-F]+)') {
        $full   = $Matches[1].ToUpper()
        $id     = $full.Substring($full.Length - 4)   # last 4 = actual VID
        $prefix = $full.Substring(0, $full.Length - 4) # remaining = prefix
        $isBtSig = ($prefix -eq '01' -or $prefix -eq '0001')
        if ($isBtSig) {
            $btSigResult  = if ($vidTable.ContainsKey("0x$id"))    { $vidTable["0x$id"] }    else { "" }
            $usbIfResult  = if ($usbVidTable.ContainsKey($id))     { $usbVidTable[$id] }     else { "" }

            $btSigKnown  = ($btSigResult  -ne "") -and ($btSigResult  | ForEach-Object { $lower = $_.ToLower(); $brandNormalize.Keys | Where-Object { $lower -match $_ } | Select-Object -First 1 })
            $usbIfKnown  = ($usbIfResult  -ne "") -and ($usbIfResult  | ForEach-Object { $lower = $_.ToLower(); $brandNormalize.Keys | Where-Object { $lower -match $_ } | Select-Object -First 1 })

            if ($btSigKnown) {
                # BT SIG result is a recognised brand — trust it
                $script:lastVidSource = 'BT-SIG'; return $btSigResult
            } elseif ($usbIfKnown) {
                # BT SIG result is unknown / obscure; USB-IF gives a recognised brand — prefer it
                $script:lastVidSource = "USB-IF(prefix=$prefix)"; return $usbIfResult
            } elseif ($btSigResult -ne "") {
                # Neither is a known brand, but BT SIG has something — return it
                $script:lastVidSource = 'BT-SIG'; return $btSigResult
            }
        }
        # USB-IF table (either explicit USB-IF prefix, or BT SIG lookup produced nothing)
        if ($usbVidTable.ContainsKey($id)) { $script:lastVidSource = "USB-IF(prefix=$prefix)"; return $usbVidTable[$id] }
    }
    return ""
}

# 1c. Load USB-IF vendor IDs (usb.ids)
$usbIdsPath = Join-Path $PSScriptRoot "data\usb.ids"
if (-not (Test-Path $usbIdsPath)) {
    Write-Host "[INFO] usb.ids not found. Downloading from linux-usb.org..."
    try {
        Invoke-WebRequest -Uri "http://www.linux-usb.org/usb.ids" `
            -OutFile $usbIdsPath -TimeoutSec 30 -ErrorAction Stop `
            -Proxy "http://proxy-dmz.intel.com:912" -ProxyUseDefaultCredentials `
            -UseBasicParsing
        Write-Host "[INFO] Download complete: $usbIdsPath"
    } catch {
        Write-Warning "Failed to download usb.ids: $_"
    }
}

$usbVidTable = @{}
if (Test-Path $usbIdsPath) {
    foreach ($line in [System.IO.File]::ReadLines($usbIdsPath)) {
        if ($line -match '^([0-9a-fA-F]{4})\s{2}(.+)$') {
            $usbVidTable[$Matches[1].ToUpper()] = $Matches[2].Trim()
        }
    }
    Write-Host "[INFO] USB VID table loaded: $($usbVidTable.Count) entries"
}


$brandNormalize = [ordered]@{
    # Apple
    "apple"                        = "Apple"
    # Samsung
    "samsung"                      = "Samsung"
    # Sony
    "sony"                         = "Sony"
    # Bose
    "bose"                         = "Bose"
    # Jabra (GN Audio)
    "gn audio"                     = "Jabra"
    "jabra"                        = "Jabra"
    # Logitech
    "logitech"                     = "Logitech"
    # Plantronics / Poly
    "plantronics"                  = "Plantronics/Poly"
    "poly"                         = "Plantronics/Poly"
    # Beats
    "beats"                        = "Beats"
    # JBL / Harman
    "harman"                       = "JBL"
    # Sennheiser
    "sennheiser"                   = "Sennheiser"
    # Bang & Olufsen
    "bang.*olufsen"                = "Bang & Olufsen"
    # Anker / Soundcore
    "anker"                        = "Anker/Soundcore"
    # Huawei
    "huawei"                       = "Huawei"
    # Razer
    "razer"                        = "Razer"
    # Skullcandy
    "skullcandy"                   = "Skullcandy"
    # SteelSeries
    "steelseries"                  = "SteelSeries"
    # Corsair
    "corsair"                      = "Corsair"
    # HyperX / HP
    "hyperx"                       = "HyperX"
    # HP
    "hewlett"                      = "HP"
    "hp inc"                       = "HP"
    "hp, Inc"                       = "HP"
    # Dell
    "jingxun"                      = "Dell"
    "dell computer corp"            = "Dell"
    # Microsoft
    "microsoft"                    = "Microsoft"
    # Google
    "google"                       = "Google"
    # Qualcomm (chip vendor, not end brand — keep as-is but map for clarity)
    "qualcomm"                     = "Qualcomm"
}

function Normalize-Brand {
    param([string]$rawVendor)
    $lower = $rawVendor.ToLower()
    foreach ($pattern in $brandNormalize.Keys) {
        if ($lower -match $pattern) {
            return $brandNormalize[$pattern]
        }
    }
    return $rawVendor  # return original if no match
}

# 3a. Device category detection
#     Priority: DeviceContainer_Category → CoD (registry) → UUID profiles → FriendlyName keywords
function Get-DeviceCategory {
    param(
        [string]$mac,          # 12-char uppercase MAC, e.g. "B85C5C03B3EB"
        [string]$friendlyName, # device display name
        [object[]]$children,   # PnpDevice children already collected
        [string]$protocol,     # "Classic" or "LE"
        [string]$instanceId    # PnP InstanceId of the root BT device node
    )
    $script:lastCategorySource = 'Unknown'

    # --- Method A0: DEVPKEY_DeviceContainer_Category (Windows HID stack / metadata) ---
    if ($instanceId) {
        $containerCats = (Get-PnpDeviceProperty -InstanceId $instanceId `
            -KeyName 'DEVPKEY_DeviceContainer_Category' -ErrorAction SilentlyContinue).Data
        if ($containerCats) {
            # Data is a StringList; check each entry against known patterns
            $catMap = [ordered]@{
                '^Input\.Mouse'              = 'Mouse'
                '^Input\.Keyboard'           = 'Keyboard'
                '^Input\.Gamepad'            = 'Controller'
                '^Input\.Joystick'           = 'Controller'
                '^Audio\.Headset'            = 'Headset'
                '^Communication\.Headset'    = 'Headset'
                '^Audio\.Headphones'         = 'Headphones'
                '^Audio\.Earbuds'            = 'Earbuds'
                '^Audio\.Speaker'            = 'Speaker'
                '^Wearable'                  = 'Wearable'
                '^Phone'                     = 'Phone'
                '^Computer'                  = 'Computer'
            }
            foreach ($cat in $containerCats) {
                foreach ($pattern in $catMap.Keys) {
                    if ($cat -match $pattern) {
                        $script:lastCategorySource = "Method A0 (DeviceContainer_Category='$cat')"
                        return $catMap[$pattern]
                    }
                }
            }
        }
    }

    # --- Method A: Class of Device (CoD) from registry (Classic BT only) ---
    if ($protocol -eq 'Classic' -and $mac) {
        $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Devices\$($mac.ToLower())"
        try {
            $cod = (Get-ItemProperty -Path $regPath -Name 'ClassOfDevice' -ErrorAction Stop).ClassOfDevice
            $majorClass = ($cod -shr 8) -band 0x1F
            $minorClass = ($cod -shr 2) -band 0x3F
            switch ($majorClass) {
                4 {  # Audio/Video
                    $script:lastCategorySource = "Method A (CoD=0x$('{0:X6}' -f $cod) Major=4 Audio/Video)"
                    switch ($minorClass) {
                        1  { return 'Headset' }     # Wearable Headset
                        2  { return 'Headset' }     # Hands-free
                        5  { return 'Speaker' }     # Loudspeaker
                        6  { return 'Headphones' }  # Headphones
                        7  { return 'Speaker' }     # Portable Audio
                        default { return 'Audio' }
                    }
                }
                5 {  # Peripheral (HID)
                    $script:lastCategorySource = "Method A (CoD=0x$('{0:X6}' -f $cod) Major=5 HID)"
                    $hidbits = ($minorClass -shr 4) -band 0x03
                    switch ($hidbits) {
                        1 { return 'Keyboard' }
                        2 { return 'Mouse' }
                        3 { return 'Keyboard+Mouse' }
                        default { return 'HID' }
                    }
                }
                2 { $script:lastCategorySource = "Method A (CoD Major=2 Phone)";    return 'Phone' }
                1 { $script:lastCategorySource = "Method A (CoD Major=1 Computer)"; return 'Computer' }
                default { return '' }  # unknown, try next method
            }
        } catch { <# registry key not found — continue #> }
    }

    # --- Method B: UUID profiles in children ---
    $uuids = $children | ForEach-Object { $_.InstanceId } | Where-Object { $_ -match '[0-9a-fA-F]{8}-' }
    $hasHFP   = $children | Where-Object { $_.InstanceId -match '0000111E' }
    $hasA2DP  = $children | Where-Object { $_.InstanceId -match '0000110B' }
    $hasHID   = $children | Where-Object { $_.InstanceId -match '00001124|00001812|00001812' }
    $hasHOGP  = $children | Where-Object { $_.InstanceId -match '00001812' }  # HID over GATT (BLE)

    if ($hasHFP -and $hasA2DP) { $script:lastCategorySource = 'Method B (UUID: HFP+A2DP)';  return 'Headset' }
    if ($hasHFP)                { $script:lastCategorySource = 'Method B (UUID: HFP)';       return 'Headset' }
    if ($hasA2DP)               { $script:lastCategorySource = 'Method B (UUID: A2DP)';      return 'Headphones/Speaker' }
    if ($hasHID -or $hasHOGP) {
        # Distinguish mouse vs keyboard by name heuristic
        $nl = $friendlyName.ToLower()
        $hidUuid = if ($hasHOGP) { '00001812 HID-over-GATT' } else { '00001124 HID-Classic' }
        if ($nl -match 'mouse|mice|trackball|trackpad|touchpad|mx anywhere|mx master|lift|pebble') {
            $script:lastCategorySource = "Method B (UUID: $hidUuid) + name keyword"; return 'Mouse'
        }
        if ($nl -match 'keyboard|numpad|\bmx keys\b|\bk[0-9]{3}\b') {
            $script:lastCategorySource = "Method B (UUID: $hidUuid) + name keyword"; return 'Keyboard'
        }
        $script:lastCategorySource = "Method B (UUID: $hidUuid)"; return 'HID'
    }

    # --- Method C: FriendlyName keywords ---
    $nl = $friendlyName.ToLower()
    if ($nl -match 'earbuds?|earbud|tws|buds')                   { $script:lastCategorySource = 'Method C (name keyword)'; return 'Earbuds' }
    if ($nl -match 'headset|headphone|\bwh-|\bwf-|\bxm[0-9]')   { $script:lastCategorySource = 'Method C (name keyword)'; return 'Headset' }
    if ($nl -match 'speaker|soundbar|\bsrs-|\bult |stanmore|woburn|acton|kilburn|emberton') { $script:lastCategorySource = 'Method C (name keyword)'; return 'Speaker' }
    if ($nl -match 'mouse|mice|trackball|trackpad|mx anywhere|mx master') { $script:lastCategorySource = 'Method C (name keyword)'; return 'Mouse' }
    if ($nl -match 'keyboard|numpad|\bmx keys')                  { $script:lastCategorySource = 'Method C (name keyword)'; return 'Keyboard' }
    if ($nl -match 'gamepad|controller|joystick|xbox|dualshock|dualsense') { $script:lastCategorySource = 'Method C (name keyword)'; return 'Controller' }
    if ($nl -match 'watch|band|tracker|fitness')                 { $script:lastCategorySource = 'Method C (name keyword)'; return 'Wearable' }
    if ($nl -match 'pen|stylus')                                 { $script:lastCategorySource = 'Method C (name keyword)'; return 'Stylus' }

    return 'Unknown'
}

# 3. deviceMap
$deviceMap = @{}

# 4. Scan connected Bluetooth devices
Get-PnpDevice -Class Bluetooth | Where-Object {
    ($_.InstanceId -match 'BTH(ENUM|LE)\\DEV_([0-9a-fA-F]{12})') -and ($_.Status -eq 'OK')
} | ForEach-Object {
    
    Write-Host "================================================================="
    $name       = $_.FriendlyName
    $instanceId = $_.InstanceId
    $protocol   = if ($instanceId -match "BTHLE") { "LE" } else { "Classic" }

    Write-Host "[DEBUG] Device Name : $name"
    Write-Host "[DEBUG] Protocol    : $protocol"
    Write-Host "[DEBUG] InstanceId  : $instanceId"

    # --- write to deviceMap ---
    if ($instanceId -match 'DEV_([0-9a-fA-F]{12})') { $mac = $Matches[1].ToUpper() } else { $mac = "" }
    if (-not $deviceMap.ContainsKey($name)) {
        $deviceMap[$name] = @{
            Protocols      = [System.Collections.Generic.List[string]]::new()
            Brand          = ""
            BrandMethod    = ""
            MACs           = [System.Collections.Generic.List[string]]::new()
            AudioMode      = ""
            DeviceCategory = ""
            InstanceId     = $instanceId
        }
    }
    if ($mac -and -not $deviceMap[$name].MACs.Contains($mac)) {
        $deviceMap[$name].MACs.Add($mac)
    }
    if (-not $deviceMap[$name].Protocols.Contains($protocol)) {
        $deviceMap[$name].Protocols.Add($protocol)
    }
}

# 4b. Profile detection pass — determine actual audio transport per device
$allPnpDevices = Get-PnpDevice
foreach ($key in $deviceMap.Keys) {
    $macs = $deviceMap[$key].MACs
    if (-not $macs -or $macs.Count -eq 0) { continue }

    $children = $allPnpDevices | Where-Object {
        $id = $_.InstanceId
        $found = $false
        foreach ($m in $macs) { if ($id -match $m) { $found = $true; break } }
        $found
    }

    Write-Host "[DEBUG] [$key] children matched: $(($children | Measure-Object).Count) (MACs=$($macs -join ','))"

    $hasA2DP     = $children | Where-Object { $_.InstanceId -match '0000110B' }
    $hasHFP      = $children | Where-Object { $_.InstanceId -match '0000111E' }
    $hasLEProxy = $allPnpDevices | Where-Object {
        $id = $_.InstanceId
        if ($id -notmatch 'APXENUM') { return $false }
        $found = $false
        foreach ($m in $macs) { if ($id -match $m) { $found = $true; break } }
        $found
    }

    Write-Host "[DEBUG] [$key] A2DP=$([bool]$hasA2DP) HFP=$([bool]$hasHFP) LEProxy=$([bool]$hasLEProxy)"

    # --- Brand detection (VID > FriendlyName) ---
    $finalBrand = ""
    $finalMethod = ""

    # Priority 1: VID lookup (Bluetooth SIG — most accurate, identifies end-product manufacturer)
    $vidEntry = $children | Where-Object { $_.InstanceId -match 'VID[&]' } | Select-Object -First 1
    if ($vidEntry) {
        Write-Host "[DEBUG] [$key] VID child  : $($vidEntry.InstanceId)"
        $vidId = ""
        if ($vidEntry.InstanceId -match 'VID[&]([0-9a-fA-F]+)') {
            $full = $Matches[1].ToUpper()
            $id   = $full.Substring($full.Length - 4)
            $pfx  = $full.Substring(0, $full.Length - 4)
            $vidId = "0x$id"
            $vidSource = if ($pfx -eq '01' -or $pfx -eq '0001') { 'BT-SIG' } else { "USB-IF(prefix=$pfx)" }
        }
        Write-Host "[DEBUG] [$key] VID        : $vidId (source=$vidSource)"
        $script:lastVidSource = ''
        $rawVid = Get-BrandByVID -instanceId $vidEntry.InstanceId
        if ($rawVid) {
            Write-Host "[DEBUG] [$key] VID raw    : $rawVid"
            $finalBrand = Normalize-Brand -rawVendor $rawVid
            $finalMethod = "Method 1 ($($script:lastVidSource) VID)"
        }
    }

    # Priority 2: FriendlyName keyword
    if (-not $finalBrand) {
        $nameLower = $key.ToLower()
        $nameKeywords = [ordered]@{
            "airpods|apple watch|iphone|ipad|macbook" = "Apple"
            "galaxy buds|galaxy watch|samsung"        = "Samsung"
            "\bwh-|\bwf-|\bxm[0-9]|\bsrs-|\bult "     = "Sony"
            "\bbose\b"                                = "Bose"
            "\bjabra\b"                               = "Jabra"
            "logitech|\bmx \b|\bmx keys\b"            = "Logitech"
            "plantronics|\bpoly\b|voyager"            = "Plantronics/Poly"
            "\bbeats\b|powerbeats"                    = "Beats"
            "\bjbl\b"                                 = "JBL"
            "sennheiser|momentum|accentum"            = "Sennheiser"
            "beoplay|bang.*olufsen|\bb&o\b"           = "Bang & Olufsen"
            "soundcore|\banker\b"                     = "Anker/Soundcore"
            "freebuds|freelace|huawei"                = "Huawei"
            "\brazer\b|barracuda"                     = "Razer"
            "skullcandy|crusher|hesh"                 = "Skullcandy"
            "steelseries|arctis"                      = "SteelSeries"
            "\bcorsair\b|virtuoso"                    = "Corsair"
            "\bhyperx\b|cloud alpha|cloud ii"         = "HyperX"
            "surface|xbox"                            = "Microsoft"
            "pixel buds|google"                       = "Google"
            "\bhp\b|hewlett"                          = "HP"
            "\bdell\b"                                = "Dell"
            "emberton|stanmore|woburn|acton|kilburn"  = "Marshall"
        }
        foreach ($pattern in $nameKeywords.Keys) {
            if ($nameLower -match $pattern) {
                $finalBrand = $nameKeywords[$pattern]
                $finalMethod = "Method 2 (FriendlyName keyword) matched: '$pattern'"
                break
            }
        }
    }

    if (-not $finalBrand) { $finalBrand = "Unknown"; $finalMethod = "N/A" }

    Write-Host "[DEBUG] [$key] Brand source: $finalMethod -> $finalBrand"
    $deviceMap[$key].Brand = $finalBrand
    $deviceMap[$key].BrandMethod = $finalMethod

    # OEM override: VID resolves to ODM/chip vendor but device name reveals actual brand
    if ($deviceMap[$key].Brand -eq 'Creative Technology, Ltd' -and $key -match '\bdell\b') {
        $deviceMap[$key].Brand = 'Dell'
        $deviceMap[$key].BrandMethod = 'Method OEM override (ODM=Creative->Dell)'
        Write-Host "[DEBUG] [$key] OEM override  : Creative Technology, Ltd -> Dell"
    }

    if ($hasA2DP -or $hasHFP) {
        $deviceMap[$key].AudioMode = "Classic"
    } elseif ($hasLEProxy) {
        $deviceMap[$key].AudioMode = "LE"
    }
    # else: non-audio device (mouse/keyboard etc.) — AudioMode empty, falls back to protocol (Classic/LE)

    # --- Device category ---
    $primaryMac      = $deviceMap[$key].MACs | Select-Object -First 1
    $primaryProtocol = $deviceMap[$key].Protocols | Select-Object -First 1
    $primaryInstanceId = $deviceMap[$key].InstanceId
    $script:lastCategorySource = ''
    $category = Get-DeviceCategory -mac $primaryMac -friendlyName $key -children $children -protocol $primaryProtocol -instanceId $primaryInstanceId
    Write-Host "[DEBUG] [$key] DeviceCategory: $category (source=$($script:lastCategorySource))"
    $deviceMap[$key].DeviceCategory = $category
}

# 5. Output
Write-Host ""
Write-Host ("{0,-32} {1,-18} {2,-20} {3}" -f "Device Name", "Category", "Type", "Brand")
Write-Host ("{0,-32} {1,-18} {2,-20} {3}" -f "-----------", "--------", "----", "-----")

foreach ($key in $deviceMap.Keys) {
    $protocols  = $deviceMap[$key].Protocols
    $brand      = $deviceMap[$key].Brand
    $audioMode  = $deviceMap[$key].AudioMode
    $category   = $deviceMap[$key].DeviceCategory
    if ($audioMode) {
        $typeString = $audioMode
    } elseif ($protocols.Count -eq 2) {
        $typeString = "Dual Mode (Classic + LE)"
    } else {
        $typeString = [string]$protocols[0]
    }
    Write-Host ("{0,-32} {1,-18} {2,-20} {3}" -f $key, $category, $typeString, $brand)
}

Pause
