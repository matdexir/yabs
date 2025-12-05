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
  echo "$2" | awk -F: -v key="$1" '$1 ~ key { gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit }'
}

# Check sudo access
SUDO_CMD="sudo"
if ! $SUDO_CMD -v 2>/dev/null; then
  warn "SUDO access for privileged commands (dmidecode, smartctl, lshw, fdisk) is not pre-cached."
  warn "You may be prompted for your password multiple times."
fi

# --- Fetching Functions ---

fetch_system_info() {
  header "1. System & BIOS Information"
  separator

  if check_tool dmidecode; then
    log "Vendor and Product Details:"
    $SUDO_CMD dmidecode -t system | awk '
      /Manufacturer|Product Name|Serial Number|UUID/ { gsub(/^[ \t]+/, ""); print }'

    log "\nBIOS Information:"
    $SUDO_CMD dmidecode -t bios | awk '
      /Vendor|Version|Release Date/ { gsub(/^[ \t]+/, ""); print }'
  fi
}

fetch_cpu_info() {
  header "2. CPU Information"
  separator

  if check_tool lscpu; then
    local lscpu_output
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
        /Manufacturer|Family|Version|Core Count|Thread Count|Max Speed/ {
          gsub(/^[ \t]+/, ""); print
        }' | head -n 30
    fi
  fi
}

fetch_ram_info() {
  header "3. RAM Information"
  separator

  if check_tool lshw; then
    log "Total System Memory Summary (lshw):"
    $SUDO_CMD lshw -class memory | awk '
      /size:|capacity:/ { print "Total System Size: " $2 $3 }
      /slot:/ || /size:/ || /speed:/ || /manufacturer:/ || /part number:/ {
        gsub(/^[ \t]+/, ""); print
      }' | head -n 30
  else
    if check_tool free; then
      log "\nTotal System Memory (free):"
      free -h | awk '/^Mem:/ { print "Total RAM: " $2 " (use dmidecode for details)" }'
    fi
  fi

  if check_tool dmidecode; then
    log "\nDetailed Memory Devices (dmidecode):"
    $SUDO_CMD dmidecode -t memory | awk '
      /Memory Device/ { print "\n" $0 }
      /Manufacturer|Part Number|Size|Speed|Type|Locator/ {
        gsub(/^[ \t]+/, ""); print
      }' | sed '/^\s*$/d'
  fi
}

fetch_disk_info() {
  header "4. Disk/Storage Information"
  separator

  if check_tool lsblk; then
    log "Block Devices (lsblk):"
    lsblk -o NAME,SIZE,TYPE,RO,MOUNTPOINT,MODEL -e7
  fi

  if check_tool smartctl; then
    log "\nSMART info for major disks:"
    for disk in /dev/sd? /dev/hd? /dev/nvme?n?; do
      if [ -b "$disk" ]; then
        info "--- Disk: $disk ---"
        $SUDO_CMD smartctl -i "$disk" | \
          grep -E "(Model Family|Device Model|Serial Number|Firmware Version|User Capacity|Rotation Rate)" | \
          awk -F: '{ gsub(/^[ \t]+/, ""); print }'
      fi
    done
  fi
}

fetch_raid_info() {
  header "5. RAID Information"
  separator

  local found_raid=0

  if [ -f /proc/mdstat ]; then
    log "Software RAID (mdadm) Status (from /proc/mdstat):"
    cat /proc/mdstat

    if grep -q '^md[0-9]' /proc/mdstat; then
      found_raid=1
      log "\nDetailed mdadm information for active arrays:"

      for array in $(grep '^md[0-9]' /proc/mdstat | awk '{print $1}'); do
        info "--- Array: /dev/$array ---"
        if check_tool mdadm; then
          $SUDO_CMD mdadm --detail /dev/"$array" 2>/dev/null
        else
          warn "mdadm utility not found."
        fi
      done
    fi
  fi

  log "\nHardware RAID Controller Check:"
  local raid_tools=(megacli storcli hpssacli hpacucli perccli arcconf)

  for tool in "${raid_tools[@]}"; do
    if command -v "$tool" >/dev/null 2>&1; then
      info "$tool found. Attempting RAID configuration display."
      found_raid=1

      case "$tool" in
        storcli) $SUDO_CMD storcli /cALL show all ;;
        hpssacli|hpacucli) $SUDO_CMD "$tool" ctrl all show config ;;
        perccli) $SUDO_CMD perccli /cALL show all ;;
        arcconf) $SUDO_CMD arcconf GETCONFIG 1 LD ;;
        megacli)
          warn "MegaCli often installed in /opt/MegaRAID/... — run manually if needed."
          ;;
      esac
      break
    fi
  done

  if [ "$found_raid" -eq 0 ]; then
    info "No RAID detected (software or typical hardware utilities)."
  fi
}

fetch_pci_info() {
  header "6. PCI Devices (GPU, NIC, RAID)"
  separator

  if check_tool lspci; then
    log "Graphics/Display Controllers:"
    lspci | grep -iE 'vga|display|3d'

    log "\nNetwork Controllers:"
    lspci | grep -iE 'ethernet|network'

    log "\nRAID/Storage Controllers:"
    lspci | grep -iE 'raid|sata|scsi'
  fi

  if check_tool lshw; then
    log "\nDetailed NIC/Display Info (lshw):"
    $SUDO_CMD lshw -class network -class display -short 2>/dev/null
  fi
}

fetch_network_info() {
  header "7. Live Network Interface Status"
  separator

  if check_tool ip; then
    log "Interface Details (ip addr):"
    ip -br a
  fi
}

# --- Main Execution ---

info "==================================="
info " Server Hardware Specs Report"
info "==================================="

fetch_system_info
fetch_cpu_info
fetch_ram_info
fetch_disk_info
fetch_raid_info
fetch_pci_info
fetch_network_info

log "\nScript completed successfully."
