#!/bin/bash

# Exit on error
set -e

INSTALL_DIR="/usr/local/bin/dell-fan-control"
SERVICE_NAME="dell_ipmi_fan_control"
BACKUP_DIR="/tmp/dell-fan-control-backup-$(date +%Y%m%d_%H%M%S)"
TEMP_DIR="/tmp/dell-fan-control-install"
REPO_URL="https://raw.githubusercontent.com/fjbravo/dell_server_fan_control/feature/server-monitoring"
IS_UPDATE=false
TEMP_SETTINGS=""

# Function to cleanup temporary files
cleanup() {
    if [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
}

# Set up cleanup trap
trap cleanup EXIT

echo "Dell Server Fan Control Installation Script"
echo "----------------------------------------"
echo "WARNING: Ensure IPMI is enabled in your iDRAC settings before proceeding."
echo

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Error: Please run with sudo privileges."
    exit 1
fi

# Function to check and install dependencies
check_dependencies() {
    echo "Step 1: Checking dependencies..."
    local missing_deps=()
    
    # Check for lm-sensors
    if ! dpkg -l | grep -q "^ii.*lm-sensors"; then
        echo "- lm-sensors not found"
        missing_deps+=("lm-sensors")
    else
        echo "- lm-sensors is installed"
    fi
    
    # Check for ipmitool
    if ! dpkg -l | grep -q "^ii.*ipmitool"; then
        echo "- ipmitool not found"
        missing_deps+=("ipmitool")
    else
        echo "- ipmitool is installed"
    fi
    
    # Check for mosquitto-clients (for MQTT support)
    if ! dpkg -l | grep -q "^ii.*mosquitto-clients"; then
        echo "- mosquitto-clients not found"
        missing_deps+=("mosquitto-clients")
    else
        echo "- mosquitto-clients is installed"
    fi
    
    # Install missing dependencies if any
    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo "Installing missing dependencies: ${missing_deps[*]}"
        apt-get update
        apt-get install -y "${missing_deps[@]}"
        echo "Dependencies installation completed"
    else
        echo "All required dependencies are already installed"
    fi
    
    # Check for NVIDIA drivers (optional)
    if command -v nvidia-smi >/dev/null 2>&1; then
        echo "- NVIDIA drivers are installed"
        # Check if GPU is detected
        if nvidia-smi --query-gpu=gpu_name --format=csv,noheader >/dev/null 2>&1; then
            echo "  ✓ NVIDIA GPU detected"
        else
            echo "  ! NVIDIA drivers installed but no GPU detected"
            echo "  ! GPU monitoring will be disabled"
        fi
    else
        echo "- NVIDIA drivers not found"
        echo "  ! GPU monitoring will be disabled"
        echo "  ! To enable GPU monitoring, install NVIDIA drivers and run this script again"
    fi
}

# Function to download required files
download_files() {
    echo "Step 2: Downloading latest files..."
    mkdir -p "$TEMP_DIR"
    cd "$TEMP_DIR" || exit 1
    
    # Download main files
    for file in fan_control.sh shutdown_fan_control.sh dell_ipmi_fan_control.service config.env; do
        echo "- Downloading $file..."
        if ! curl -L -o "$file" "$REPO_URL/$file"; then
            echo "Error: Failed to download $file from $REPO_URL/$file"
            cd - > /dev/null || true
            exit 1
        fi
        
        # Verify file was downloaded and has content
        if [ ! -s "$file" ]; then
            echo "Error: Downloaded file $file is empty"
            cd - > /dev/null || true
            exit 1
        fi
        echo "  Successfully downloaded $file"
    done

    # Download lib directory files
    mkdir -p "$TEMP_DIR/lib"
    for file in logging.sh ipmi_control.sh temperature.sh config.sh mqtt.sh; do
        echo "- Downloading lib/$file..."
        if ! curl -L -o "lib/$file" "$REPO_URL/lib/$file"; then
            echo "Error: Failed to download lib/$file"
            cd - > /dev/null || true
            exit 1
        fi
        
        # Verify file was downloaded and has content
        if [ ! -s "lib/$file" ]; then
            echo "Error: Downloaded file lib/$file is empty"
            cd - > /dev/null || true
            exit 1
        fi
        echo "  Successfully downloaded lib/$file"
    done
    
    # Make scripts executable
    chmod +x fan_control.sh shutdown_fan_control.sh lib/*.sh
    cd - > /dev/null || exit 1
    echo "All files downloaded successfully"
}

# Function to check existing installation
check_installation() {
    echo "Step 3: Checking for existing installation..."
    if [ -d "$INSTALL_DIR" ] || [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]; then
        echo "Existing installation found"
        IS_UPDATE=true
    else
        echo "No existing installation found"
        IS_UPDATE=false
    fi
}

# Function to backup existing installation
backup_existing() {
    echo "Step 4: Processing existing installation..."
    if [ "$IS_UPDATE" = true ]; then
        echo "Creating backup..."
        mkdir -p "$BACKUP_DIR"
        
        # Backup all files from install directory
        if [ -d "$INSTALL_DIR" ]; then
            cp -r "$INSTALL_DIR/"* "$BACKUP_DIR/" 2>/dev/null || true
            echo "- Backed up all files from $INSTALL_DIR"
        fi
        
        if [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]; then
            cp "/etc/systemd/system/${SERVICE_NAME}.service" "$BACKUP_DIR/"
            echo "- Backed up service file"
        fi
        
        echo "Backup created at: $BACKUP_DIR"
    else
        echo "Fresh installation, no backup needed"
    fi
}

# Function to install or update files
install_files() {
    echo "Step 5: Installing files..."
    
    # Create installation directory if it doesn't exist
    mkdir -p "$INSTALL_DIR"
    
    # Copy main files
    cp "$TEMP_DIR/fan_control.sh" "$INSTALL_DIR/"
    cp "$TEMP_DIR/shutdown_fan_control.sh" "$INSTALL_DIR/"
    cp "$TEMP_DIR/dell_ipmi_fan_control.service" /etc/systemd/system/

    # Copy lib files
    mkdir -p "$INSTALL_DIR/lib"
    cp "$TEMP_DIR/lib/"* "$INSTALL_DIR/lib/"
    
    # Handle config file
    if [ "$IS_UPDATE" = true ]; then
        echo "Processing configuration..."
        if [ -f "$INSTALL_DIR/config.env" ]; then
            # Save new config for reference
            cp "$TEMP_DIR/config.env" "$INSTALL_DIR/config.template.env"
            echo "- New default config saved as: $INSTALL_DIR/config.template.env"
            
            # Check if existing config has MQTT settings
            if ! grep -q "MQTT_BROKER" "$INSTALL_DIR/config.env"; then
                echo "- Migrating configuration to include MQTT settings..."
                
                # Create a temporary copy of the new config
                cp "$TEMP_DIR/config.env" "$INSTALL_DIR/config.env.new"
                
                # Add version tracking to existing config if not present
                if ! grep -q "CONFIG_VERSION" "$INSTALL_DIR/config.env"; then
                    echo -e "\n# Configuration version" >> "$INSTALL_DIR/config.env"
                    echo "CONFIG_VERSION=2" >> "$INSTALL_DIR/config.env"
                else
                    sed -i 's/CONFIG_VERSION=.*/CONFIG_VERSION=2/' "$INSTALL_DIR/config.env"
                fi
                
                # Extract MQTT section from new config
                echo "- Adding MQTT settings to your configuration..."
                sed -n '/# MQTT Settings/,/^$/p' "$INSTALL_DIR/config.env.new" >> "$INSTALL_DIR/config.env"
                
                # Clean up
                rm -f "$INSTALL_DIR/config.env.new"
                echo "- Configuration updated with MQTT settings"
                echo "  MQTT is disabled by default (MQTT_BROKER is empty)"
                echo "  Edit $INSTALL_DIR/config.env to configure MQTT if needed"
            else
                echo "- MQTT settings already present in configuration"
            fi
        else
            echo "! No existing config found, creating from downloaded config..."
            cp "$TEMP_DIR/config.env" "$INSTALL_DIR/config.env"
            cp "$TEMP_DIR/config.env" "$INSTALL_DIR/config.template.env"
        fi
    else
        echo "Creating configuration from downloaded config..."
        cp "$TEMP_DIR/config.env" "$INSTALL_DIR/config.env"
        cp "$TEMP_DIR/config.env" "$INSTALL_DIR/config.template.env"
        echo "- Default configuration installed"
        echo "- Please edit $INSTALL_DIR/config.env to set your iDRAC credentials and preferences"
    fi
    
    # Copy migration script
    echo "Installing configuration migration script..."
    cat > "$INSTALL_DIR/migrate_config.sh" << 'EOF'
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
EOF
    chmod +x "$INSTALL_DIR/migrate_config.sh"
    echo "- Migration script installed at: $INSTALL_DIR/migrate_config.sh"
    
    echo "Files installed successfully"
}

# Function to manage service
manage_service() {
    echo "Step 6: Managing service..."
    
    # Stop service if running
    if systemctl is-active --quiet ${SERVICE_NAME}; then
        echo "- Stopping existing service"
        systemctl stop ${SERVICE_NAME}
    fi
    
    echo "- Reloading systemd configuration"
    systemctl daemon-reload
    
    echo "- Enabling service"
    systemctl enable ${SERVICE_NAME}.service
    
    echo "- Starting service"
    systemctl start ${SERVICE_NAME}.service
    
    # Verify service status
    if systemctl is-active --quiet ${SERVICE_NAME}; then
        echo "Service is running successfully"
    else
        echo "Warning: Service failed to start. Please check: systemctl status ${SERVICE_NAME}"
    fi
}

# Main installation process
check_dependencies
download_files
check_installation
backup_existing
install_files
manage_service

echo
if [ "$IS_UPDATE" = true ]; then
    echo "Update completed successfully!"
    echo "Previous installation backed up to: $BACKUP_DIR"
else
    echo "Installation completed successfully!"
fi

echo
echo "Monitoring and Management Commands:"
echo "--------------------------------"
echo "1. Monitor fan control logs in real-time:"
echo "   sudo tail -f /var/log/fan_control.log"
echo
echo "2. View service logs:"
echo "   sudo journalctl -fu ${SERVICE_NAME}    # Follow logs in real-time"
echo "   sudo journalctl -u ${SERVICE_NAME}     # Show all logs"
echo
echo "3. Check service status:"
echo "   sudo systemctl status ${SERVICE_NAME}"
echo
echo "4. Configuration:"
echo "   - Files located in: $INSTALL_DIR"
echo "   - Edit settings: sudo nano $INSTALL_DIR/config.env"
echo "   - Default template: $INSTALL_DIR/config.template.env"
echo "   - GPU monitoring settings:"
echo "     * Enable/disable: GPU_MONITORING=y/n"
echo "     * Temperature thresholds: GPU_MIN_TEMP, GPU_MAX_TEMP, GPU_FAIL_THRESHOLD"
echo "     * Fan IDs: GPU_FAN_IDS (comma-separated list, default: 5,6)"
echo "   - MQTT settings:"
echo "     * MQTT_BROKER: Hostname or IP of MQTT broker (leave empty to disable)"
echo "     * MQTT_PORT: Port of MQTT broker (default: 1883, TLS: 8883)"
echo "     * MQTT_USER/MQTT_PASS: Optional authentication credentials"
echo "     * MQTT_TLS: Enable TLS encryption (y/n)"
echo
echo "5. Service control:"
echo "   sudo systemctl stop ${SERVICE_NAME}     # Stop the service"
echo "   sudo systemctl start ${SERVICE_NAME}    # Start the service"
echo "   sudo systemctl restart ${SERVICE_NAME}  # Restart the service"

if [ "$IS_UPDATE" = true ]; then
    echo
    echo "Note: If you experience any issues with this update, you can restore"
    echo "      the backup from $BACKUP_DIR"
    echo
    echo "      Your current config.env has been saved as template:"
    echo "      $INSTALL_DIR/config.template.env"
    echo "      A new default configuration is available at:"
    echo "      $INSTALL_DIR/config.env.new"
    echo "      Compare them and update your config.env manually if needed."
fi
