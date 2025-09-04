#!/bin/bash

# Copyright (c) 2025 Jema Technology.
# =============================================================================
# rEFInd USB Installation Script for JemaOS
# =============================================================================
# This script installs rEFInd bootloader on a USB device with JemaOS 
# It creates a new 13th partition for rEFInd and configures auto-detection
# of installed OS plus JemaOS from the USB device

# Configuration Variables (Edit these as needed)
# =============================================================================
DEBUG_MODE=0  # Set to 1 to enable debug mode (preserve $WORK_DIR and copy partitions)
REFIND_LOG_LEVEL=0  # Set log level (0=silent, 1=error, 2=warning, 3=info, 4=verbose)

REFIND_VERSION="0.14.2"
REFIND_DOWNLOAD_URL="https://netix.dl.sourceforge.net/project/refind/${REFIND_VERSION}/refind-bin-${REFIND_VERSION}.zip"

# Theme Repository Options (uncomment one to use a custom theme)
# THEME_REPOSITORY=""
# THEME_REPOSITORY="git@github.com:JemaOS/jemaos-refind-theme.git"
THEME_REPOSITORY="https://github.com/Pr0cella/rEFInd-glassy.git"
# THEME_REPOSITORY="https://github.com/bobafetthotmail/refind-theme-regular.git"
# THEME_REPOSITORY="/home/ranjith/jemaos/r114/git_clones/jemaos-refind-theme"



REFIND_TIMEOUT=40

# rEFInd partition size in MB (will be automatically converted to sectors)
# REFIND_PARTITION_SIZE_MB=64  # Size in MB
REFIND_PARTITION_SIZE_MB=128  # Note: for debug logs I have doubled the size 

# Auto-calculate partition size in sectors (512-byte sectors)
# Formula: MB * 1024 * 1024 / 512 = MB * 2048
REFIND_PARTITION_SIZE=$((REFIND_PARTITION_SIZE_MB * 2048))  # Auto-calculated sectors

REFIND_PARTITION_LABEL="REFIND"
CHROMEOS_PARTITION_NUMBER=12  # JemaOS EFI partition number


# =============================================================================
# JemaOS Partition Label
# =============================================================================
# This label is used for the JemaOS partition (partition 12)
# It will be updated to match the FAT filesystem label used by rEFInd
# The label will be set to a FAT-compatible format during execution
# FAT Label Constraints:
# Max 11 characters: FAT labels have a limit
# No spaces: Spaces are converted to underscores
# Uppercase: Converted to uppercase for consistency
# Example: "JEMAOS" → "JEMAOS", "Jema OS" → "JEMA_OS"

JEMAOS_PARTITION_LABEL="JEMAOS"  

# JemaOS partition label (will be updated to match FAT label)
FAT_LABEL=""  # Will be set during execution

# Exit on any error
set -e

# Get script directory for template files
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REFIND_TEMPLATES_DIR="$SCRIPT_DIR/refind"

# Validate template files exist
if [ ! -d "$REFIND_TEMPLATES_DIR" ]; then
    echo "❌ Error: rEFInd templates directory not found: $REFIND_TEMPLATES_DIR"
    exit 1
fi

for template_file in "refind.conf" "startup.nsh"; do
    if [ ! -f "$REFIND_TEMPLATES_DIR/$template_file" ]; then
        echo "❌ Error: Template file not found: $REFIND_TEMPLATES_DIR/$template_file"
        exit 1
    fi
done

# Check if script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "❌ This script must be run as root"
   exit 1
fi

# Parse command line arguments
USB_DEVICE=""

print_usage() {
    echo "Usage: $0 --device /dev/sdX"
    echo "  --device /dev/sdX   USB device to install rEFInd on"
    echo ""
    echo "Example: $0 --device /dev/sdb"
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --device)
            USB_DEVICE="$2"
            shift 2
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            echo "❌ Unknown option: $1"
            print_usage
            exit 1
            ;;
    esac
done

if [ -z "$USB_DEVICE" ]; then
    echo "❌ Error: USB device not specified"
    print_usage
    exit 1
fi

# Verify the USB device exists and has JemaOS structure
if [ ! -b "$USB_DEVICE" ]; then
    echo "❌ Error: Device $USB_DEVICE does not exist or is not a block device"
    exit 1
fi

# Check if any partitions from this device are currently mounted
echo "🔍 Checking for mounted partitions on $USB_DEVICE..."
MOUNTED_PARTITIONS=$(mount | grep "^$USB_DEVICE" | awk '{print $1}' || true)
if [ -n "$MOUNTED_PARTITIONS" ]; then
    echo "⚠️  Warning: Found mounted partitions from $USB_DEVICE:"
    echo "$MOUNTED_PARTITIONS"
    echo "💡 This may cause partition table update issues"
    echo "💡 Consider unmounting non-essential partitions if problems occur"
