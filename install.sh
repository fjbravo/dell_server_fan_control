#!/bin/bash

# Exit on error
set -e

INSTALL_DIR="/usr/local/bin/dell-fan-control"
SERVICE_NAME="dell_ipmi_fan_control"
BACKUP_DIR="/tmp/dell-fan-control-backup-$(date +%Y%m%d_%H%M%S)"
IS_UPDATE=false

echo "Dell Server Fan Control Installation Script"
echo "----------------------------------------"
echo "WARNING: Ensure IPMI is enabled in your iDRAC settings before proceeding."
echo "This script requires sudo privileges to install system-wide."
echo

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo privileges."
    exit 1
fi

# Function to backup existing installation
backup_existing() {
    if [ -d "$INSTALL_DIR" ] || [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]; then
        echo "Existing installation found. Creating backup..."
        mkdir -p "$BACKUP_DIR"
        
        if [ -d "$INSTALL_DIR" ]; then
            cp -r "$INSTALL_DIR" "$BACKUP_DIR/"
        fi
        
        if [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]; then
            cp "/etc/systemd/system/${SERVICE_NAME}.service" "$BACKUP_DIR/"
        fi
        
        echo "Backup created at: $BACKUP_DIR"
        IS_UPDATE=true
    fi
}

# Function to preserve user settings
preserve_settings() {
    if [ -f "$INSTALL_DIR/fan_control.sh" ]; then
        echo "Preserving existing user settings..."
        # Extract user-defined variables
        TEMP_SETTINGS=$(mktemp)
        grep -E '^[[:space:]]*(MIN_TEMP|MAX_TEMP|FAN_MIN|HYST_TEMP|HYST_LEVEL|CHECK_INTERVAL|DEBUG)=' "$INSTALL_DIR/fan_control.sh" > "$TEMP_SETTINGS" || true
        
        if [ -s "$TEMP_SETTINGS" ]; then
            echo "Found existing settings, will restore after update."
            return 0
        fi
    fi
    return 1
}

# Function to restore user settings
restore_settings() {
    if [ -f "$TEMP_SETTINGS" ] && [ -s "$TEMP_SETTINGS" ]; then
        echo "Restoring user settings..."
        while IFS= read -r setting; do
            variable=$(echo "$setting" | cut -d'=' -f1 | tr -d '[:space:]')
            value=$(echo "$setting" | cut -d'=' -f2)
            sed -i "s/^[[:space:]]*$variable=.*/$variable=$value/" "$INSTALL_DIR/fan_control.sh"
        done < "$TEMP_SETTINGS"
        rm "$TEMP_SETTINGS"
    fi
}

# Stop service if running
if systemctl is-active --quiet ${SERVICE_NAME}; then
    echo "Stopping existing service..."
    systemctl stop ${SERVICE_NAME}
fi

# Backup existing installation
backup_existing

# Preserve settings if updating
if [ "$IS_UPDATE" = true ]; then
    preserve_settings
fi

# Install dependencies
echo "Installing required packages..."
apt-get update
apt-get install -y lm-sensors ipmitool

# Create installation directory
mkdir -p "$INSTALL_DIR"

# Install scripts
echo "Installing scripts..."
cp fan_control.sh "$INSTALL_DIR/"
cp shutdown_fan_control.sh "$INSTALL_DIR/"

# Make scripts executable
chmod +x "$INSTALL_DIR/fan_control.sh"
chmod +x "$INSTALL_DIR/shutdown_fan_control.sh"

# Restore settings if updating
if [ "$IS_UPDATE" = true ]; then
    restore_settings
fi

# Install service file
echo "Installing systemd service..."
cp dell_ipmi_fan_control.service /etc/systemd/system/

# Reload systemd
systemctl daemon-reload

# Enable and start service
echo "Enabling and starting service..."
systemctl enable ${SERVICE_NAME}.service
systemctl start ${SERVICE_NAME}.service

echo
if [ "$IS_UPDATE" = true ]; then
    echo "Update completed successfully!"
    echo "Previous installation backed up to: $BACKUP_DIR"
else
    echo "Installation completed successfully!"
fi
echo "The service is now running."
echo
echo "To check service status: systemctl status ${SERVICE_NAME}"
echo "To view logs: journalctl -u ${SERVICE_NAME}"
echo "Configuration files are located in: $INSTALL_DIR"
echo
echo "Note: You can modify the temperature and fan settings by editing"
echo "      $INSTALL_DIR/fan_control.sh"

if [ "$IS_UPDATE" = true ]; then
    echo
    echo "If you experience any issues with this update, you can restore"
    echo "the backup from $BACKUP_DIR"
fi