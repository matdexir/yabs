# Server Specs Fetcher (Hardware Specification Report)

A robust and efficient Bash script designed to quickly gather and display detailed hardware specifications of a Linux server, including CPU, RAM, Storage (Disks/SMART), and PCI devices (NICs, GPUs, RAID controllers).

The script utilizes standard Linux utilities like lscpu, dmidecode, lsblk, smartctl, and lspci, and presents the output with clear formatting and color-coded headers for readability.

## 🚀 Features

- Comprehensive Coverage: Reports on CPU architecture, RAM configuration, disk details, and major PCI components.

- Efficiency: Caches output from frequently used commands (like lscpu) to minimize execution time.

- Color-Coded Output: Uses ANSI colors to clearly distinguish headers, information, warnings, and detailed logs.

- Dependency Checking: Warns the user if required tools are missing.

- SMART Data: Attempts to fetch health and identification data for physical disks (/dev/sd*, /dev/nvme*).

## ⚙️ Requirements

This script relies on several standard Linux utilities, some of which require root privileges (sudo) to execute correctly.
- bash
- lscpu
- dmidecode
- lsblk
- smartctl
- lspci
- lshw
- ip


> Note: The script uses sudo for commands like dmidecode, smartctl, and lshw. Ensure your user has the necessary permissions.

## 💻 How to Run

1. Save the script: Save the code as a file, for example, server_specs.sh.

2. Make it executable:
```
chmod +x server_specs.sh

```

3. Execute the script:
```
./server_specs.sh
```

> If you have not recently used sudo, you will be prompted for your password at the start of the execution.

## 📋 Example Output

The output is segmented by hardware category and styled with blue headers and cyan separators.

```
===================================
 Server Hardware Specs Report
===================================

1. CPU Information
-----------------------------------
Brand/Model: Intel(R) Core(TM) i7-10700K CPU @ 3.80GHz
Architecture: x86_64
CPU(s): 16
Core(s) per socket: 8
Socket(s): 1
CPU max MHz: 5100.0000
[... Detailed CPU from dmidecode ...]

2. RAM Information
-----------------------------------
Memory Devices (dmidecode):
Memory Device
    Size: 32 GB
    Speed: 3200 MT/s
    Type: DDR4
    Locator: DIMM_A1
[... more memory devices ...]

3. Disk/Storage Information
-----------------------------------
Block Devices (lsblk):
NAME   SIZE TYPE RO MOUNTPOINT MODEL
sda    1.8T disk  0            SAMSUNG MZQLB1T9HBJR-00A07
vda  100G disk  0 /          Cloud Block Device

SMART info for major disks:
--- Disk: /dev/sda ---
Device Model:     SAMSUNG MZQLB1T9HBJR-00A07
Serial Number:    S5J7NM0R600293
User Capacity:    1.92 TB
[... more SMART info ...]
```
