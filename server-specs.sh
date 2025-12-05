#!/bin/bash

# Server Specs Fetcher
# Fetches detailed hardware specifications of the server

# --- Configuration & Logging ---

# Color definitions
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
MAGENTA='\033[35m'
CYAN='\033[36m'
NC='\033[0m' # No Color

# Logging functions
log() { echo -e "${GREEN}$1${NC}"; }
warn() { echo -e "${YELLOW}Warning: $1${NC}" >&2; }
error() {
	echo -e "${RED}Error: $1${NC}" >&2
	exit 1
}
info() { echo -e "${CYAN}$1${NC}"; }
header() { echo -e "\n${BLUE}$1${NC}"; }
separator() { echo -e "${BLUE}-----------------------------------${NC}"; }

# Check for required tools
check_tool() {
	if ! command -v "$1" >/dev/null 2>&1; then
		warn "$1 not found. Some information may be missing."
		return 1
	fi
	return 0
}

# Enhanced lscpu data extraction
get_lscpu_val() {
	# $1: The key to search for (e.g., 'Model name')
	# $2: The cached lscpu output
	echo "$2" | awk -F: -v key="$1" '$1 ~ key { gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit }'
}

# Check for SUDO access early for a cleaner run
SUDO_CMD="sudo"
if ! $SUDO_CMD -v 2>/dev/null; then
	warn "SUDO access for privileged commands (dmidecode, smartctl, lshw, fdisk) is not pre-cached."
	warn "You may be prompted for your password multiple times."
fi

# --- Fetching Functions ---

fetch_cpu_info() {
	header "1. CPU Information"
	separator
	if check_tool lscpu; then
		# Cache lscpu output for efficiency
		local lscpu_output lscpu_output
		lscpu_output=$(lscpu)

		echo "Brand/Model: $(get_lscpu_val 'Model name' "$lscpu_output")"
		echo "Architecture: $(get_lscpu_val 'Architecture' "$lscpu_output")"
		echo "CPU(s): $(get_lscpu_val '^CPU(s)' "$lscpu_output")"
		echo "Core(s) per socket: $(get_lscpu_val 'Core(s) per socket' "$lscpu_output")"
		echo "Socket(s): $(get_lscpu_val 'Socket(s)' "$lscpu_output")"
		echo "CPU max MHz: $(get_lscpu_val 'CPU max MHz' "$lscpu_output")"

		if check_tool dmidecode; then
			log "\nDetailed CPU (dmidecode):"
			$SUDO_CMD dmidecode -t processor | awk '
            /Processor Information/ { print "\n" $0 }
            /Manufacturer|Family|Version|Core Count|Thread Count|Max Speed/ { gsub(/^[ \t]+/, ""); print }' | head -n 30
		fi
	fi
}

fetch_ram_info() {
    header "2. RAM Information"
    separator
    if check_tool dmidecode; then
        log "Memory Devices (dmidecode):"
        $SUDO_CMD dmidecode -t memory | awk '
        /Memory Device/ { print "\n" $0 }
        /Manufacturer|Part Number|Size|Speed|Type|Locator/ { gsub(/^[ \t]+/, ""); print }' | sed '/^\s*$/d'
	fi
}

fetch_disk_info() {
	header "3. Disk/Storage Information"
	separator
	if check_tool lsblk; then
		log "Block Devices (lsblk):"
		lsblk -o NAME,SIZE,TYPE,RO,MOUNTPOINT,MODEL -e7 # Exclude loop devices
	fi

	if check_tool smartctl; then
		log "\nSMART info for major disks:"
		# Target common disk patterns, handle different names
		for disk in /dev/sd[a-z] /dev/hd[a-z] /dev/nvme[0-9]n[0-9]; do
			if [ -b "$disk" ]; then
				info "--- Disk: $disk ---"
				# Use a specific grep to reduce noise
				$SUDO_CMD smartctl -i "$disk" | grep -E "(Model Family|Device Model|Serial Number|Firmware Version|User Capacity|Rotation Rate)" | awk -F: '{ gsub(/^[ \t]+/, ""); print $0 }'
			fi
		done
	fi
}

