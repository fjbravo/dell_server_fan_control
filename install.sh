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
    for file in fan_control.sh shutdown_fan_control.sh dell_ipmi_fan_control.service; do
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
        mkdir -p "$BACKUP_DIR"
        
        if [ -d "$INSTALL_DIR" ]; then
            cp -r "$INSTALL_DIR" "$BACKUP_DIR/"
            echo "- Backed up scripts directory"
        fi
        
        if [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]; then
            cp "/etc/systemd/system/${SERVICE_NAME}.service" "$BACKUP_DIR/"
            echo "- Backed up service file"
        fi
        
        echo "Backup created at: $BACKUP_DIR"
        
        # Preserve user settings
        if [ -f "$INSTALL_DIR/fan_control.sh" ]; then
            echo "Preserving existing user settings..."
            TEMP_SETTINGS=$(mktemp)
            grep -E '^[[:space:]]*(MIN_TEMP|MAX_TEMP|FAN_MIN|HYST_TEMP|HYST_LEVEL|CHECK_INTERVAL|DEBUG)=' "$INSTALL_DIR/fan_control.sh" > "$TEMP_SETTINGS" || true
            
            if [ -s "$TEMP_SETTINGS" ]; then
                echo "- Found user settings, will restore after update"
            else
                echo "- No custom settings found"
                rm "$TEMP_SETTINGS"
                TEMP_SETTINGS=""
            fi
        fi
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
    
    # Restore user settings if updating
    if [ -n "$TEMP_SETTINGS" ] && [ -f "$TEMP_SETTINGS" ]; then
        echo "Restoring user settings..."
        while IFS= read -r setting; do
            variable=$(echo "$setting" | cut -d'=' -f1 | tr -d '[:space:]')
            value=$(echo "$setting" | cut -d'=' -f2)
            sed -i "s/^[[:space:]]*$variable=.*/$variable=$value/" "$INSTALL_DIR/fan_control.sh"
        done < "$TEMP_SETTINGS"
        rm "$TEMP_SETTINGS"
        echo "- User settings restored"
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