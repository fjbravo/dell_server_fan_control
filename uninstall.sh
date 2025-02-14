#!/bin/bash

# Exit on error
set -e

INSTALL_DIR="/usr/local/bin/dell-fan-control"
SERVICE_NAME="dell_ipmi_fan_control"
BACKUP_DIR="/tmp/dell-fan-control-backup-$(date +%Y%m%d_%H%M%S)"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Error: Please run with sudo privileges."
    exit 1
fi

echo "Dell Server Fan Control Uninstall Script"
echo "--------------------------------------"
echo "This script will:"
echo "1. Stop and disable the fan control service"
echo "2. Remove all installed files"
echo "3. Restore Dell's default fan control"
echo "4. Create a backup of your configuration (optional)"
echo

# Ask for confirmation
read -p "Do you want to proceed with uninstallation? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Uninstallation cancelled."
    exit 0
fi

# Ask about backup
read -p "Would you like to backup your configuration before uninstalling? (Y/n) " -n 1 -r
echo
BACKUP=true
if [[ $REPLY =~ ^[Nn]$ ]]; then
    BACKUP=false
fi

# Create backup if requested
if [ "$BACKUP" = true ]; then
    echo "Creating backup..."
    mkdir -p "$BACKUP_DIR"
    if [ -d "$INSTALL_DIR" ]; then
        cp -r "$INSTALL_DIR"/* "$BACKUP_DIR/" 2>/dev/null || true
        echo "- Configuration backed up to: $BACKUP_DIR"
    else
        echo "- No configuration files found to backup"
    fi
fi

# Stop and disable service
echo "Stopping fan control service..."
if systemctl is-active --quiet ${SERVICE_NAME}; then
    # Try to restore Dell's fan control before stopping
    if [ -x "$INSTALL_DIR/shutdown_fan_control.sh" ]; then
        echo "- Restoring Dell's fan control..."
        "$INSTALL_DIR/shutdown_fan_control.sh"
    else
        echo "- Warning: Could not find shutdown script, attempting manual fan control restoration..."
        if command -v ipmitool >/dev/null 2>&1; then
            ipmitool raw 0x30 0x30 0x01 0x01
        fi
    fi
    
    echo "- Stopping service..."
    systemctl stop ${SERVICE_NAME}
fi

echo "- Disabling service..."
systemctl disable ${SERVICE_NAME} 2>/dev/null || true

# Remove files
echo "Removing installed files..."
if [ -d "$INSTALL_DIR" ]; then
    echo "- Removing installation directory..."
    rm -rf "$INSTALL_DIR"
fi

if [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]; then
    echo "- Removing service file..."
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
fi

# Reload systemd
echo "Reloading systemd configuration..."
systemctl daemon-reload

# Final check for Dell's fan control
echo "Ensuring Dell's fan control is restored..."
if command -v ipmitool >/dev/null 2>&1; then
    ipmitool raw 0x30 0x30 0x01 0x01 || true
fi

echo
echo "Uninstallation completed successfully!"
if [ "$BACKUP" = true ]; then
    echo "Your configuration has been backed up to: $BACKUP_DIR"
    echo "To reinstall with the same configuration:"
    echo "1. Reinstall the software"
    echo "2. Copy the backed-up config.env to: $INSTALL_DIR/"
fi
echo
echo "Note: The server's fans are now under Dell's control again."