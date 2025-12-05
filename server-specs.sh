#!/bin/bash

# Server Specs Fetcher
# Fetches detailed hardware specifications of the server

# Color definitions
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
MAGENTA='\033[35m'
CYAN='\033[36m'
NC='\033[0m'  # No Color

# Logging functions
log() {
    echo -e "${GREEN}$1${NC}"
}

warn() {
    echo -e "${YELLOW}Warning: $1${NC}"
}

error() {
    echo -e "${RED}Error: $1${NC}"
}

info() {
    echo -e "${CYAN}$1${NC}"
}

header() {
    echo -e "${BLUE}$1${NC}"
}

info "Server Hardware Specifications"
info "=============================="

# Check for required tools
check_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        warn "$1 not found. Some information may be missing."
        return 1
    fi
    return 0
}

header "\n1. CPU Information:"
header "-------------------"
if check_tool lscpu; then
    echo "Brand/Model: $(lscpu | grep 'Model name' | sed 's/Model name: *//')"
    echo "Architecture: $(lscpu | grep 'Architecture' | sed 's/Architecture: *//')"
    echo "CPU(s): $(lscpu | grep '^CPU(s):' | sed 's/CPU(s): *//')"
    echo "Thread(s) per core: $(lscpu | grep 'Thread(s) per core' | sed 's/Thread(s) per core: *//')"
    echo "Core(s) per socket: $(lscpu | grep 'Core(s) per socket' | sed 's/Core(s) per socket: *//')"
    echo "Socket(s): $(lscpu | grep 'Socket(s)' | sed 's/Socket(s): *//')"
    echo "Vendor ID: $(lscpu | grep 'Vendor ID' | sed 's/Vendor ID: *//')"
    echo "CPU family: $(lscpu | grep 'CPU family' | sed 's/CPU family: *//')"
    echo "Model: $(lscpu | grep '^Model:' | sed 's/Model: *//')"
    echo "Stepping: $(lscpu | grep 'Stepping' | sed 's/Stepping: *//')"
    echo "CPU MHz: $(lscpu | grep 'CPU MHz' | sed 's/CPU MHz: *//')"
    echo "CPU max MHz: $(lscpu | grep 'CPU max MHz' | sed 's/CPU max MHz: *//')"
    echo "CPU min MHz: $(lscpu | grep 'CPU min MHz' | sed 's/CPU min MHz: *//')"
fi

if check_tool dmidecode; then
    log "\nDetailed CPU from dmidecode:"
    sudo dmidecode -t processor | grep -E "(Manufacturer|Family|Version|Frequency|Status)" | head -20
fi

header "\n2. RAM Information:"
header "-------------------"
if check_tool dmidecode; then
    sudo dmidecode -t memory | grep -A 10 "Memory Device" | grep -E "(Manufacturer|Part Number|Size|Speed|Type|Locator)" | sed 's/^[ \t]*//'
fi

if check_tool lshw; then
    log "\nRAM from lshw:"
    sudo lshw -class memory | grep -A 5 -B 5 "System Memory" | grep -E "(description|product|vendor|size|clock)"
fi

header "\n3. RAID Card Information:"
header "-------------------------"
if check_tool lspci; then
    log "RAID Controllers:"
    lspci | grep -i raid
fi

if check_tool dmidecode; then
    log "\nRAID from dmidecode:"
    sudo dmidecode | grep -A 10 -i raid
fi

header "\n4. Disk Information:"
header "--------------------"
if check_tool lsblk; then
    log "Disks:"
    lsblk -o NAME,SIZE,TYPE,MODEL,SERIAL | grep disk
fi

if check_tool fdisk; then
    log "\nPartition info:"
    sudo fdisk -l | grep -E "^Disk /"
fi

if check_tool smartctl; then
    log "\nSMART info for disks:"
    for disk in /dev/sd[a-z] /dev/nvme[0-9]; do
        if [ -b "$disk" ]; then
            info "Disk: $disk"
            sudo smartctl -i "$disk" | grep -E "(Model Family|Device Model|Serial Number|Firmware Version|User Capacity)"
        fi
    done
fi

if check_tool lshw; then
    log "\nDisk from lshw:"
    sudo lshw -class disk | grep -A 5 -E "(description|product|vendor|size|serial)"
fi

header "\n5. GPU Information:"
header "-------------------"
if check_tool lspci; then
    log "GPUs:"
    lspci | grep -i vga
fi

if check_tool lshw; then
    log "\nGPU from lshw:"
    sudo lshw -class display | grep -A 5 -E "(description|product|vendor)"
fi

header "\n6. NIC Information:"
header "-------------------"
if check_tool lspci; then
    log "Network Controllers:"
    lspci | grep -i "network\|ethernet"
fi

if check_tool lshw; then
    log "\nNIC from lshw:"
    sudo lshw -class network | grep -A 10 -E "(description|product|vendor|serial|capacity)"
fi

if check_tool ip; then
    log "\nNetwork interfaces:"
    ip link show | grep -E "^[0-9]+:"
fi

log "\nScript completed."
