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
other_pci_json="[]"
gpu_json="[]"
interconnect_json="{}"

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

    cat << EOF
Model:           $model
Architecture:    $arch
CPU Count:       $cpus
Cores / Socket:  $cores
Sockets:         $sockets
Max MHz:         $maxmhz
EOF

    cpu_json=$(jq -n \
        --arg arch "$arch" \
        --arg model "$model" \
        --arg cpus "$cpus" \
        --arg cores "$cores" \
        --arg sockets "$sockets" \
        --arg maxmhz "$maxmhz" \
        '{ architecture: $arch, model: $model, cpus: $cpus, cores_per_socket: $cores,
           sockets: $sockets, max_mhz: $maxmhz }')
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

    # --------------------------------------------
    # Helper: determine correct smartctl invocation
    # --------------------------------------------
    get_smart_info() {
        local disk="$1"

        # NVMe drives require nvme device type
        if [[ "$disk" == /dev/nvme* ]]; then
            $SUDO smartctl -i -d nvme "$disk" 2>/dev/null && return 0
        fi

        # USB-to-SATA adapters often need -d sat
        if udevadm info --query=all --name "$disk" 2>/dev/null | grep -q "ID_BUS=usb"; then
            $SUDO smartctl -i -d sat "$disk" 2>/dev/null && return 0
        fi

        # Default SATA/SAS
        $SUDO smartctl -i "$disk" 2>/dev/null && return 0

        return 1
    }

    # --------------------------------------------
    # Helper: check RAID membership
    # --------------------------------------------
    is_raid_member() {
        local disk="$1"
        # sysfs md directory
        if [ -d "/sys/block/$(basename "$disk")/md" ]; then
            echo "yes"
            return
        fi
        # udev property
        if udevadm info --query=all --name="$disk" 2>/dev/null | grep -q "linux_raid_member"; then
            echo "yes"
            return
        fi
        # mdadm superblock
        if sudo mdadm --examine "$disk" &>/dev/null; then
            echo "yes"
            return
        fi
        echo "no"
    }

    # --------------------------------------------
    # Enumerate *real block disks*, not partitions
    # --------------------------------------------
    for sysdev in /sys/block/*; do
        devname=$(basename "$sysdev")
        disk="/dev/$devname"

        # Accept only disk devices, no partitions
        case "$disk" in
            /dev/sd*|/dev/hd*|/dev/nvme*n*) ;;
            *) continue ;;
        esac

        # Skip loop devices
        [[ "$devname" == loop* ]] && continue

        local model="" serial="" fw="" cap="" rpm="" info="" smart_ok=false raid="no"

        # --------------------------------------------
        # SMART detection
        # --------------------------------------------
        if has smartctl; then
            if get_smart_info "$disk" &>/dev/null; then
                smart_ok=true
                info=$(get_smart_info "$disk")
            fi
        fi

        # --------------------------------------------
        # Parse info if SMART available
        # --------------------------------------------
        if [ "$smart_ok" = true ] && [ -n "$info" ]; then
            model=$(echo "$info" | awk -F: '/Device Model|Model Number/ {print $2}' | xargs)
            serial=$(echo "$info" | awk -F: '/Serial Number/ {print $2}' | xargs)
            fw=$(echo "$info" | awk -F: '/Firmware Version/ {print $2}' | xargs)

            # Capacity (multiple possible fields)
            cap=$(echo "$info" | awk -F: '/User Capacity/ {print $2}' | xargs)
            [ -z "$cap" ] && cap=$(echo "$info" | awk -F: '/Total NVM Capacity/ {print $2}' | xargs)
            [ -z "$cap" ] && cap=$(echo "$info" | awk -F: '/Namespace [0-9]+ Size/ {print $2}' | xargs)

            # Rotation Rate
            rpm=$(echo "$info" | awk -F: '/Rotation Rate/ {print $2}' | xargs)

            # Full SMART dump fallback for RPM
            info_full=$($SUDO smartctl -a "$disk" 2>/dev/null)
            [ -z "$rpm" ] && rpm=$(echo "$info_full" | awk -F: '/Rotation Rate/ {print $2}' | xargs)
        fi

        # --------------------------------------------
        # Fallbacks when SMART unsupported
        # --------------------------------------------
        if [ "$smart_ok" = false ] || [ -z "$model" ]; then
            model=$(udevadm info --query=property --name="$disk" 2>/dev/null | grep '^ID_MODEL=' | cut -d= -f2)
            serial=$(udevadm info --query=property --name="$disk" 2>/dev/null | grep '^ID_SERIAL=' | cut -d= -f2)
        fi

        # --------------------------------------------
        # Capacity fallback via blockdev
        # --------------------------------------------
        if [ -z "$cap" ] && has blockdev; then
            bytes=$(blockdev --getsize64 "$disk" 2>/dev/null)
            [ -n "$bytes" ] && cap="$(numfmt --to=iec --suffix=B "$bytes")"
        fi

        # --------------------------------------------
        # RPM / SSD detection fallback
        # --------------------------------------------
        if [ -z "$rpm" ]; then
            if [[ "$disk" == /dev/nvme* ]]; then
                rpm="SSD"
            else
                rotational=$(cat "/sys/block/$devname/queue/rotational" 2>/dev/null)
                if [ "$rotational" = "0" ]; then
                    rpm="SSD"
                elif [ "$rotational" = "1" ]; then
                    rpm="Unknown"
                fi
            fi
        fi

        # hdparm fallback for SATA RPM
        if [ "$rpm" = "Unknown" ] && has hdparm && [[ "$disk" == /dev/sd* ]]; then
            hdinfo=$(sudo hdparm -I "$disk" 2>/dev/null)
            rpm=$(echo "$hdinfo" | awk '/RPM/ {print $1}' | xargs)
        fi

        # --------------------------------------------
        # RAID detection
        # --------------------------------------------
        raid=$(is_raid_member "$disk")

        # --------------------------------------------
        # Pretty print output
        # --------------------------------------------
        echo -e "${CYAN}$disk${NC}"
        echo -e "  Model:  $model"
        echo -e "  Serial: $serial"
        echo -e "  FW:     $fw"
        echo -e "  Size:   $cap"
        echo -e "  RPM:    $rpm"
        echo -e "  RAID:   $raid"

        # --------------------------------------------
        # JSON append
        # --------------------------------------------
        disks_json=$(echo "$disks_json" | jq \
            --arg disk "$disk" \
            --arg model "$model" \
            --arg serial "$serial" \
            --arg fw "$fw" \
            --arg cap "$cap" \
            --arg rpm "$rpm" \
            --arg raid "$raid" \
            '. += [{
                disk: $disk,
                model: $model,
                serial: $serial,
                firmware: $fw,
                capacity: $cap,
                rotation_rate: $rpm,
                raid: $raid
            }]')
    done

    DISK_INFO_JSON="$disks_json"
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

fetch_other_pci_info(){
    header "6.2 Other PCI Devices"
    separator

    if has lspci; then
        local pcis=$(lspci | grep -vi 'vga\|3d\|2d')
        if [[ -n "$pcis" ]]; then
            printf "%-10s | %-50s\n" "Slot" "Description"
            printf "%s\n" "-------------------------------------------------------------"
            while read -r line; do
                local slot=$(echo "$line" | awk '{print $1}')
                local desc=$(echo "$line" | cut -d' ' -f2-)
                printf "%-10s | %-50s\n" "$slot" "$desc"
                other_pci_json=$(echo "$other_pci_json" | jq -c --arg slot "$slot" --arg desc "$desc" '. += [{slot: $slot, description: $desc}]')
            done <<< "$pcis"
        else
            echo "No other PCI devices detected."
        fi
    else
        warn "lspci missing – PCI info limited."
    fi
}

# =====================================================================
#   SECTION 7: HIGH-SPEED INTERCONNECTS
# =====================================================================
fetch_interconnect_info() {

    header "4. High-Speed Interconnects (NIC / DPU / InfiniBand / NVLink / NVSwitch)"
    separator

    local ic_json='{"ethernet":[],"infiniband":[],"nvswitch":[]}'

    #
    # =====================================================================
    # 1. ETHERNET & DPU DEVICES (PCI, lspci, ethtool)
    # =====================================================================
    #

    if command -v lspci >/dev/null 2>&1; then
        while IFS= read -r line; do
            local pci=$(echo "$line" | awk '{print $1}')
            local desc=$(echo "$line" | cut -d' ' -f2-)

            # Extract brand
            local brand=$(echo "$desc" | sed 's/.*: //')

            # Determine type (NIC vs DPU)
            local type="NIC"
            if echo "$desc" | grep -qiE "BlueField|SmartNIC|ConnectX.*DPU"; then
                type="DPU"
            fi

            # Find network interfaces under this PCI dev
            local netdir="/sys/bus/pci/devices/$pci/net"
            if [[ -d "$netdir" ]]; then
                for iface in "$netdir"/*; do
                    iface=$(basename "$iface")
                    local mac=$(cat "/sys/class/net/$iface/address" 2>/dev/null)
                    local driver=$(basename "$(readlink -f "/sys/class/net/$iface/device/driver")" 2>/dev/null)

                    local fw="Unknown"
                    if command -v ethtool >/dev/null 2>&1; then
                        fw=$(ethtool -i "$iface" 2>/dev/null | awk -F': ' '/firmware-version/ {print $2}')
                    fi

                    ic_json=$(echo "$ic_json" | jq \
                        --arg pci "$pci" \
                        --arg brand "$brand" \
                        --arg type "$type" \
                        --arg iface "$iface" \
                        --arg mac "$mac" \
                        --arg driver "$driver" \
                        --arg fw "$fw" \
                        '
                        .ethernet += [{
                            pci: $pci,
                            brand: $brand,
                            type: $type,
                            interface: $iface,
                            mac: $mac,
                            driver: $driver,
                            firmware: $fw
                        }]')
                done
            fi
        done <<< "$(lspci -Dvmm | awk '/^Slot:/ {printf "%s ",$2} /^Class:/ {printf "%s ",$2} /^Vendor:/ {printf "%s ",$2} /^Device:/ {print $2}')"
    else
        warn "lspci missing — cannot enumerate Ethernet."
    fi


    #
    # =====================================================================
    # 2. INFINIBAND HCAs (full port introspection)
    # =====================================================================
    #

    if [[ -d /sys/class/infiniband ]]; then
        for hca in /sys/class/infiniband/*; do
            local name=$(basename "$hca")

            local fw=$(cat "$hca/fw_ver" 2>/dev/null || echo "Unknown")
            local node=$(cat "$hca/node_desc" 2>/dev/null || echo "Unknown")
            local htype=$(cat "$hca/hca_type" 2>/dev/null || echo "Unknown")

            ic_json=$(echo "$ic_json" | jq --arg n "$name" --arg fw "$fw" --arg nd "$node" --arg ht "$htype" '
                .infiniband += [{
                    name: $n,
                    firmware: $fw,
                    node_desc: $nd,
                    hca_type: $ht,
                    ports: []
                }]')

            for port in "$hca/ports/"*; do
                [[ ! -d "$port" ]] && continue
                local pn=$(basename "$port")

                local state=$(awk '{print $2}' "$port/state" 2>/dev/null)
                local phys=$(awk '{print $2}' "$port/phys_state" 2>/dev/null)
                local rate=$(cat "$port/rate" 2>/dev/null)

                ic_json=$(echo "$ic_json" | jq \
                    --arg n "$name" --arg pn "$pn" \
                    --arg st "$state" --arg ps "$phys" --arg rt "$rate" '
                    .infiniband |=
                        map(if .name == $n then
                            .ports += [{
                                port: $pn,
                                state: $st,
                                phys_state: $ps,
                                rate: $rt
                            }]
                        else . end)
                ')
            done
        done
    else
        warn "No InfiniBand subsystem detected."
    fi


    #
    # =====================================================================
    # 3. NVLINK / NVSWITCH (driver-dependent, safe checks)
    # =====================================================================
    #

    if command -v nvidia-smi >/dev/null 2>&1; then

        #
        # ---- A. NVSwitch Support Detection
        #
        if nvidia-smi --help | grep -q "query-switch"; then

            local swinfo
            swinfo=$(nvidia-smi --query-switch=index,uuid,family,model,firmware_version --format=csv,noheader 2>/dev/null)

            while IFS=',' read -r idx uuid fam model fw; do
                idx=$(echo "$idx" | xargs)
                uuid=$(echo "$uuid" | xargs)
                fam=$(echo "$fam" | xargs)
                model=$(echo "$model" | xargs)
                fw=$(echo "$fw" | xargs)

                ic_json=$(echo "$ic_json" | jq \
                    --arg idx "$idx" --arg uuid "$uuid" --arg fam "$fam" \
                    --arg model "$model" --arg fw "$fw" '
                    .nvswitch += [{
                        index: $idx,
                        uuid: $uuid,
                        family: $fam,
                        model: $model,
                        firmware: $fw,
                        links: []
                    }]')
            done <<< "$swinfo"
        else
            warn "NVSwitch API not supported on this system."
        fi


        #
        # ---- B. NVLink Topology
        #
        if nvidia-smi nvlink --help >/dev/null 2>&1; then
            local ln
            ln=$(nvidia-smi nvlink --format=csv,noheader 2>/dev/null)

            while IFS=',' read -r sw gpu link bw state; do
                sw=$(echo "$sw" | xargs)
                gpu=$(echo "$gpu" | xargs)
                link=$(echo "$link" | xargs)
                bw=$(echo "$bw" | xargs)
                state=$(echo "$state" | xargs)

                ic_json=$(echo "$ic_json" | jq \
                    --arg sw "$sw" --arg gpu "$gpu" --arg link "$link" \
                    --arg bw "$bw" --arg st "$state" '
                    .nvswitch |=
                        map(if .index == $sw then
                            .links += [{
                                link: $link,
                                gpu: $gpu,
                                bandwidth: $bw,
                                state: $st
                            }]
                        else . end)
                ')
            done <<< "$ln"
        else
            warn "NVLink API unsupported on this driver."
        fi

    else
        warn "nvidia-smi not installed — skipping NVSwitch/NVLink."
    fi



    #
    # =====================================================================
    # 4. HUMAN-READABLE TABLE OUTPUT
    # =====================================================================
    #

    echo ""
    echo "=== Ethernet / DPU Devices ==="
    printf "%-12s | %-6s | %-12s | %-40s | %-20s | %-40s | %-35s\n" \
        "PCI" "Type" "Driver" "Interface" "MAC" "Firmware" "Brand"
    echo "------------------------------------------------------------------------------------------------------------------------------------------------------------------------"

    echo "$ic_json" | jq -r '.ethernet[] | [.pci,.type,.driver,.interface,.mac,.firmware,.brand] | @tsv' |
    while IFS=$'\t' read -r pci type drv iface mac fw brand; do
        printf "%-12s | %-6s | %-12s | %-40s | %-20s | %-40s | %-35s\n" \
            "$pci" "$type" "$drv" "$iface" "$mac" "$fw" "$brand"
    done


    echo ""
    echo "=== InfiniBand HCAs ==="
    printf "%-12s | %-20s | %-20s | %-50s\n" "Name" "Firmware" "Type" "Node Description"
    echo "------------------------------------------------------------------------------------------------------------------------------------------"

    echo "$ic_json" | jq -r '.infiniband[] | [.name,.firmware,.hca_type,.node_desc] | @tsv' |
    while IFS=$'\t' read -r n fw typ nd; do
        printf "%-12s | %-20s | %-20s | %-50s\n" "$n" "$fw" "$typ" "$nd"
    done


    echo ""
    echo "=== InfiniBand Ports ==="
    printf "%-10s | %-5s | %-12s | %-12s | %-15s\n" "HCA" "Port" "State" "PhysState" "Rate"
    echo "---------------------------------------------------------------------------"

    echo "$ic_json" | jq -r '
        .infiniband[] as $h |
        $h.ports[]? |
        [$h.name,.port,.state,.phys_state,.rate] | @tsv' |
    while IFS=$'\t' read -r h p st ps rt; do
        printf "%-10s | %-5s | %-12s | %-12s | %-15s\n" "$h" "$p" "$st" "$ps" "$rt"
    done


    echo ""
    echo "=== NVSwitch Devices ==="
    printf "%-5s | %-40s | %-20s | %-25s\n" "Idx" "UUID" "Firmware" "Model"
    echo "--------------------------------------------------------------------------------------------------"

    echo "$ic_json" | jq -r '.nvswitch[] | [.index,.uuid,.firmware,.model] | @tsv' |
    while IFS=$'\t' read -r idx uuid fw model; do
        printf "%-5s | %-40s | %-20s | %-25s\n" "$idx" "$uuid" "$fw" "$model"
    done


    echo ""
    echo "=== NVLink Links ==="
    printf "%-5s | %-5s | %-5s | %-12s | %-12s\n" "Sw" "Link" "GPU" "Bandwidth" "State"
    echo "-------------------------------------------------------------"

    echo "$ic_json" | jq -r '
        .nvswitch[] as $sw |
        $sw.links[]? |
        [$sw.index,.link,.gpu,.bandwidth,.state] | @tsv' |
    while IFS=$'\t' read -r sw lk gpu bw st; do
        printf "%-5s | %-5s | %-5s | %-12s | %-12s\n" "$sw" "$lk" "$gpu" "$bw" "$st"
    done


    #
    # =====================================================================
    # Export JSON
    # =====================================================================
    #
    interconnect_json="$ic_json"
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
fetch_gpu_info
fetch_other_pci_info

fetch_interconnect_info

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
    --argjson pci "$other_pci_json" \
    --argjson gpus "$gpu_json" \
    --argjson ic "$interconnect_json" \
    '{
        system: $sys,
        cpu: $cpu,
        ram: { summary: $ram, dimms: $dimms },
        storage: { disks: $disks, raid: $raid },
        pci: $pci,
        gpus: $gpus,
        interconnects: $ic
    }'
)

if [[ $JSON_MODE -eq 1 ]]; then
    echo "$canonical_json"
elif [[ $JSON_TREE_MODE -eq 1 ]]; then
    echo "$canonical_json" | jq '{ hardware: { system: .system, cpu: .cpu, memory: .ram, storage: .storage, pci: .pci }, interconnects: .interconnects }'
else
    log "\nScript completed successfully."
fi
