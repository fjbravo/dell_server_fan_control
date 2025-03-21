#!/bin/bash

# Dell Server Fan Control - Configuration Migration Script
# This script migrates existing config.env files to include MQTT settings

# Exit on error
set -e

CONFIG_PATH="/usr/local/bin/dell-fan-control/config.env"
TEMPLATE_PATH="/usr/local/bin/dell-fan-control/config.template.env"
BACKUP_PATH="${CONFIG_PATH}.bak.$(date +%Y%m%d_%H%M%S)"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Error: Please run with sudo privileges."
    exit 1
fi

# Check if config file exists
if [ ! -f "$CONFIG_PATH" ]; then
    echo "Error: Configuration file not found at $CONFIG_PATH"
    exit 1
fi

echo "Dell Server Fan Control - Configuration Migration"
echo "------------------------------------------------"
echo "This script will update your configuration to include MQTT settings."
echo "Your original configuration will be backed up."
echo

# Create backup
echo "Creating backup of current configuration..."
cp "$CONFIG_PATH" "$BACKUP_PATH"
echo "Backup created at: $BACKUP_PATH"

# Add version tracking if not present
if ! grep -q "CONFIG_VERSION" "$CONFIG_PATH"; then
    echo "Adding configuration version tracking..."
    echo -e "\n# Configuration version" >> "$CONFIG_PATH"
    echo "CONFIG_VERSION=2" >> "$CONFIG_PATH"
else
    echo "Updating configuration version..."
    sed -i 's/CONFIG_VERSION=.*/CONFIG_VERSION=2/' "$CONFIG_PATH"
fi

# Check for MQTT settings and add if missing
echo "Checking for MQTT settings..."

# Function to add a setting if it doesn't exist
add_setting() {
    local setting="$1"
    local value="$2"
    local comment="$3"
    
    if ! grep -q "^${setting}=" "$CONFIG_PATH"; then
        if [ -n "$comment" ]; then
            echo -e "\n# $comment" >> "$CONFIG_PATH"
        fi
        echo "${setting}=${value}" >> "$CONFIG_PATH"
        echo "- Added $setting"
    else
        echo "- $setting already exists"
    fi
}

# Check if MQTT section exists
if ! grep -q "MQTT Settings" "$CONFIG_PATH"; then
    echo "Adding MQTT settings section..."
    echo -e "\n# MQTT Settings" >> "$CONFIG_PATH"
    echo "# Configure these settings to enable remote monitoring via MQTT" >> "$CONFIG_PATH"
    echo "# Leave MQTT_BROKER empty to disable MQTT publishing" >> "$CONFIG_PATH"
    
    # Add all MQTT settings
    add_setting "MQTT_BROKER" "" ""
    add_setting "MQTT_PORT" "1883" "MQTT broker port (default: 1883, TLS: 8883)"
    add_setting "MQTT_USER" "" "MQTT username (optional)"
    add_setting "MQTT_PASS" "" "MQTT password (optional)"
    add_setting "MQTT_TLS" "n" "Enable TLS encryption (y/n)"
    add_setting "MQTT_CA_CERT" "" "Path to CA certificate file (for TLS)"
    add_setting "MQTT_CLIENT_CERT" "" "Path to client certificate file (for TLS)"
    add_setting "MQTT_CLIENT_KEY" "" "Path to client key file (for TLS)"
    add_setting "MQTT_TIMEOUT" "3" "Timeout in seconds for MQTT connections"
    add_setting "MQTT_MAX_FAILURES" "3" "Max consecutive failures before disabling MQTT"
else
    # Check individual MQTT settings
    add_setting "MQTT_BROKER" "" "MQTT broker hostname or IP address"
    add_setting "MQTT_PORT" "1883" "MQTT broker port (default: 1883, TLS: 8883)"
    add_setting "MQTT_USER" "" "MQTT username (optional)"
    add_setting "MQTT_PASS" "" "MQTT password (optional)"
    add_setting "MQTT_TLS" "n" "Enable TLS encryption (y/n)"
    add_setting "MQTT_CA_CERT" "" "Path to CA certificate file (for TLS)"
    add_setting "MQTT_CLIENT_CERT" "" "Path to client certificate file (for TLS)"
    add_setting "MQTT_CLIENT_KEY" "" "Path to client key file (for TLS)"
    add_setting "MQTT_TIMEOUT" "3" "Timeout in seconds for MQTT connections"
    add_setting "MQTT_MAX_FAILURES" "3" "Max consecutive failures before disabling MQTT"
fi

echo
echo "Configuration migration completed successfully!"
echo "You can now edit $CONFIG_PATH to configure your MQTT settings."
echo
echo "To enable MQTT monitoring:"
echo "1. Set MQTT_BROKER to your MQTT broker hostname or IP address"
echo "2. Verify MQTT_PORT is correct (default: 1883, TLS: 8883)"
echo "3. Set authentication credentials if required"
echo "4. Restart the service: sudo systemctl restart dell_ipmi_fan_control"
echo
echo "For detailed MQTT setup instructions, see the documentation:"
echo "https://github.com/fjbravo/dell_server_fan_control/blob/feature/server-monitoring/docs/MQTT-DEPLOYMENT.md"