fi

echo "🚀 Installing rEFInd bootloader on $USB_DEVICE..."
echo "📋 Configuration:"
echo "   - rEFInd Version: $REFIND_VERSION"
if [ -n "$THEME_REPOSITORY" ]; then
    echo "   - Theme: $(basename "$THEME_REPOSITORY" .git)"
else
    echo "   - Theme: Default rEFInd Icons"
fi
echo "   - Timeout: ${REFIND_TIMEOUT}s"
echo "   - Partition Size: ${REFIND_PARTITION_SIZE_MB}MB (${REFIND_PARTITION_SIZE} sectors)"
echo ""

# Create temporary directories
WORK_DIR=$(mktemp -d)
REFIND_DIR="$WORK_DIR/refind"
THEME_DIR="$WORK_DIR/theme"
MOUNT_DIR="$WORK_DIR/mount"

# Cleanup function
cleanup() {
    echo "🧹 Cleaning up..."
    # Unmount any mounted partitions
    for mount_point in "$MOUNT_DIR"/*; do
        if mountpoint -q "$mount_point" 2>/dev/null; then
            umount "$mount_point" 2>/dev/null || true
        fi
    done
    
    # Try to sync and flush any pending writes
    sync 2>/dev/null || true
    
    # Only delete $WORK_DIR if not in debug mode
    if [ "$DEBUG_MODE" -eq 0 ]; then
        rm -rf "$WORK_DIR" 2>/dev/null || true
    else
        echo "⚠️  Debug mode enabled: $WORK_DIR will NOT be deleted."
    fi
    
    # If we encountered the partition table error, provide guidance
    if [ "${PARTITION_TABLE_ERROR:-0}" -eq 1 ]; then
        echo ""
        echo "❌🔧 PARTITION TABLE UPDATE ISSUE DETECTED:"
        echo "=================================================="
        echo "The partition was created but the kernel couldn't be informed of the change."
        echo "This usually happens when:"
        echo "1. Some partitions on the device are currently mounted"
        echo "2. The device is being accessed by another process"
        echo "3. The kernel has cached the old partition table"
        echo ""
        echo "🔄 RECOMMENDED SOLUTIONS:"
        echo "1. Reboot the system and run the script again"
        echo "2. Or try: sudo partprobe $USB_DEVICE && sudo blockdev --rereadpt $USB_DEVICE"
        echo "3. Or unmount all partitions: sudo umount ${USB_DEVICE}* (if safe to do so)"
        echo ""
        echo "The partition should be available after a reboot."
        echo "=================================================="
    fi
}

trap cleanup EXIT

# Create mount directory
mkdir -p "$MOUNT_DIR"

# =============================================================================
# Step 1: Verify JemaOS structure
# =============================================================================
echo "🔍 Verifying JemaOS structure..."

# Check if partition 12 exists and is EFI type
CHROMEOS_EFI_PARTITION="${USB_DEVICE}${CHROMEOS_PARTITION_NUMBER}"
if [ ! -b "$CHROMEOS_EFI_PARTITION" ]; then
    echo "❌ Error: JemaOS EFI partition $CHROMEOS_EFI_PARTITION not found"
    echo "💡 Expected JemaOS with 12 partitions, partition 12 containing GRUB"
    exit 1
fi

# Verify it's an EFI system partition
EFI_INFO=$(fdisk -l "$USB_DEVICE" | grep "$CHROMEOS_EFI_PARTITION" | grep -i "EFI\|ef00")
if [ -z "$EFI_INFO" ]; then
    echo "❌ Error: Partition 12 is not an EFI System Partition"
    echo "💡 Expected JemaOS EFI partition with GRUB bootloader"
    exit 1
fi

echo "✅ Found JemaOS EFI partition: $CHROMEOS_EFI_PARTITION"

# =============================================================================
# Step 2: Update partition 12 labels (GPT and FAT) to match JEMAOS_PARTITION_LABEL
# =============================================================================
echo "🏷️  Updating partition 12 labels to '$JEMAOS_PARTITION_LABEL'..."

# First update the GPT partition label (what disk utilities show)
echo "📝 Updating GPT partition label..."
sgdisk -c ${CHROMEOS_PARTITION_NUMBER}:"$JEMAOS_PARTITION_LABEL" "$USB_DEVICE" || {
    echo "⚠️  Warning: Failed to update GPT partition label with sgdisk"
}

# Then update the FAT filesystem label (what rEFInd reads)
echo "📝 Updating FAT filesystem label..."
if command -v fatlabel >/dev/null 2>&1; then
    # Check if JEMAOS_PARTITION_LABEL is FAT-compatible (max 11 chars, no spaces)
    if [ ${#JEMAOS_PARTITION_LABEL} -le 11 ] && [[ "$JEMAOS_PARTITION_LABEL" != *" "* ]]; then
        # Use the same label for both GPT and FAT
        FAT_LABEL="$JEMAOS_PARTITION_LABEL"
        echo "📋 Using same label for both GPT and FAT: '$FAT_LABEL'"
    else
        # Create a FAT-compatible version
        FAT_LABEL=$(echo "$JEMAOS_PARTITION_LABEL" | tr ' ' '_' | cut -c1-11 | tr '[:lower:]' '[:upper:]')
        echo "📋 Created FAT-compatible label: '$FAT_LABEL' (from '$JEMAOS_PARTITION_LABEL')"
    fi
    
    fatlabel "${USB_DEVICE}${CHROMEOS_PARTITION_NUMBER}" "$FAT_LABEL" || {
        echo "⚠️  Warning: Failed to update FAT filesystem label with fatlabel"
    }
    echo "✅ Updated FAT filesystem label to '$FAT_LABEL'"
else
    echo "⚠️  fatlabel not found, FAT filesystem label not updated"
    echo "💡 rEFInd may still show the old filesystem label"
    FAT_LABEL="$JEMAOS_PARTITION_LABEL"  # Set for display purposes
fi

# Refresh partition table after label changes
partprobe "$USB_DEVICE"
sleep 4

echo "✅ Updated partition 12 labels:"
if [ "$JEMAOS_PARTITION_LABEL" = "$FAT_LABEL" ]; then
    echo "   - Both GPT and FAT labels: '$JEMAOS_PARTITION_LABEL'"
else
    echo "   - GPT partition label: '$JEMAOS_PARTITION_LABEL'"
    echo "   - FAT filesystem label: '$FAT_LABEL' (for rEFInd compatibility)"
fi

# =============================================================================
# Step 3: Update GRUB configuration in partition 12 (set timeout to 0)
# =============================================================================
echo "⚙️  Updating GRUB configuration in partition 12..."

# Mount the JemaOS EFI partition (partition 12)
JEMAOS_MOUNT_POINT="$MOUNT_DIR/jemaos"
mkdir -p "$JEMAOS_MOUNT_POINT"
mount "$CHROMEOS_EFI_PARTITION" "$JEMAOS_MOUNT_POINT" || {
    echo "⚠️  Warning: Failed to mount JemaOS EFI partition"
    echo "💡 Continuing without GRUB configuration update"
}

if mountpoint -q "$JEMAOS_MOUNT_POINT" 2>/dev/null; then
    # Check if grub.cfg exists
    GRUB_CONFIG_PATH="$JEMAOS_MOUNT_POINT/efi/boot/grub.cfg"
    if [ -f "$GRUB_CONFIG_PATH" ]; then
        echo "📋 Found GRUB configuration: $GRUB_CONFIG_PATH"
        
        # Show current timeout setting
        echo "📋 Current timeout setting:"
        grep "^set timeout=" "$GRUB_CONFIG_PATH" || echo "   No timeout setting found"
        
        # Update any timeout value to 0 (handles empty values, numbers, etc.)
        if grep -q "^set timeout=" "$GRUB_CONFIG_PATH"; then
            sed -i 's/^set timeout=.*/set timeout=0/' "$GRUB_CONFIG_PATH"
            echo "✅ Updated GRUB timeout to 0 seconds"
        else
            echo "⚠️  No timeout setting found in grub.cfg"
        fi
        
        # Show updated timeout setting
        echo "📋 Updated timeout setting:"
        grep "^set timeout=" "$GRUB_CONFIG_PATH" || echo "   No timeout setting found"
        
    else
        echo "⚠️  GRUB configuration not found: $GRUB_CONFIG_PATH"
        echo "💡 Expected path: /efi/boot/grub.cfg"
        echo "📋 Available files in /efi/boot/:"
        ls -la "$JEMAOS_MOUNT_POINT/efi/boot/" 2>/dev/null || echo "   Directory not found"
    fi
    
    # Unmount the JemaOS partition
    umount "$JEMAOS_MOUNT_POINT" || {
        echo "⚠️  Warning: Failed to unmount JemaOS partition"
    }
else
    echo "⚠️  JemaOS partition not mounted, skipping GRUB configuration update"
fi

echo "✅ GRUB configuration update completed"

# =============================================================================
# Step 4: Create 13th partition for rEFInd
# =============================================================================
echo "🔨 Creating partition 13 for rEFInd..."

# Fix GPT table if needed
echo "🔧 Checking and fixing GPT table..."
sgdisk -e "$USB_DEVICE" || {
    echo "⚠️  Warning: Failed to fix GPT table, continuing anyway..."
}

# Show current partition information for debugging
echo "📋 Current partition table:"
fdisk -l "$USB_DEVICE" | grep "^$USB_DEVICE" | head -15

# Find the last partition and calculate new partition boundaries
# Use a more robust method to extract partition numbers
# LAST_PARTITION_NUM=12
# NEW_PARTITION_NUM=13
LAST_PARTITION_NUM=$(fdisk -l "$USB_DEVICE" | grep "^$USB_DEVICE" | sed "s|^$USB_DEVICE||" | sed 's/[^0-9].*$//' | sort -n | tail -1)
NEW_PARTITION_NUM=$((LAST_PARTITION_NUM + 1))
NEW_PARTITION="${USB_DEVICE}${NEW_PARTITION_NUM}"

echo "🔍 Detected last partition: $LAST_PARTITION_NUM"
echo "🔍 Will create partition: $NEW_PARTITION_NUM"

# Get the highest end sector using a more robust method
HIGHEST_END_SECTOR=$(fdisk -l "$USB_DEVICE" | grep "^$USB_DEVICE" | awk '{print $3}' | sort -n | tail -1)
START_SECTOR=$((HIGHEST_END_SECTOR + 2048))  # 1MB padding
END_SECTOR=$((START_SECTOR + REFIND_PARTITION_SIZE - 1))

# Check available space
TOTAL_SECTORS=$(fdisk -l "$USB_DEVICE" | grep "^Disk $USB_DEVICE:" | awk '{print $7}' | sed 's/,//')
DISK_SIZE_GB=$(( TOTAL_SECTORS * 512 / 1024 / 1024 / 1024 ))
echo "💾 Disk size: ${DISK_SIZE_GB}GB ($TOTAL_SECTORS sectors)"

if [ $END_SECTOR -gt $TOTAL_SECTORS ]; then
    echo "❌ Error: Not enough space on device"
    echo "💡 Available: $TOTAL_SECTORS sectors, Required: $END_SECTOR sectors"
    exit 1
fi

# Validate partition number is reasonable (should be 13 for JemaOS)
if [ $NEW_PARTITION_NUM -gt 128 ] || [ $NEW_PARTITION_NUM -lt 13 ]; then
    echo "❌ Error: Invalid partition number detected: $NEW_PARTITION_NUM"
    echo "💡 Expected partition 13 for JemaOS with 12 existing partitions"
    echo "💡 Current partitions:"
    fdisk -l "$USB_DEVICE" | grep "^$USB_DEVICE"
    exit 1
fi

# Check if partition 13 already exists
if [ -b "${USB_DEVICE}13" ]; then
    echo "⚠️  Warning: Partition 13 already exists on $USB_DEVICE"
    echo "💡 This may indicate a previous installation or manual partition setup"
    echo "💡 Please check the partition table and remove partition 13 if needed"
    echo "💡 Current partition 13 info:"
    fdisk -l "$USB_DEVICE" | grep "${USB_DEVICE}13" || echo "   (No detailed info available)"
    exit 1
fi

# Create the new partition using sgdisk
echo "📝 Creating partition $NEW_PARTITION_NUM from sector $START_SECTOR to $END_SECTOR"
sgdisk -n ${NEW_PARTITION_NUM}:${START_SECTOR}:${END_SECTOR} \
       -t ${NEW_PARTITION_NUM}:ef00 \
       -c ${NEW_PARTITION_NUM}:"$REFIND_PARTITION_LABEL" \
       -A ${NEW_PARTITION_NUM}:set:2 \
       "$USB_DEVICE" || {
    echo "❌ Error: Failed to create partition using sgdisk"
    echo "💡 Trying alternative approach..."
    
    # Try using sgdisk with default end sector
    sgdisk -n ${NEW_PARTITION_NUM}:${START_SECTOR}:+${REFIND_PARTITION_SIZE_MB}M \
           -t ${NEW_PARTITION_NUM}:ef00 \
           -c ${NEW_PARTITION_NUM}:"$REFIND_PARTITION_LABEL" \
           -A ${NEW_PARTITION_NUM}:set:2 \
           "$USB_DEVICE" || {
        echo "❌ Error: Failed to create partition with alternative method"
        echo "💡 Current partition table:"
        fdisk -l "$USB_DEVICE" | grep "^$USB_DEVICE"
        echo ""
        echo "🔧 TROUBLESHOOTING STEPS:"
        echo "1. Check if any partitions are mounted: mount | grep $USB_DEVICE"
        echo "2. Unmount any mounted partitions: sudo umount ${USB_DEVICE}*"
        echo "3. Try running the script again"
        echo "4. If the issue persists, reboot and try again"
        exit 1
    }
}

# Refresh partition table with multiple methods
echo "🔄 Refreshing partition table..."
PARTITION_TABLE_ERROR=0

# Try partprobe first
if ! partprobe "$USB_DEVICE" 2>/dev/null; then
    echo "⚠️  partprobe failed, trying alternative methods..."
    PARTITION_TABLE_ERROR=1
fi

# Try additional methods to refresh partition table
if command -v blockdev >/dev/null 2>&1; then
    if ! blockdev --rereadpt "$USB_DEVICE" 2>/dev/null; then
        echo "⚠️  blockdev failed"
        PARTITION_TABLE_ERROR=1
    fi
fi

# Force kernel to re-read partition table
echo 1 > /sys/block/$(basename "$USB_DEVICE")/device/rescan 2>/dev/null || PARTITION_TABLE_ERROR=1

# Wait longer for partition table to be recognized
sleep 5

# Check if the error occurred and provide guidance
if [ $PARTITION_TABLE_ERROR -eq 1 ]; then
    echo "⚠️  Warning: Partition table update issues detected"
    echo "💡 The partition was likely created but the kernel couldn't be informed"
    echo "💡 This is usually not a critical error, but you may need to reboot"
fi

# Verify the new partition exists before formatting
if [ ! -b "$NEW_PARTITION" ]; then
    echo "⚠️  Partition $NEW_PARTITION not immediately available, waiting..."
    sleep 5
    if [ ! -b "$NEW_PARTITION" ]; then
        echo "❌ Error: Partition $NEW_PARTITION was not created successfully"
        echo "💡 The partition may exist but isn't visible to the kernel yet"
        echo "💡 Try: sudo partprobe $USB_DEVICE && ls -la ${USB_DEVICE}*"
        echo "💡 Or reboot and check if the partition exists"
        PARTITION_TABLE_ERROR=1
        exit 1
    fi
fi

# Format the new partition
echo "💾 Formatting partition as FAT32..."
if ! mkfs.vfat -F 32 -n "$REFIND_PARTITION_LABEL" "$NEW_PARTITION"; then
    echo "❌ Error: Failed to format partition $NEW_PARTITION"
    echo "💡 The partition may not be available yet"
    echo "💡 Try running the script again or reboot first"
    PARTITION_TABLE_ERROR=1
    exit 1
fi

echo "✅ Created and formatted partition: $NEW_PARTITION"

# =============================================================================
# Step 5: Download and extract rEFInd bootloader
# =============================================================================
echo "📥 Downloading rEFInd $REFIND_VERSION..."

mkdir -p "$REFIND_DIR"
wget -q --show-progress -O "$REFIND_DIR/refind.zip" "$REFIND_DOWNLOAD_URL"

echo "📦 Extracting rEFInd..."
unzip -q "$REFIND_DIR/refind.zip" -d "$REFIND_DIR"

# Find the extracted directory
REFIND_EXTRACTED=$(find "$REFIND_DIR" -name "refind-bin-*" -type d | head -1)
if [ -z "$REFIND_EXTRACTED" ]; then
    echo "❌ Error: Could not find extracted rEFInd directory"
    exit 1
fi

echo "✅ rEFInd extracted to: $REFIND_EXTRACTED"

# =============================================================================
# Step 6: Download and prepare theme (if configured)
# =============================================================================
echo "🎨 Installing rEFInd Theme..."

# Check if THEME_REPOSITORY is a local path or remote URL
if [ -n "$THEME_REPOSITORY" ]; then
    if [ -d "$THEME_REPOSITORY" ]; then
        # Local path - copy the theme
        echo "📁 Using local theme from: $THEME_REPOSITORY"
        echo "📋 Theme directory contents:"
        ls -la "$THEME_REPOSITORY"
        mkdir -p "$THEME_DIR"
        cp -r "$THEME_REPOSITORY"/* "$THEME_DIR" || {
            echo "⚠️  Warning: Failed to copy local theme, using default theme"
            THEME_DIR=""
        }
    else
        # Remote URL - clone the theme
        echo "📥 Cloning theme from: $THEME_REPOSITORY"
        mkdir -p "$THEME_DIR"
        git clone "$THEME_REPOSITORY" "$THEME_DIR" || {
            echo "⚠️  Warning: Failed to clone theme repository, using default theme"
            THEME_DIR=""
        }
    fi
else
    echo "⚠️  No theme repository specified, using default theme"
    THEME_DIR=""
fi

# =============================================================================
# Step 7: Mount rEFInd partition and install files (rEFInd, theme, JemaOS icon)
# =============================================================================
echo "🔧 Configuring rEFInd installation..."

REFIND_MOUNT_POINT="$MOUNT_DIR/refind"
mkdir -p "$REFIND_MOUNT_POINT"
mount "$NEW_PARTITION" "$REFIND_MOUNT_POINT"

# Create EFI directory structure
mkdir -p "$REFIND_MOUNT_POINT/EFI/BOOT"
mkdir -p "$REFIND_MOUNT_POINT/EFI/tools"

# Copy rEFInd files
echo "📋 Installing rEFInd files..."
cp -r "$REFIND_EXTRACTED/refind"/* "$REFIND_MOUNT_POINT/EFI/BOOT/"

# Rename rEFInd EFI binaries to standard bootloader names (bootx64.efi, bootia32.efi) for UEFI compatibility
if [ -f "$REFIND_MOUNT_POINT/EFI/BOOT/refind_x64.efi" ]; then
    mv "$REFIND_MOUNT_POINT/EFI/BOOT/refind_x64.efi" "$REFIND_MOUNT_POINT/EFI/BOOT/bootx64.efi"
fi

if [ -f "$REFIND_MOUNT_POINT/EFI/BOOT/refind_ia32.efi" ]; then
    mv "$REFIND_MOUNT_POINT/EFI/BOOT/refind_ia32.efi" "$REFIND_MOUNT_POINT/EFI/BOOT/bootia32.efi"
fi

# Install theme if available
if [ -n "$THEME_DIR" ] && [ -f "$THEME_DIR/theme.conf" ]; then
    echo "🎨 Installing theme..."
    
    # Get theme name from repository URL or directory name
    if [ -n "$THEME_REPOSITORY" ]; then
        # Extract theme name from URL or path (keep full name)
        THEME_NAME=$(basename "$THEME_REPOSITORY" .git)
    else
        THEME_NAME="custom-theme"
    fi
    
    echo "📋 Theme name: $THEME_NAME"
    
    # Create theme directory with dynamic name
    THEME_INSTALL_DIR="$REFIND_MOUNT_POINT/EFI/BOOT/themes/$THEME_NAME"
    mkdir -p "$THEME_INSTALL_DIR"
    cp -r "$THEME_DIR"/* "$THEME_INSTALL_DIR/"
    
    # Update theme config path
    # dont remove include before themes/ as it is used in refind.conf
    THEME_CONFIG="include themes/$THEME_NAME/theme.conf"
    ICON_PATH="themes/$THEME_NAME/icons"
    
else
    echo "⚠️  Using default rEFInd icons"
    THEME_CONFIG=""
    ICON_PATH="icons"
fi

# Copy JemaOS icon to icons directory (works for both custom themes and default icons)
JEMAOS_ICON_SOURCE="$REFIND_TEMPLATES_DIR/os_jemaos.png"
if [ -f "$JEMAOS_ICON_SOURCE" ]; then
    echo "📋 Copying JemaOS icon to icons directory..."
    cp "$JEMAOS_ICON_SOURCE" "$REFIND_MOUNT_POINT/EFI/BOOT/icons/os_jemaos.png"
    echo "✅ JemaOS icon copied to icons directory"
else
    echo "⚠️  JemaOS icon not found at: $JEMAOS_ICON_SOURCE"
fi

 
# =============================================================================
# Step 8: Generate rEFInd configuration file with variable substitution
# =============================================================================
echo "⚙️  Creating rEFInd configuration..."

# Choose configuration template 
REFIND_CONFIG_TEMPLATE="$REFIND_TEMPLATES_DIR/refind.conf"
if [ -f "$REFIND_TEMPLATES_DIR/refind_simple.conf" ]; then
    echo "📋 Using simplified rEFInd configuration for better tool compatibility"
    REFIND_CONFIG_TEMPLATE="$REFIND_TEMPLATES_DIR/refind_simple.conf"
fi

# Copy refind.conf template and substitute variables
cp "$REFIND_CONFIG_TEMPLATE" "$REFIND_MOUNT_POINT/EFI/BOOT/refind.conf"



# Debug - show variables before substitution
echo "📋 Variables for substitution:"
echo "   THEME_CONFIG: $THEME_CONFIG"
echo "   REFIND_TIMEOUT: $REFIND_TIMEOUT"
echo "   CHROMEOS_PARTITION_NUMBER: $CHROMEOS_PARTITION_NUMBER"
echo "   REFIND_LOG_LEVEL: $REFIND_LOG_LEVEL"

# Variable substitution for refind.conf template
sed -i "s|\$THEME_CONFIG|$THEME_CONFIG|g" "$REFIND_MOUNT_POINT/EFI/BOOT/refind.conf"
sed -i "s|\$REFIND_TIMEOUT|$REFIND_TIMEOUT|g" "$REFIND_MOUNT_POINT/EFI/BOOT/refind.conf"
sed -i "s|\$CHROMEOS_PARTITION_NUMBER|$CHROMEOS_PARTITION_NUMBER|g" "$REFIND_MOUNT_POINT/EFI/BOOT/refind.conf"
sed -i "s|\$JEMAOS_PARTITION_LABEL|$JEMAOS_PARTITION_LABEL|g" "$REFIND_MOUNT_POINT/EFI/BOOT/refind.conf"

sed -i "s|\$REFIND_LOG_LEVEL|$REFIND_LOG_LEVEL|g" "$REFIND_MOUNT_POINT/EFI/BOOT/refind.conf"

# # Remove 'disabled' lines to enable the menu entries
# sed -i '/^[[:space:]]*disabled[[:space:]]*$/d' "$REFIND_MOUNT_POINT/EFI/BOOT/refind.conf"

# Debug - show final config file
echo "📋 Final refind.conf content:"
cat "$REFIND_MOUNT_POINT/EFI/BOOT/refind.conf"

# =============================================================================
# Step 9: Install startup.nsh for UEFI auto-boot
# =============================================================================
echo "⚙️  Creating startup.nsh for auto-boot..."

# Copy startup.nsh template if it exists
if [ -f "$REFIND_TEMPLATES_DIR/startup.nsh" ]; then
    cp "$REFIND_TEMPLATES_DIR/startup.nsh" "$REFIND_MOUNT_POINT/startup.nsh"
    echo "✅ Startup script installed"
else
    echo "⚠️  Warning: startup.nsh template not found"
fi

# Unmount partition
umount "$REFIND_MOUNT_POINT"



# =============================================================================
# Step 10 : Debug mode - copy partition 12 and 13 contents to $WORK_DIR 
# =============================================================================
if [ "$DEBUG_MODE" -eq 1 ]; then
    echo "🐞 Debug mode: copying partition 12 and 13 contents to $WORK_DIR for inspection..."
    # Partition 12 (JemaOS EFI)
    PART12_MOUNT="$WORK_DIR/part12_mount"
    mkdir -p "$PART12_MOUNT"
    mount "${USB_DEVICE}${CHROMEOS_PARTITION_NUMBER}" "$PART12_MOUNT" 2>/dev/null && \
        cp -a "$PART12_MOUNT" "$WORK_DIR/partition12_copy" && \
        umount "$PART12_MOUNT"
    # Partition 13 (rEFInd)
    PART13_MOUNT="$WORK_DIR/part13_mount"
    mkdir -p "$PART13_MOUNT"
    mount "$NEW_PARTITION" "$PART13_MOUNT" 2>/dev/null && \
        cp -a "$PART13_MOUNT" "$WORK_DIR/partition13_copy" && \
        umount "$PART13_MOUNT"
    echo "✅ Partition contents copied to $WORK_DIR/partition12_copy and $WORK_DIR/partition13_copy"
fi



# =============================================================================
# Step 11: Cleanup, unmount, and display comprehensive installation summary
# =============================================================================
echo ""
echo "🎉 rEFInd Installation Complete!"
echo "=================================================="
echo ""
echo "📋 INSTALLATION SUMMARY:"
echo "=================================================="
echo "Device: $USB_DEVICE"
echo "rEFInd Version: $REFIND_VERSION"
echo "rEFInd Partition: $NEW_PARTITION (Partition $NEW_PARTITION_NUM)"
echo "Partition Size: ${REFIND_PARTITION_SIZE_MB}MB (${REFIND_PARTITION_SIZE} sectors)"
echo "Partition Label: $REFIND_PARTITION_LABEL"
echo "JemaOS Partition: ${USB_DEVICE}${CHROMEOS_PARTITION_NUMBER}"
if [ "$JEMAOS_PARTITION_LABEL" = "$FAT_LABEL" ]; then
    echo "   - Label: '$JEMAOS_PARTITION_LABEL' (both GPT and FAT)"
else
    echo "   - GPT Label: '$JEMAOS_PARTITION_LABEL'"
    echo "   - FAT Label: '$FAT_LABEL' (displayed in rEFInd)"
fi
echo "Boot Timeout: ${REFIND_TIMEOUT} seconds"
echo ""
echo "🐞 DEBUG CONFIGURATION:"
echo "=================================================="
if [ "$DEBUG_MODE" -eq 1 ]; then
    echo "Debug Mode: ✅ ENABLED"
    echo "rEFInd Log Level: $REFIND_LOG_LEVEL (verbose logging)"
    echo "Work Directory: $WORK_DIR (preserved for inspection)"
    echo "Partition Copies: Available in $WORK_DIR/partition12_copy and $WORK_DIR/partition13_copy"
else
    echo "Debug Mode: ⚠️  DISABLED"
    echo "rEFInd Log Level: $REFIND_LOG_LEVEL (silent logging)"
    echo "Work Directory: Will be cleaned up on exit"
fi
echo ""
echo "🎨 THEME CONFIGURATION:"
echo "=================================================="
if [ -n "$THEME_DIR" ] && [ -n "$THEME_NAME" ]; then
    echo "Theme: $THEME_NAME"
    echo "Theme Source: $THEME_REPOSITORY"
    echo "Theme Path: /EFI/BOOT/themes/$THEME_NAME/"
    echo "Status: ✅ Installed"
else
    echo "Theme: Default rEFInd Icons"
    echo "Status: ⚠️  Custom theme not available"
fi
echo ""
echo "📁 PARTITION STRUCTURE:"
echo "=================================================="
fdisk -l "$USB_DEVICE" | grep "^$USB_DEVICE" | head -15
echo ""
echo "🔧 CONFIGURATION FILES:"
echo "=================================================="
echo "Main Config: /EFI/BOOT/refind.conf"
echo "Startup Script: /startup.nsh"
echo "Boot Loader: /EFI/BOOT/bootx64.efi"
echo "GRUB Config: /efi/boot/grub.cfg (timeout updated to 0)"
echo "Log Level: $REFIND_LOG_LEVEL (0=silent, 4=verbose)"
echo ""
echo "🚀 BOOT INSTRUCTIONS:"
echo "=================================================="
echo "1. Insert the USB device into target computer"
echo "2. Boot from USB device (may require changing boot order in BIOS/UEFI)"
echo "3. Select the 13th partition (rEFInd) in the boot menu"
echo "4. rEFInd will automatically start and show available OS options"
echo "5. Select 'Jema OS' to boot from the USB device"
echo "6. Or select other detected operating systems from the menu"
echo ""
echo "⚙️  ADVANCED rEFInd OPTIONS:"
echo "=================================================="
echo "• Press ESC or F2 during boot to access rEFInd options"
echo "• Edit refind.conf on the rEFInd partition to customize settings"
echo "• Add custom boot entries by editing refind.conf"
echo "• Change timeout by modifying 'timeout $REFIND_TIMEOUT' in refind.conf"
echo ""
echo "🔍 TROUBLESHOOTING:"
echo "=================================================="
echo "• If rEFInd doesn't start: Check UEFI boot order and Secure Boot settings"
echo "• If JemaOS doesn't appear: Verify partition 12 contains valid GRUB installation"
echo "• If custom theme missing: Check theme files in /EFI/BOOT/themes/$THEME_NAME/"
echo "• For boot issues: Check startup.nsh and refind.conf syntax"
echo "• For debugging: Enable DEBUG_MODE=1 in script for verbose logs and partition copies"
echo ""
echo "📄 LOG FILES:"
echo "=================================================="
echo "Installation completed at: $(date)"
if [ "$DEBUG_MODE" -eq 1 ]; then
    echo "Work directory (DEBUG): $WORK_DIR (preserved for inspection)"
    echo "Partition 12 copy: $WORK_DIR/partition12_copy (JemaOS EFI)"
    echo "Partition 13 copy: $WORK_DIR/partition13_copy (rEFInd)"
    echo "Theme files: sudo ls -la $WORK_DIR/partition13_copy/EFI/BOOT/themes/"
else
    echo "Work directory (temporary): $WORK_DIR (will be cleaned up)"
fi
echo "Script location: $SCRIPT_DIR"
echo "Template directory: $REFIND_TEMPLATES_DIR"
echo ""
echo "✅ Installation successful! Your USB device is now ready for multi-boot."
echo "=================================================="

# =============================================================================


