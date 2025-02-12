#!/bin/bash

# Exit on error
set -e

INSTALL_DIR="/usr/local/bin/dell-fan-control"
SERVICE_NAME="dell_ipmi_fan_control"
BACKUP_DIR="/tmp/dell-fan-control-backup-$(date +%Y%m%d_%H%M%S)"
TEMP_DIR="/tmp/dell-fan-control-install"
REPO_URL="https://raw.githubusercontent.com/fjbravo/dell_server_fan_control/feature/add-installation-script"
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
    
    # Install missing dependencies if any
    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo "Installing missing dependencies: ${missing_deps[*]}"
        apt-get update
        apt-get install -y "${missing_deps[@]}"
        echo "Dependencies installation completed"
    else
        echo "All required dependencies are already installed"
    fi
}

# Function to download required files
download_files() {
    echo "Step 2: Downloading latest files..."
    mkdir -p "$TEMP_DIR"
    cd "$TEMP_DIR" || exit 1
    
    # Download required files
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
    
    # Make scripts executable
    chmod +x fan_control.sh shutdown_fan_control.sh
    cd - > /dev/null || exit 1
    echo "All files downloaded successfully"
}

# Function to check existing installation
check_installation() {
    echo "Step 3: Checking for existing installation..."
    if [ -d "$INSTALL_DIR" ] || [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]; then
        echo "Existing installation found"
        IS_UPDATE=true
        return 0
    else
        echo "No existing installation found"
        return 1
    fi
}

# Function to backup existing installation
backup_existing() {
    echo "Step 4: Processing existing installation..."
    if [ "$IS_UPDATE" = true ]; then
        echo "Creating backup..."
        mkdir -p "$BACKUP_DIR/scripts"
        
        # Backup scripts but exclude config file
        if [ -d "$INSTALL_DIR" ]; then
            cp "$INSTALL_DIR/fan_control.sh" "$INSTALL_DIR/shutdown_fan_control.sh" "$BACKUP_DIR/scripts/" 2>/dev/null || true
            echo "- Backed up script files"
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
    
    # Copy files
    cp "$TEMP_DIR/fan_control.sh" "$INSTALL_DIR/"
    cp "$TEMP_DIR/shutdown_fan_control.sh" "$INSTALL_DIR/"
    cp "$TEMP_DIR/dell_ipmi_fan_control.service" /etc/systemd/system/
    
    # Handle config file
    if [ "$IS_UPDATE" = true ]; then
        echo "Processing configuration update..."
        if [ -f "$INSTALL_DIR/config.env" ]; then
            # Create temporary files
            MERGED_CONFIG=$(mktemp)
            if [ ! -f "$MERGED_CONFIG" ]; then
                echo "Error: Failed to create temporary file for config merging"
                exit 1
            fi
            
            # Get list of variables from new config
            echo "- Checking for new configuration options..."
            if ! grep -oP '^[A-Za-z_]+=.*$' "$TEMP_DIR/config.env" > /dev/null; then
                echo "Error: New configuration file appears to be empty or invalid"
                rm -f "$MERGED_CONFIG"
                exit 1
            fi
            
            # Process each variable
            grep -oP '^[A-Za-z_]+=.*$' "$TEMP_DIR/config.env" | cut -d'=' -f1 | while read -r VAR; do
                # If variable exists in old config, use that value
                if grep -q "^${VAR}=" "$INSTALL_DIR/config.env"; then
                    echo "- Preserving existing setting: ${VAR}"
                    grep "^${VAR}=" "$INSTALL_DIR/config.env" >> "$MERGED_CONFIG"
                else
                    echo "- Adding new setting: ${VAR}"
                    grep "^${VAR}=" "$TEMP_DIR/config.env" >> "$MERGED_CONFIG"
                fi
            done
            
            # Verify merged config has content
            if [ ! -s "$MERGED_CONFIG" ]; then
                echo "Error: Failed to merge configurations"
                rm -f "$MERGED_CONFIG"
                exit 1
            fi
            
            # Backup old config
            cp "$INSTALL_DIR/config.env" "$BACKUP_DIR/config.env.old"
            echo "- Backed up old configuration to: $BACKUP_DIR/config.env.old"
            
            # Merge configs while preserving structure and comments
            echo "- Updating configuration structure..."
            TEMP_FINAL=$(mktemp)
            while IFS= read -r line; do
                if [[ "$line" =~ ^[A-Za-z_]+= ]]; then
                    # For variable lines, get the variable name
                    var_name=$(echo "$line" | cut -d'=' -f1)
                    # Check if we have this variable in merged config
                    if grep -q "^${var_name}=" "$MERGED_CONFIG"; then
                        grep "^${var_name}=" "$MERGED_CONFIG" >> "$TEMP_FINAL"
                    else
                        echo "$line" >> "$TEMP_FINAL"
                    fi
                else
                    # For comments and empty lines, copy as is
                    echo "$line" >> "$TEMP_FINAL"
                fi
            done < "$TEMP_DIR/config.env"
            
            # Install the merged config
            mv "$TEMP_FINAL" "$INSTALL_DIR/config.env"
            
            # Cleanup
            rm "$MERGED_CONFIG"
            echo "✓ Configuration updated successfully"
            echo "- Review $INSTALL_DIR/config.env for any new options"
        else
            echo "! No existing config found, installing default configuration..."
            cp "$TEMP_DIR/config.env" "$INSTALL_DIR/"
        fi
    else
        echo "Installing default configuration..."
        cp "$TEMP_DIR/config.env" "$INSTALL_DIR/"
        echo "- Default configuration installed"
        echo "- Please edit $INSTALL_DIR/config.env to set your iDRAC credentials and preferences"
    fi
    
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
echo
echo "5. Service control:"
echo "   sudo systemctl stop ${SERVICE_NAME}     # Stop the service"
echo "   sudo systemctl start ${SERVICE_NAME}    # Start the service"
echo "   sudo systemctl restart ${SERVICE_NAME}  # Restart the service"

if [ "$IS_UPDATE" = true ]; then
    echo
    echo "Note: If you experience any issues with this update, you can restore"
    echo "      the backup from $BACKUP_DIR"
fi