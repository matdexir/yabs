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


# =====================================================================
#   SECTION 3: RAM
# =====================================================================

# Helper function to extract a single, cleaned value from a block of text
extract_dmi_value() {
	local block="$1"
	local field_name="$2"
	local raw_value

	# 1. Isolate the specific line (case-insensitive grep)
	# 2. Use awk to isolate the part *after* the first colon, strip leading/trailing whitespace
	raw_value=$(echo "$block" | grep -i "$field_name:" | head -n 1 | awk -F':' '{print $2}' | xargs)

	# 3. Handle empty slots early
	if [[ "$field_name" == "Size" ]] && [[ "$raw_value" == "No Module Installed" ]]; then
		echo ""
		return
	fi

	# 4. Remove common noise strings for cleaner parsing later
	# Note: We keep the value here, units will be added back later if needed
	echo "$raw_value" | sed 's/ MT\/s//' | sed 's/ Synchronous//' | xargs
}

fetch_ram_info() {
	header "3. RAM Information"
	separator

	local total="Unknown"
	local maxcap="Unknown"
	# Declared as local to prevent contamination
	local ram_type=""
	ram_devices_json="[]"

	if ! has dmidecode; then
		warn "dmidecode missing – RAM info limited."
		return
	fi

	# --- 1. Fetch Summary Info (Max Capacity, Total Installed RAM) ---
	local dmi_memory_info=$($SUDO dmidecode -t memory 2>/dev/null || true)
	maxcap=$(echo "$dmi_memory_info" | awk -F: '/Maximum Capacity/ {print $2}' | xargs)

	# Calculate Total Installed RAM (Reliable MB sum)
	total=$(echo "$dmi_memory_info" | awk -F: '/Size:/ && $2 ~ /[0-9]/ {print $2}' |
		awk '/MB/ {sum+=$1} /GB/ {sum+=($1*1024)} END {print sum " MB"}')

	# Convert total RAM to human-readable GB/MB format
	if has numfmt && [[ "$total" =~ MB ]]; then
		# Convert MB to human-readable units
		local temp_total=$(echo "$total" | numfmt --from-unit=M --to=iec-i --format="%0.0f %s" 2>/dev/null || echo "$total")
		# Fix units to MB/GB (replace MiB/GiB with MB/GB)
		total=$(echo "$temp_total" | sed 's/MiB/MB/' | sed 's/GiB/GB/' | xargs)
	else
		# fallback formatting
		total=$(echo "$total" | sed 's/MB/ MB/' | xargs)
	fi

	# --- 2. Iterate and Parse Individual DIMM Blocks (Type 17) ---
	local raw_blocks
	raw_blocks=$($SUDO dmidecode -t 17 2>/dev/null | sed -n '/Memory Device$/ {s/.*/***/; p;}; /Memory Device$/! p' | tr -d '\r')

	IFS='*' # Change the internal field separator to the delimiter
	for block in $raw_blocks; do
		[[ -z "$block" ]] && continue

		# Use the strict helper function for each field
		local size_raw=$(extract_dmi_value "$block" "Size")
		[[ -z "$size_raw" ]] && continue # Skip if empty slot (helper returns "")

		local type=$(extract_dmi_value "$block" "Type")
		local speed=$(extract_dmi_value "$block" "Speed")
		local manufacturer=$(extract_dmi_value "$block" "Manufacturer")
		local serial=$(extract_dmi_value "$block" "Serial Number")

		# Determine the unit and value (M for MB, G for GB)
		local size_value=""
		local size_unit=""

		if [[ "$size_raw" =~ MB ]]; then
			size_value=$(echo "$size_raw" | sed 's/MB//' | xargs)
			size_unit="MB"
		elif [[ "$size_raw" =~ GB ]]; then
			size_value=$(echo "$size_raw" | sed 's/GB//' | xargs)
			size_unit="GB"
		else
			size_value="$size_raw" # Use raw if no unit found
		fi

		local final_size="$size_raw"
		# Convert size unit if numfmt is available
		if has numfmt && [[ "$size_unit" == "MB" ]]; then
			# Convert MB value to GB/MB human format
			final_size=$(echo "$size_value" | numfmt --from-unit=M --to-unit=G --to-unit=iec-i --format="%0.0f %s" 2>/dev/null || echo "$size_value MB")
			final_size=$(echo "$final_size" | sed 's/\([0-9]\+\) M/\1 MB/' | sed 's/\([0-9]\+\) G/\1 GB/' | xargs)
		elif [[ "$size_unit" == "GB" ]]; then
			final_size="$size_value GB"
		fi

		# Build JSON array
		ram_devices_json=$(echo "$ram_devices_json" | jq -c \
			--arg size "$final_size" --arg type "$type" \
			--arg speed "$speed" --arg manufacturer "$manufacturer" --arg serial "$serial" \
			'. += [{Size: $size, Type: $type, Speed: $speed, Manufacturer: $manufacturer, Serial: $serial}]')
	done
	IFS=$' \t\n' # Restore IFS

	# --- 3. Determine dominant RAM Type (Variable protection fix) ---
	local determined_type=$(echo "$ram_devices_json" | jq -r '
	    map(.Type) |                     # Collect all Type fields into an array
	    map(select(. != "")) |           # Remove empty types
	    group_by(.) |                    # Group by type
	    map({type: .[0], count: length}) |
	    max_by(.count)? |                # Pick the most common type safely
	    .type // "Unknown"')

	ram_type=$(echo "$determined_type" | xargs)

	# Human-readable summary table
	printf "\nTotal System RAM:         %s\n" "$total"
	printf "Maximum Supported RAM:    %s\n" "$maxcap"
	printf "System RAM Type:          %s\n\n" "$ram_type"

	# Table header
	printf "%-8s | %-6s | %-8s | %-12s | %-12s\n" "Size" "Type" "Speed" "Manufacturer" "Serial"
	printf "%s\n" "--------------------------------------------------------------------------------"

	# Table rows
	echo "$ram_devices_json" | jq -r '.[] | [.Size, .Type, .Speed, .Manufacturer, .Serial] | @tsv' |
		while IFS=$'\t' read -r size type speed manufacturer serial; do
			printf "%-8s | %-6s | %-8s | %-12s | %-12s\n" "$size" "$type" "$speed" "$manufacturer" "$serial"
		done

	# JSON summary
	ram_json=$(jq -n \
		--arg total "$total" --arg maxcap "$maxcap" --arg type "$ram_type" \
		--argjson dimms "$ram_devices_json" \
		'{ total: $total, max_supported: $maxcap, type: $type, dimms: $dimms }')
}

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
    header "7. Network / DPU Information"
    separator

    net_devices_json="[]"

    # All PCI Network/Ethernet controllers
    local pci_list=$(lspci -D | grep -Ei 'Ethernet|Network')

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local pci_addr=$(echo "$line" | awk '{print $1}')
        local description=$(echo "$line" | cut -d ' ' -f2-)
        local vendor=$(echo "$line" | cut -d ':' -f3- | xargs)

        local dev_path="/sys/bus/pci/devices/${pci_addr}"

        # ----- Driver Detection -----
        local driver="Unknown"
        if [[ -L "$dev_path/driver" ]]; then
            driver=$(basename "$(readlink -f "$dev_path/driver")")
        fi

        # ----- Version Detection -----
        local driver_version="Unknown"
        if [[ -f "/sys/module/$driver/version" ]]; then
            driver_version=$(cat "/sys/module/$driver/version" 2>/dev/null)
        fi

        # ----- lspci provides revision -----
        local revision=$(lspci -D -vvv -s "$pci_addr" 2>/dev/null | awk '/Rev:/ {print $2}' | xargs)
        [[ -z "$revision" ]] && revision="Unknown"

        # ----- Determine Device Type (NIC or DPU) -----
        local dev_type="NIC"
        if [[ "$vendor" =~ Mellanox|NVIDIA|BlueField|Pensando|IPU|DPU ]]; then
            dev_type="DPU"
        fi
        if [[ -f "$dev_path/class" ]] && ! grep -q "020000" "$dev_path/class"; then
            dev_type="DPU"
        fi

        # ----- Interface collection -----
        local iface_json="[]"
        local interfaces=()
        if [[ -d "$dev_path/net" ]]; then
            interfaces=($(ls "$dev_path/net"))
        fi

        for iface in "${interfaces[@]}"; do
            local mac=$(cat "/sys/class/net/$iface/address")
            local speed="Unknown"
            local fw_version="Unknown"

            # NIC/DPU firmware from ethtool
            if has ethtool; then
                speed=$(ethtool "$iface" 2>/dev/null | awk -F: '/Speed/ {gsub(/ /,"",$2); print $2}')
                fw_version=$(ethtool -i "$iface" 2>/dev/null | awk -F: '/firmware-version/ {print $2}' | xargs)
            fi

            # BlueField / Mellanox exposes additional FW version in sysfs
            if [[ -f "$dev_path/firmware_version" ]]; then
                fw_version=$(cat "$dev_path/firmware_version" 2>/dev/null)
            fi
            if [[ "$fw_version" == "" ]]; then
                [[ -f "$dev_path/fw_version" ]] && fw_version=$(cat "$dev_path/fw_version" 2>/dev/null)
            fi

            iface_json=$(echo "$iface_json" | jq -c \
                --arg iface "$iface" \
                --arg mac "$mac" \
                --arg speed "$speed" \
                --arg fw "$fw_version" \
                '. += [{Interface: $iface, MAC: $mac, Speed: $speed, Firmware: $fw}]')
        done

        # ----- Add main PCI device entry -----
        net_devices_json=$(echo "$net_devices_json" | jq -c \
            --arg pci "$pci_addr" \
            --arg vendor "$vendor" \
            --arg desc "$description" \
            --arg driver "$driver" \
            --arg dver "$driver_version" \
            --arg rev "$revision" \
            --arg type "$dev_type" \
            --argjson ifaces "$iface_json" \
            '. += [{
                PCI: $pci,
                Vendor: $vendor,
                Brand: $desc,
                Driver: $driver,
                DriverVersion: $dver,
                Revision: $rev,
                Type: $type,
                Interfaces: $ifaces
            }]')
    done <<< "$pci_list"

    # ----- Output Table -----
    printf "%-14s | %-6s | %-10s | %-12s | %-40s | %-40s | %-30s\n" \
        "PCI Address" "Type" "Driver" "Interface" "MAC Address" "Firmware" "Brand"
    printf "%s\n" "------------------------------------------------------------------------------------------------------------------------------------------------------------------------------"

    echo "$net_devices_json" | jq -r '
        .[] as $dev |
        ($dev.Interfaces[]? // {Interface:"-",MAC:"-",Firmware:"-"}) |
        [
            $dev.PCI,
            $dev.Type,
            $dev.Driver,
            .Interface,
            .MAC,
            .Firmware,
            $dev.Brand
        ] | @tsv' |
    while IFS=$'\t' read -r pci type driver iface mac fw brand; do
        printf "%-14s | %-6s | %-10s | %-12s | %-40s | %-40s | %-30s\n" \
            "$pci" "$type" "$driver" "$iface" "$mac" "$fw" "$brand"
    done

    # ----- Final JSON Output -----
    net_json=$(jq -n --argjson devices "$net_devices_json" '{network_devices: $devices}')
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
