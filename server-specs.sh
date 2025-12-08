#!/bin/bash
# ============================================================
#   UNIVERSAL HARDWARE INVENTORY TOOL
#   Modes: Human-readable, JSON, JSON-tree
#   Portable across all major Linux distros
# ============================================================

set -o pipefail
export LANG=C

# ---------------------------
#   COLOR DEFINITIONS
# ---------------------------
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
NC='\033[0m'

header()  { echo -e "\n${BLUE}$1${NC}"; }
log()     { echo -e "${GREEN}$1${NC}"; }
warn()    { echo -e "${YELLOW}Warning:${NC} $1"; }
error()   { echo -e "${RED}Error:${NC} $1"; exit 1; }
separator(){ echo -e "${BLUE}-----------------------------------${NC}"; }

show_help() {
cat << EOF

Usage: $0 [OPTIONS]

Options:
  --json        Output hardware info in namespaced JSON
  --json-tree   Output hardware info as hierarchical JSON tree
  --validate    Run environment validation only
  -h, --help    Show this help and exit

EOF
exit 0
}

# ---------------------------
#   MODE SELECTION
# ---------------------------
JSON_MODE=0
JSON_TREE_MODE=0
VALIDATE_MODE=0

case "$1" in
    --json) JSON_MODE=1 ;;
    --json-tree) JSON_TREE_MODE=1 ;;
    --validate) VALIDATE_MODE=1 ;;
    -h|--help) show_help ;;
esac

# ---------------------------
#   TOOL CHECKER
# ---------------------------
has() { command -v "$1" >/dev/null 2>&1; }

