#!/bin/bash
# ============================================================
#   UNIVERSAL HARDWARE INVENTORY TOOL
#   Human readable, JSON, JSON-tree modes
#   Portable across all major Linux distros
# ============================================================

export LANG=C
set -o pipefail

# ---------------------------
#   COLOR DEFINITIONS
# ---------------------------
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
NC='\033[0m' # No Color

header()  { echo -e "\n${BLUE}$1${NC}"; }
log()     { echo -e "${GREEN}$1${NC}"; }
warn()    { echo -e "${YELLOW}Warning:${NC} $1"; }
error()   { echo -e "${RED}Error:${NC} $1"; exit 1; }
separator(){ echo -e "${BLUE}-----------------------------------${NC}"; }

show_help() {
cat << EOF

Usage: $0 [OPTIONS]

Options:
  --json        Output hardware information in namespaced JSON format
  --json-tree   Output hardware information as hierarchical JSON tree
  -h, --help    Show this help menu and exit

EOF
exit 0
}

# ---------------------------
#   MODE SELECTION
# ---------------------------
JSON_MODE=0
JSON_TREE_MODE=0

case "$1" in
    --json) JSON_MODE=1 ;;
    --json-tree) JSON_TREE_MODE=1 ;;
    -h|--help) show_help ;;
esac

# ---------------------------
#   TOOL CHECKER
# ---------------------------
has() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------
#   GLOBALS
# ---------------------------
if [[ $EUID -eq 0 ]]; then
    SUDO=""
elif has sudo; then
    SUDO="sudo"
    $SUDO -n true 2>/dev/null || warn "sudo password may be required"
else
    SUDO=""
    warn "Not root and sudo not available — some information will be missing"
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
        warn "dmidecode missing – system info limited."
    fi

    echo -e "Vendor:        $vendor"
    echo -e "Product:       $product"
    echo -e "Serial:        $serial"
    echo -e "UUID:          $uuid"
    echo -e "BIOS Vendor:   $bios_vendor"
    echo -e "BIOS Version:  $bios_version"
    echo -e "BIOS Date:     $bios_date"

    system_info_json=$(jq -n \
        --arg vendor "$vendor" \
        --arg product "$product" \
        --arg serial "$serial" \
        --arg uuid "$uuid" \
        --arg bios_vendor "$bios_vendor" \
        --arg bios_version "$bios_version" \
        --arg bios_date "$bios_date" \
        '{ vendor: $vendor, product: $product, serial: $serial, uuid: $uuid,
           bios: { vendor: $bios_vendor, version: $bios_version, date: $bios_date } }')
}

# =====================================================================
#   SECTION 2: CPU
# =====================================================================
fetch_cpu_info() {
    header "2. CPU Information"
    separator

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

    echo "Model:           $model"
    echo "Architecture:    $arch"
    echo "CPU Count:       $cpus"
    echo "Cores / Socket:  $cores"
    echo "Sockets:         $sockets"
    echo "Max MHz:         $maxmhz"

    cpu_json=$(jq -n \
        --arg arch "$arch" --arg model "$model" --arg cpus "$cpus" \
        --arg cores "$cores" --arg sockets "$sockets" --arg maxmhz "$maxmhz" \
        '{ architecture: $arch, model: $model, cpus: $cpus, cores_per_socket: $cores,
           sockets: $sockets, max_mhz: $maxmhz }')
}

# =====================================================================
#   SECTION 3: RAM (DIMM fix + total/max fix)
# =====================================================================
fetch_ram_info() {
    header "3. RAM Information"
    separator

    local total="0 MB" maxcap="Unknown"

    if has dmidecode; then
        maxcap=$(
            $SUDO dmidecode -t memory |
            awk -F: '/Maximum Capacity/ {print $2}' | xargs
        )

        total=$(
            $SUDO dmidecode -t memory |
            awk -F: '/Size:/ && $2 ~ /[0-9]/ {print $2}' |
            awk '
                /MB/ {sum+=$1}
                /GB/ {sum+=($1*1024)}
                END {print sum " MB"}'
        )
    fi

    echo "Total System RAM:       $total"
    echo "Maximum Supported RAM:  $maxcap"
    echo ""

    ram_json=$(jq -n --arg total "$total" --arg maxcap "$maxcap" \
        '{ total: $total, max_supported: $maxcap }')

    # DIMM details (patched parser)
    ram_devices_json="[]"

    if has dmidecode; then
        while IFS= read -r block; do
            [[ -z "$block" ]] && continue

            dev_json=$(echo "$block" | jq -Rn '
                (input | split("\n")) as $lines |
                reduce $lines[] as $l ({}; 
                    if ($l|test(": ")) then
                      ($l|split(": ")) as $kv |
                      . + { ($kv[0] | gsub(" "; "_")): ($kv[1]) }
                    else . end
                )')

            ram_devices_json=$(echo "$ram_devices_json" | jq --argjson d "$dev_json" '. += [$d]')

        done < <($SUDO dmidecode -t memory | awk '/Memory Device$/,/^$/' | sed '/^Memory Device$/d')
    fi
}

# =====================================================================
#   SECTION 4: DISKS (NVMe fix + glob safety)
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

        echo -e "${CYAN}$disk${NC}"
        echo "  Model:  $model"
        echo "  Serial: $serial"
        echo "  FW:     $fw"
        echo "  Size:   $cap"
        echo "  RPM:    $rpm"

        disks_json=$(echo "$disks_json" | jq --arg disk "$disk" \
            --arg model "$model" --arg serial "$serial" \
            --arg fw "$fw" --arg cap "$cap" --arg rpm "$rpm" \
            '. += [{ disk: $disk, model: $model, serial: $serial, firmware: $fw,
                     capacity: $cap, rotation_rate: $rpm }]')
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
#   SECTION 6: PCI (subshell JSON fix)
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

# =====================================================================
#   SECTION 7: NETWORK (subshell JSON fix)
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
#   RUN EVERYTHING
# =====================================================================
fetch_system_info
fetch_cpu_info
fetch_ram_info
fetch_disk_info
fetch_raid_info
fetch_pci_info
fetch_network_info

# =====================================================================
#   JSON OUTPUT (Unified Internal Structure)
# =====================================================================

# Canonical master JSON object:
canonical_json=$(jq -n \
    --argjson sys "$system_info_json" \
    --argjson cpu "$cpu_json" \
    --argjson ram "$ram_json" \
    --argjson dimms "$ram_devices_json" \
    --argjson disks "$disks_json" \
    --argjson raid "$raid_json" \
    --argjson pci "$pci_json" \
    --argjson net "$net_json" \
    '{
        system: $sys,
        cpu: $cpu,
        ram: {
            summary: $ram,
            dimms: $dimms
        },
        storage: {
            disks: $disks,
            raid: $raid
        },
        pci: $pci,
        network: {
            interfaces: $net
        }
    }'
)

if [[ $JSON_MODE -eq 1 ]]; then
    # Output canonical object (namespaced CMDB style)
    echo "$canonical_json"
    exit 0
elif [[ $JSON_TREE_MODE -eq 1 ]]; then
    # Render hierarchical view using the canonical object
    final=$(echo "$canonical_json" | jq '
    {
        hardware: {
            system: .system,
            cpu: .cpu,
            memory: .ram,
            storage: .storage,
            pci: .pci
        },
        network: .network
    }')
    echo "$final"
    exit 0
fi

log "\nScript completed successfully."