fetch_raid_info() {
	header "4. RAID Information"
	separator
	local found_raid=0

	# --- 4.1. Software RAID (mdadm) ---
	if [ -f /proc/mdstat ]; then
		log "Software RAID (mdadm) Status (from /proc/mdstat):"
		cat /proc/mdstat
		# Check if there are active arrays beyond 'unused'
		if grep -q '^md[0-9]' /proc/mdstat; then
			found_raid=1
			log "\nDetailed mdadm information for active arrays:"
			# Loop through all md devices found in /proc/mdstat
			for array in $(grep '^md[0-9]' /proc/mdstat | awk '{print $1}'); do
				info "--- Array: /dev/$array ---"
				# Use --detail for in-depth status
				if check_tool mdadm; then
					$SUDO_CMD mdadm --detail /dev/"$array" 2>/dev/null
				else
					warn "mdadm utility not found. Cannot get detailed array status."
				fi
			done
		fi
	fi

	# --- 4.2. Hardware RAID (Vendor Specific Tools) ---
	log "\nHardware RAID Controller Check:"

	# Common Hardware RAID utilities to check
	local raid_tools=(megacli storcli hpssacli hpacucli perccli arcconf)
	local tool_found=0

	for tool in "${raid_tools[@]}"; do
		if command -v "$tool" >/dev/null 2>&1 || command -v "$(echo "$tool" | tr '[:lower:]' '[:upper:]')" >/dev/null 2>&1; then
			info "$tool utility found. Attempting RAID configuration display."
			found_raid=1
			tool_found=1
			# Note: Specific command flags vary wildly by tool/version.
			# Using common, generic flags for a best-effort attempt.
			case "$tool" in
			megacli)
				# MegaCli needs the binary path, often not in PATH
				warn "MegaCli path is often environment dependent (e.g. /opt/MegaRAID/MegaCli/MegaCli64)."
				warn "Manual execution may be required."
				;;
			storcli)
				$SUDO_CMD storcli /cALL show all 2>/dev/null
				;;
			hpssacli | hpacucli)
				$SUDO_CMD "${tool}" ctrl all show config 2>/dev/null
				;;
			perccli)
				$SUDO_CMD perccli /cALL show all 2>/dev/null
				;;
			arcconf)
				$SUDO_CMD arcconf GETCONFIG 1 LD 2>/dev/null
				;;
			*)
				# Should not happen
				;;
			esac
			break # Stop after finding the first one
		fi
	done

	if [ "$found_raid" -eq 0 ]; then
		info "No active Software RAID arrays found and no common Hardware RAID utilities (mdadm, MegaCli, StorCLI, hpssacli, etc.) were found."
		info "Check PCI devices for controller model if you suspect Hardware RAID."
	fi
}

fetch_pci_info() {
	header "4. PCI Devices (GPU, NIC, RAID)"
	separator
	if check_tool lspci; then
		log "Graphics/Display Controllers (VGA):"
		lspci | grep -i 'vga\|display\|3d'

		log "\nNetwork/Ethernet Controllers (NICs):"
		lspci | grep -i 'ethernet\|network'

		log "\nRAID/Storage Controllers:"
		lspci | grep -i 'raid\|sata\|scsi'
	fi

	if check_tool lshw; then
		log "\nDetailed NIC/Display Info (lshw):"
		$SUDO_CMD lshw -class network -class display -short 2>/dev/null
	fi
}

fetch_network_info() {
	header "5. Live Network Interface Status"
	separator
	if check_tool ip; then
		log "Interface Details (ip addr):"
		# Display all interfaces, including state, MAC, and IP
		ip -br a
	fi
}

# --- Main Execution ---

info "==================================="
info " Server Hardware Specs Report"
info "==================================="

fetch_cpu_info
fetch_ram_info
fetch_disk_info
fetch_raid_info
fetch_pci_info
fetch_network_info

log "\nScript completed successfully."