check_tools() {
    declare -A tools=(
        ["dmidecode"]="DMI tables"
        ["lscpu"]="CPU info"
        ["smartctl"]="Disk SMART info"
        ["lspci"]="PCI devices"
        ["ip"]="Network interfaces"
        ["jq"]="JSON processing"
    )

    local missing=()
    for t in "${!tools[@]}"; do
        ! has "$t" && missing+=("$t")
    done

    if [ ${#missing[@]} -ne 0 ]; then
        echo -e "${RED}Error: Missing required tools:${NC}"
        for t in "${missing[@]}"; do
            echo "  - $t (needed for: ${tools[$t]})"
        done
        exit 1
    fi
}

# ---------------------------
#   SUDO HANDLER
# ---------------------------
if [[ $EUID -eq 0 ]]; then
    SUDO=""
elif has sudo; then
    SUDO="sudo"
    $SUDO -n true 2>/dev/null || warn "sudo password may be required"
else
    SUDO=""
    warn "Not root and sudo not available — some info may be missing"
fi

# ---------------------------
#   GLOBAL JSON OBJECTS
# ---------------------------
system_info_json="{}"
cpu_json="{}"
ram_json="{}"
ram_devices_json="[]"
disks_json="[]"
raid_json="{}"
pci_json="[]"
gpu_json="[]"
net_json="[]"

# =====================================================================
#   SECTION 1: SYSTEM & BIOS
# =====================================================================
fetch_system_info() {
    header "1. System Information"
    separator

    local vendor="" product="" serial="" uuid="" bios_vendor="" bios_version="" bios_date=""

    if has dmidecode; then
        vendor=$($SUDO dmidecode -s system-manufacturer 2>/dev/null || true)
        product=$($SUDO dmidecode -s system-product-name 2>/dev/null || true)
        serial=$($SUDO dmidecode -s system-serial-number 2>/dev/null || true)
        uuid=$($SUDO dmidecode -s system-uuid 2>/dev/null || true)
        bios_vendor=$($SUDO dmidecode -s bios-vendor 2>/dev/null || true)
        bios_version=$($SUDO dmidecode -s bios-version 2>/dev/null || true)
        bios_date=$($SUDO dmidecode -s bios-release-date 2>/dev/null || true)
    else
        warn "dmidecode missing – limited system info."
    fi

    echo -e "Vendor: $vendor\nProduct: $product\nSerial: $serial\nUUID: $uuid"
    echo -e "BIOS Vendor: $bios_vendor\nBIOS Version: $bios_version\nBIOS Date: $bios_date"

    system_info_json=$(jq -n \
        --arg vendor "$vendor" --arg product "$product" --arg serial "$serial" --arg uuid "$uuid" \
        --arg bios_vendor "$bios_vendor" --arg bios_version "$bios_version" --arg bios_date "$bios_date" \
        '{ vendor: $vendor, product: $product, serial: $serial, uuid: $uuid,
           bios: { vendor: $bios_vendor, version: $bios_version, date: $bios_date } }')
}

# =====================================================================
#   SECTION 2: CPU
# =====================================================================
fetch_cpu_info() {
    header "2. CPU Information"
    separator

    # Initialize variables
    local arch="" model="" cpus="" cores="" sockets="" maxmhz=""

    if has lscpu; then
        arch=$(lscpu | awk -F: '/Architecture/ {print $2}' | xargs)
        model=$(lscpu | awk -F: '/Model name/ {print $2}' | xargs)
        cpus=$(lscpu | awk -F: '/^CPU\(s\)/ {print $2}' | xargs)
        cores=$(lscpu | awk -F: '/Core\(s\) per socket/ {print $2}' | xargs)
        sockets=$(lscpu | awk -F: '/Socket\(s\)/ {print $2}' | xargs)
        maxmhz=$(lscpu | awk -F: '/CPU max MHz/ {print $2}' | xargs)
    else
        warn "lscpu missing – limited CPU info."
    fi

    # Human-readable output
    cat << EOF
Model:           $model
Architecture:    $arch
CPU Count:       $cpus
Cores / Socket:  $cores
Sockets:         $sockets
Max MHz:         $maxmhz
EOF

    # JSON output
    cpu_json=$(jq -n \
        --arg arch "$arch" \
        --arg model "$model" \
        --arg cpus "$cpus" \
        --arg cores "$cores" \
        --arg sockets "$sockets" \
        --arg maxmhz "$maxmhz" \
        '{ 
            architecture: $arch, 
            model: $model, 
            cpus: $cpus, 
            cores_per_socket: $cores,
            sockets: $sockets, 
            max_mhz: $maxmhz 
        }')
}

# fetch_cpu_info() {
#     header "2. CPU Information"
#     separator
#
#     if has lscpu; then
#         cpu_json=$(lscpu | awk -F: '
#             /Architecture/ {arch=$2}
#             /Model name/ {model=$2}
#             /^CPU\(s\)/ {cpus=$2}
#             /Core\(s\) per socket/ {cores=$2}
#             /Socket\(s\)/ {sockets=$2}
#             /CPU max MHz/ {maxmhz=$2}
#             END {gsub(/^[ \t]+|[ \t]+$/, "", arch); gsub(/^[ \t]+|[ \t]+$/, "", model); gsub(/^[ \t]+|[ \t]+$/, "", cpus);
#                  gsub(/^[ \t]+|[ \t]+$/, "", cores); gsub(/^[ \t]+|[ \t]+$/, "", sockets); gsub(/^[ \t]+|[ \t]+$/, "", maxmhz);
#                  printf("{\"architecture\":\"%s\",\"model\":\"%s\",\"cpus\":\"%s\",\"cores_per_socket\":\"%s\",\"sockets\":\"%s\",\"max_mhz\":\"%s\"}", arch, model, cpus, cores, sockets, maxmhz)}'
#         )
#     else
#         warn "lscpu missing – limited CPU info."
#         cpu_json='{}'
#     fi
#
#     echo "$cpu_json" | jq
# }

# =====================================================================
#   SECTION 3: RAM
# =====================================================================
fetch_ram_info() {
    header "3. RAM Information"
    separator

    local total="0 MB"
    local maxcap="Unknown"
    local ram_type="Unknown"
    ram_devices_json="[]"

    if has dmidecode; then
        # Total installed RAM
        total=$($SUDO dmidecode -t memory | awk -F: '/Size:/ && $2 ~ /[0-9]/ {print $2}' \
                | awk '/MB/ {sum+=$1} /GB/ {sum+=($1*1024)} END {print sum " MB"}')

        # Maximum supported RAM
        maxcap=$($SUDO dmidecode -t memory | awk -F: '/Maximum Capacity/ {print $2}' | xargs)

        # Read each Memory Device block
        IFS=$'\n' read -d '' -r -a blocks < <($SUDO dmidecode -t memory | awk '/Memory Device$/,/^$/ {print}' | sed '/^$/d')

        current_block=""
        for line in "${blocks[@]}"; do
            if [[ $line == "Memory Device"* ]]; then
                # Process previous block
                if [[ -n "$current_block" ]]; then
                    parse_dimm_block "$current_block"
                fi
                current_block="$line"$'\n'
            else
                current_block+="$line"$'\n'
            fi
        done
        # Process last block
        parse_dimm_block "$current_block"

        # Determine dominant RAM type
        ram_type=$(echo "$ram_devices_json" | jq -r '[.[] | .Type] | map(select(. != "")) | group_by(.) | map({type: .[0], count: length}) | max_by(.count) | .type // "Unknown"')
    else
        warn "dmidecode missing – RAM info limited."
    fi

    # Human-readable summary table
    printf "\nTotal System RAM:       %s\n" "$total"
    printf "Maximum Supported RAM:  %s\n" "$maxcap"
    printf "System RAM Type:        %s\n\n" "$ram_type"

    # Table header
    printf "%-8s | %-6s | %-8s | %-12s | %-12s\n" "Size" "Type" "Speed" "Manufacturer" "Serial"
    printf "%s\n" "--------------------------------------------------------------------------------"

    # Table rows
    echo "$ram_devices_json" | jq -r '.[] | [.Size, .Type, .Speed, .Manufacturer, .Serial] | @tsv' \
        | while IFS=$'\t' read -r size type speed manufacturer serial; do
            printf "%-8s | %-6s | %-8s | %-12s | %-12s\n" "$size" "$type" "$speed" "$manufacturer" "$serial"
        done

    # JSON summary
    ram_json=$(jq -n --arg total "$total" --arg maxcap "$maxcap" --arg type "$ram_type" \
        --argjson dimms "$ram_devices_json" \
        '{ total: $total, max_supported: $maxcap, type: $type, dimms: $dimms }')
}

# Helper function remains the same
parse_dimm_block() {
    local block="$1"
    local size type speed manufacturer serial

    size=$(echo "$block" | awk -F: '/Size/ {print $2}' | xargs)
    [[ "$size" == "No Module Installed" || -z "$size" ]] && return

    type=$(echo "$block" | awk -F: '/Type/ && $2 !~ /Unknown/ {print $2}' | xargs)
    speed=$(echo "$block" | awk -F: '/Speed/ {print $2}' | xargs)
    manufacturer=$(echo "$block" | awk -F: '/Manufacturer/ {print $2}' | xargs)
    serial=$(echo "$block" | awk -F: '/Serial Number/ {print $2}' | xargs)

    # Append to JSON array
    ram_devices_json=$(echo "$ram_devices_json" | jq --arg size "$size" --arg type "$type" \
        --arg speed "$speed" --arg manufacturer "$manufacturer" --arg serial "$serial" \
        '. += [{Size: $size, Type: $type, Speed: $speed, Manufacturer: $manufacturer, Serial: $serial}]')
}
# fetch_ram_info() {
#     header "3. RAM Information"
#     separator
#
#     local total="0 MB" maxcap="Unknown"
#     if has dmidecode; then
#         maxcap=$($SUDO dmidecode -t memory | awk -F: '/Maximum Capacity/ {print $2}' | xargs)
#         total=$($SUDO dmidecode -t memory | awk -F: '/Size:/ && $2 ~ /[0-9]/ {print $2}' | awk '/MB/{sum+=$1}/GB/{sum+=($1*1024)}END{print sum " MB"}')
#     fi
#
#     echo "Total System RAM: $total"
#     echo "Maximum Supported RAM: $maxcap"
#
#     ram_json=$(jq -n --arg total "$total" --arg maxcap "$maxcap" '{ total: $total, max_supported: $maxcap }')
#
#     # DIMM details
#     ram_devices_json="[]"
#     if has dmidecode; then
#         while IFS= read -r block; do
#             [[ -z "$block" ]] && continue
#             dev_json=$(echo "$block" | jq -Rn '(input|split("\n")) as $lines | reduce $lines[] as $l ({}; if ($l|test(": ")) then ($l|split(": ")) as $kv | . + { ($kv[0]|gsub(" ";"_")): ($kv[1]) } else . end)')
#             ram_devices_json=$(echo "$ram_devices_json" | jq --argjson d "$dev_json" '. += [$d]')
#         done < <($SUDO dmidecode -t memory | awk '/Memory Device$/,/^$/' | sed '/^Memory Device$/d')
#     fi
# }

# =====================================================================
#   SECTION 4: DISKS
# =====================================================================
fetch_disk_info() {
    header "4. Disk Information"
    separator

    disks_json="[]"
    for disk in /dev/sd? /dev/hd? /dev/nvme*[0-9]n[0-9]*; do
        [ -b "$disk" ] || continue
        local model="" serial="" fw="" cap="" rpm="" info=""
        if has smartctl; then
            info=$($SUDO smartctl -i "$disk" 2>/dev/null || true)
            model=$(echo "$info" | awk -F: '/Device Model|Model Number/ {print $2}' | xargs)
            serial=$(echo "$info" | awk -F: '/Serial Number/ {print $2}' | xargs)
            fw=$(echo "$info" | awk -F: '/Firmware Version/ {print $2}' | xargs)
            cap=$(echo "$info" | awk -F: '/User Capacity/ {print $2}' | xargs)
            rpm=$(echo "$info" | awk -F: '/Rotation Rate/ {print $2}' | xargs)
        fi

        echo -e "${CYAN}$disk${NC}\n  Model: $model\n  Serial: $serial\n  FW: $fw\n  Size: $cap\n  RPM: $rpm"
        disks_json=$(echo "$disks_json" | jq --arg disk "$disk" --arg model "$model" --arg serial "$serial" --arg fw "$fw" --arg cap "$cap" --arg rpm "$rpm" '. += [{ disk: $disk, model: $model, serial: $serial, firmware: $fw, capacity: $cap, rotation_rate: $rpm }]')
    done
}

# =====================================================================
#   SECTION 5: RAID
# =====================================================================
fetch_raid_info() {
    header "5. RAID Information"
    separator

    local mdstat=""
    if [ -r /proc/mdstat ]; then
        mdstat=$(cat /proc/mdstat)
        echo "$mdstat"
    else
        warn "Cannot read /proc/mdstat"
    fi

    raid_json=$(jq -n --arg md "$mdstat" '{ mdstat: $md }')
}

# =====================================================================
#   SECTION 6: PCI & GPU
# =====================================================================
fetch_pci_info() {
    header "6. PCI Devices"
    separator

    pci_json="[]"
    if has lspci; then
        while IFS= read -r line; do
            echo "$line"
            pci_json=$(echo "$pci_json" | jq --arg l "$line" '. += [$l]')
        done < <(lspci)
    fi
}

fetch_gpu_info() {
    header "6.1. GPU Information"
    separator

    gpu_json="[]"
    if has nvidia-smi; then
        while IFS= read -r line; do
            model=$(echo "$line" | awk -F',' '{print $1}' | xargs)
            serial=$(echo "$line" | awk -F',' '{print $2}' | xargs)
            pci=$(echo "$line" | awk -F',' '{print $3}' | xargs)
            echo -e "GPU Model: $model\nPCI ID: $pci\nSerial: $serial"
            gpu_json=$(echo "$gpu_json" | jq --arg model "$model" --arg pci "$pci" --arg serial "$serial" '. += [{model: $model, pci: $pci, serial: $serial}]')
        done < <(nvidia-smi --query-gpu=name,uuid,pci.bus_id --format=csv,noheader,nounits)
    else
        while IFS= read -r line; do
            pci=$(echo "$line" | awk '{print $1}')
            model=$(echo "$line" | cut -d' ' -f2-)
            echo -e "GPU Model: $model\nPCI ID: $pci"
	    warn "Since 'nvidia-smi' is not detected we cannot provide serial ID."
            gpu_json=$(echo "$gpu_json" | jq --arg model "$model" --arg pci "$pci" --arg serial "" '. += [{model: $model, pci: $pci, serial: $serial}]')
        done < <(lspci | grep -i VGA)
    fi
}

# =====================================================================
#   SECTION 7: NETWORK
# =====================================================================
fetch_network_info() {
    header "7. Network Interfaces"
    separator

    net_json="[]"
    if has ip; then
        while IFS= read -r line; do
            echo "$line"
            net_json=$(echo "$net_json" | jq --arg l "$line" '. += [$l]')
        done < <(ip -br a)
    fi
}

# =====================================================================
#   RUNNING SEQUENCE
# =====================================================================
if [[ $VALIDATE_MODE -eq 1 ]]; then
    validate
    exit 0
fi

check_tools
fetch_system_info
fetch_cpu_info
fetch_ram_info
fetch_disk_info
fetch_raid_info
fetch_pci_info
fetch_gpu_info
fetch_network_info

# =====================================================================
#   JSON OUTPUT
# =====================================================================
canonical_json=$(jq -n \
    --argjson sys "$system_info_json" \
    --argjson cpu "$cpu_json" \
    --argjson ram "$ram_json" \
    --argjson dimms "$ram_devices_json" \
    --argjson disks "$disks_json" \
    --argjson raid "$raid_json" \
    --argjson pci "$pci_json" \
    --argjson gpus "$gpu_json" \
    --argjson net "$net_json" \
    '{
        system: $sys,
        cpu: $cpu,
        ram: { summary: $ram, dimms: $dimms },
        storage: { disks: $disks, raid: $raid },
        pci: $pci,
        gpus: $gpus,
        network: { interfaces: $net }
    }'
)

if [[ $JSON_MODE -eq 1 ]]; then
    echo "$canonical_json"
elif [[ $JSON_TREE_MODE -eq 1 ]]; then
    echo "$canonical_json" | jq '{ hardware: { system: .system, cpu: .cpu, memory: .ram, storage: .storage, pci: .pci }, network: .network }'
else
    log "\nScript completed successfully."
fi
