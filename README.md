# JemaOS rEFInd USB Installer

A comprehensive script to add the rEFInd bootloader to JemaOS USB devices, enabling multi-boot capabilities and improved boot management.

## how to use 
1. Flash with usb with cros_sdk -> Flash command 
2. clone this script run the script `add_refind_to_usb.sh` 

## Overview

This script installs rEFInd bootloader on a USB device that already has JemaOS flashed, creating a new 13th partition for rEFInd and configuring automatic detection of installed operating systems plus JemaOS from the USB device.

## Features

- ✅ **Automatic Partition Management**: Creates a new 13th partition for rEFInd
- ✅ **Theme Support**: Supports custom rEFInd themes (local or remote Git repositories)
- ✅ **JemaOS Integration**: Automatically configures JemaOS boot entry with custom icon
- ✅ **GRUB Configuration**: Updates JemaOS GRUB timeout to 0 for seamless rEFInd experience
- ✅ **Partition Label Management**: Updates both GPT and FAT labels for better identification
- ✅ **Debug Mode**: Comprehensive debugging with partition content preservation
- ✅ **Robust Error Handling**: Advanced partition table refresh and error 


## Prerequisites

- **Root access** (script must be run as root)
- **JemaOS USB device** with existing 12-partition structure
- **Required tools**: `sgdisk`, `mkfs.vfat`, `wget`, `unzip`, `git` (for remote themes)
- **Optional tools**: `fatlabel` (for FAT filesystem label updates)

## Installation

### Quick Start

```bash
# Clone the repository
git clone https://github.com/JemaOS/jemaos-refind-usb-installer.git
cd jemaos-refind-usb-installer

# Make script executable
chmod +x add_refind_to_usb.sh

# Install rEFInd (replace /dev/sdX with your USB device)
sudo ./add_refind_to_usb.sh --device /dev/sdX
```

### Configuration Options

Edit the script variables at the top of `add_refind_to_usb.sh`:

```bash
# Debug and logging
DEBUG_MODE=0              # Set to 1 to preserve work directory and enable verbose logging
REFIND_LOG_LEVEL=0        # Log level (0=silent, 1=error, 2=warning, 3=info, 4=verbose)

# rEFInd version and download
REFIND_VERSION="0.14.2"   # rEFInd version to download

# Theme configuration (uncomment one)
# THEME_REPOSITORY=""                                                    # No custom theme
# THEME_REPOSITORY="https://github.com/Pr0cella/rEFInd-glassy.git"     # Remote theme
# THEME_REPOSITORY="/path/to/local/theme"                               # Local theme

# Boot configuration
REFIND_TIMEOUT=-1         # Boot timeout (-1 = wait indefinitely)
REFIND_PARTITION_SIZE_MB=128  # rEFInd partition size in MB

# Partition labels
REFIND_PARTITION_LABEL="REFIND"
JEMAOS_PARTITION_LABEL="JEMAOS"
```

## Usage

### Basic Usage

```bash
sudo ./add_refind_to_usb.sh --device /dev/sdX
```

### With Debug Mode

```bash
# Enable debug mode for troubleshooting
# Edit script: DEBUG_MODE=1, REFIND_LOG_LEVEL=4
sudo ./add_refind_to_usb.sh --device /dev/sdX
```

### Command Line Options

- `--device /dev/sdX`: Specify the USB device (required)
- `--help` or `-h`: Show usage information

## What the Script Does

### Step-by-Step Process

1. **Verification**: Checks JemaOS structure and validates partition 12 (EFI)
2. **Label Updates**: Updates partition 12 labels (both GPT and FAT) for better identification
3. **GRUB Configuration**: Sets GRUB timeout to 0 seconds in partition 12
4. **Partition Creation**: Creates 13th partition (128MB) for rEFInd
5. **rEFInd Installation**: Downloads and installs rEFInd v0.14.2
6. **Theme Installation**: Installs custom theme (if configured)
7. **Icon Integration**: Copies JemaOS icon for proper OS detection
8. **Configuration**: Generates rEFInd configuration with variable substitution
9. **Auto-boot Setup**: Installs startup.nsh for UEFI auto-boot
10. **Debug Copying**: (Debug mode) Preserves partition contents for inspection

### File Structure After Installation

```
USB Device
├── Partitions 1-12 (JemaOS original structure)
└── Partition 13 (rEFInd)
    ├── EFI/
    │   └── BOOT/
    │       ├── bootx64.efi (rEFInd bootloader)
    │       ├── refind.conf (configuration)
    │       ├── icons/ (including os_jemaos.png)
    │       └── themes/ (custom theme if installed)
    └── startup.nsh (UEFI auto-boot script)
```

## Theme Support

### Supported Theme Sources

- **Remote Git repositories**: Automatically cloned during installation
- **Local directories**: Copied from local filesystem
- **Default icons**: Falls back to rEFInd default icons

### Popular Themes

```bash
# Glassy theme (modern, transparent)
THEME_REPOSITORY="https://github.com/Pr0cella/rEFInd-glassy.git"

```

## Boot Process

### Normal Boot Flow

1. **UEFI Boot**: System boots from USB device
2. **OS Detection**: rEFInd scans for available operating systems
3. **Menu Display**: Shows JemaOS and other detected OS options
4. **OS Selection**: User selects desired operating system

### Boot Options Available

- **JemaOS**: Boots from partition 12 (USB device)
- **Detected OS**: Any other operating systems found on the system

## Troubleshooting

### Common Issues

#### Boot Problems
- **rEFInd doesn't start**: Check UEFI boot order and Secure Boot settings
- **JemaOS missing**: Verify partition 12 contains valid GRUB installation 

#### Debug Mode
```bash
# Enable debug mode for detailed troubleshooting
DEBUG_MODE=1
REFIND_LOG_LEVEL=1 (0-4)
```

### Debug Information

When `DEBUG_MODE=1`, the script preserves:
- Work directory with all downloaded/extracted files
- Complete copy of partition 12 (JemaOS EFI)
- Complete copy of partition 13 (rEFInd)
- Verbose logging and detailed error information

## Advanced Configuration

### Partition Labels

The script handles FAT label compatibility:
- **11 character limit**: Labels longer than 11 chars are truncated
- **No spaces**: Spaces converted to underscores
- **Uppercase**: Converted for consistency

## System Requirements

### Target Systems
- **UEFI-compatible** systems (Legacy BIOS not supported)
- **64-bit architecture** (primary support)
- **32-bit architecture** (included but less tested)

### USB Device Requirements
- **JemaOS pre-installed** with 12-partition structure
- **Minimum 128MB free space** for rEFInd partition

## License

Copyright (c) 2025 Jema Technology.


---

**Note**: This script is designed for JemaOS USB devices and may not work with other ChromeOS-based systems.
