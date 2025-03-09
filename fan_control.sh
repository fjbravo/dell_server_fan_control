#!/bin/bash

# Enable error tracing
set -x

# A simple bash script that uses lm_sensors to check CPU temps, and ipmitool to adjust fan speeds on iDRAC based systems.
#
# Logging functions
# Function for early logging (before log file is ready)
early_log() {
    local level="$1"
    local message="$2"
    local date_str=$(date +%d-%m-%Y\ %H:%M:%S)
    
    case "$level" in
        "ERROR")
            echo "$date_str ⚠ Error: $message" >&2
            ;;
        "WARNING")
            echo "$date_str ⚠ Warning: $message" >&2
            ;;
        "INFO")
            echo "$date_str ✓ $message" >&2
            ;;
        "CONFIG")
            echo "$date_str 🔧 Config: $message" >&2
            ;;
        "DEBUG")
            if [ "$DEBUG" = "y" ]; then
                echo "$date_str 🔍 DEBUG: $message" >&2
            fi
            ;;
    esac
    return 0
}

# Function for debug logging
debug_log() {
    if [ "$DEBUG" = "y" ]; then
        echo "$DATE 🔍 DEBUG: $1" >> $LOG_FILE
    fi
    return 0  # Always return success to avoid affecting $?
}

# Function for info logging
info_log() {
    echo "$DATE ✓ $1" >> $LOG_FILE
    return 0
}

# Function for warning logging
warn_log() {
    echo "$DATE ⚠ Warning: $1" >> $LOG_FILE
    return 0
}

# Function for error logging
error_log() {
    echo "$DATE ⚠ Error: $1" >> $LOG_FILE
    return 0
}

# Function for configuration logging
config_log() {
    echo "$DATE 🔧 Config: $1" >> $LOG_FILE
    return 0
}

# Function to validate temperature readings
is_valid_temp() {
    local temp="$1"
    local min="${2:-1}"  # Default min value is 1°C
    local max="${3:-99}" # Default max value is 99°C
    
    # Check if temp is a number and within range
    if [[ "$temp" =~ ^[0-9]+$ ]] && [ "$temp" -ge "$min" ] && [ "$temp" -le "$max" ]; then
        return 0  # Valid (success)
    else
        return 1  # Invalid (failure)
    fi
}
#
# Copyright (C) 2022  Milkysunshine
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.{{ project }}
#


# Get the directory where the script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Source configuration file (looking in the same directory as the script)
CONFIG_FILE="$SCRIPT_DIR/config.env"

# Check if config file exists and source it
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    early_log "ERROR" "Configuration file not found at $CONFIG_FILE"
    exit 1
fi






# Get system date & time for timestamp and logging
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
DATE=$(date +%d-%m-%Y\ %H:%M:%S)

# Create logs directory if it doesn't exist
LOG_DIR=$(dirname "$LOG_FILE")
if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
    early_log "ERROR" "Failed to create log directory: $LOG_DIR"
    exit 1
fi

# Ensure log directory is writable
if ! [ -w "$LOG_DIR" ]; then
    early_log "ERROR" "Log directory is not writable: $LOG_DIR"
    exit 1
fi

# Create new log file with timestamp
LOG_FILE_BASE=$(basename "$LOG_FILE")
LOG_FILE_NAME="${LOG_FILE_BASE%.*}"  # Remove extension if any
LOG_FILE_EXT="${LOG_FILE_BASE##*.}"  # Get extension if any
if [ "$LOG_FILE_NAME" = "$LOG_FILE_EXT" ]; then
    # No extension in original LOG_FILE
    NEW_LOG_FILE="$LOG_DIR/${LOG_FILE_NAME}_${TIMESTAMP}"
else
    # Has extension
    NEW_LOG_FILE="$LOG_DIR/${LOG_FILE_NAME}_${TIMESTAMP}.${LOG_FILE_EXT}"
fi
LOG_FILE="$NEW_LOG_FILE"

# Create symbolic link to latest log
LATEST_LOG="$LOG_DIR/latest_fan_control.log"
ln -sf "$LOG_FILE" "$LATEST_LOG"
# Start logging
config_log "Starting Dell IPMI fan control service..."
config_log "iDRAC IP = $IDRAC_IP"
config_log "iDRAC user = $IDRAC_USER"
config_log "Minimum fan speed = $FAN_MIN%"
config_log "CPU fan curve min point = ${CPU_MIN_TEMP}°C"
config_log "CPU fan curve max point = ${CPU_MAX_TEMP}°C"
config_log "CPU shutdown temp = ${CPU_TEMP_FAIL_THRESHOLD}°C"
config_log "GPU fan curve min point = ${GPU_MIN_TEMP}°C"
config_log "GPU fan curve max point = ${GPU_MAX_TEMP}°C"
config_log "GPU shutdown temp = ${GPU_TEMP_FAIL_THRESHOLD}°C"
config_log "GPU-specific fans = $GPU_FANS"
config_log "Degrees warmer before increasing fan speed = ${HYST_WARMING}°C"
config_log "Degrees cooler before decreasing fan speed = ${HYST_COOLING}°C"
config_log "Time between temperature checks = $LOOP_TIME seconds"
config_log "Current log file: $LOG_FILE"
config_log "Latest log symlink: $LATEST_LOG"
if [ "$DRY_RUN" = "y" ]; then
    config_log "DRY-RUN MODE ENABLED (fan changes will be logged but not executed)"
fi
# Function to check IPMI connectivity and initialize if needed
check_ipmi() {
    # Check if ipmitool exists
    if ! command -v ipmitool >/dev/null 2>&1; then
        early_log "ERROR" "'ipmitool' command not found. Please install ipmitool package."
        return 1
    fi

    # Basic connectivity test first
    if ! /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD chassis power status 2>/dev/null; then
        early_log "ERROR" "Cannot connect to IPMI. Check iDRAC settings:"
        early_log "ERROR" "  - IP: $IDRAC_IP"
        early_log "ERROR" "  - User: $IDRAC_USER"
        early_log "ERROR" "  - Password: [hidden]"
        early_log "ERROR" "  - Ensure IPMI over LAN is enabled in iDRAC"
        return 1
    fi

    # In dry-run mode, we still need to verify connectivity but won't make changes
    if [ "$DRY_RUN" = "y" ]; then
        early_log "INFO" "Dry-run mode: IPMI connectivity verified, skipping initialization"
        return 0
    fi

    # Enable IPMI LAN channel
    early_log "INFO" "Initializing IPMI LAN channel..."
    /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD lan set 1 access on >/dev/null 2>&1
    /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD lan set 1 privilege 4 >/dev/null 2>&1

    # Try to enable manual fan control
    early_log "INFO" "Attempting to enable manual fan control..."
    if ! /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD raw 0x30 0x30 0x01 0x00 2>/dev/null; then
        early_log "ERROR" "Cannot enable manual fan control. Check iDRAC user permissions."
        return 1
    fi

    # Disable 3rd Party PCIe Response
    early_log "INFO" "Disabling 3rd Party PCIe Response..."
    if ! /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD raw 0x30 0xce 0x00 0x16 0x05 0x00 0x00 0x00 2>/dev/null; then
        early_log "WARNING" "Failed to disable 3rd Party PCIe Response. Fan control may still work."
        # Not returning error as this is not critical for fan control
    fi

    # Verify we can read fan status
    if ! /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD sdr type fan >/dev/null 2>&1; then
        early_log "ERROR" "Cannot read fan status. IPMI configuration may be incorrect."
        return 1
    fi

    return 0
}

# Function to get GPU temperature
get_gpu_temp() {
    # Check if nvidia-smi command exists
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        early_log "ERROR" "'nvidia-smi' command not found. Please install NVIDIA drivers."
        return 1
    fi

    local temp
    temp=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null)
    
    # Check if we got a valid temperature reading
    if [ -z "$temp" ] || ! [[ "$temp" =~ ^[0-9]+$ ]]; then
        early_log "ERROR" "Could not read GPU temperature. Check if NVIDIA GPU is present and drivers are loaded."
        return 1
    fi
    
    echo "$temp"
    return 0
}

# Function to get CPU temperature
get_cpu_temp() {
    # Check if sensors command exists
    if ! command -v sensors >/dev/null 2>&1; then
        early_log "ERROR" "'sensors' command not found. Please install lm-sensors package."
        return 1
    fi

    # Check if sensors are detected
    if ! sensors >/dev/null 2>&1; then
        early_log "ERROR" "No sensors detected. Please run 'sensors-detect' as root."
        return 1
    fi

    local temp
    temp=$(sensors coretemp-isa-0000 coretemp-isa-0001 2>/dev/null | grep Package | cut -c17-18 | sort -n | tail -1)
    
    # Check if we got a valid temperature reading
    if [ -z "$temp" ]; then
        early_log "ERROR" "Could not read CPU temperature. Check if coretemp module is loaded."
        early_log "ERROR" "Available sensors (run 'sensors -A' for more details)"
        return 1
    fi
    
    echo "$temp"
    return 0
}

# Function to set fan speed for specific fans
# set_fan_speed() {
#     local fan_ids="$1"
#     local speed="$2"
#     local success=0
    
#     # Convert speed to hexadecimal
#     local hex_speed=$(printf '0x%02x' "$speed")
    
#     # Set speed for each fan ID
#     IFS=',' read -ra FAN_ARRAY <<< "$fan_ids"
#     for fan_id in "${FAN_ARRAY[@]}"; do
#         if ! /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD raw 0x30 0x30 0x02 "$fan_id" "$hex_speed" 2>/dev/null; then
#             error_log "Failed to set fan $fan_id speed to $speed%"
#             success=1
#         fi
#     done
    
#     return $success
# }

# Check IPMI connectivity first
if ! check_ipmi; then
    exit 1
fi

# Get initial CPU temperature
CPU_T=$(get_cpu_temp)
debug_log "Read Initial CPU temperature: ${CPU_T}°C"
if ! is_valid_temp "$CPU_T"; then
    error_log "Failed to read Initial CPU temperature or value out of range (${CPU_T}). Enabling stock Dell fan control."
    
    if [ "$DRY_RUN" = "y" ]; then
        debug_log "DRY-RUN: Would enable stock Dell fan control due to Initial CPU temperature read failure"
    else
        /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD raw 0x30 0x30 0x01 0x01 >> $LOG_FILE
    fi
    
    exit 1
fi

# Get initial GPU temperature (non-fatal if it fails)
GPU_T=$(get_gpu_temp)
debug_log "Read Initial GPU temperature: ${GPU_T}°C"
if ! is_valid_temp "$GPU_T"; then
    warn_log "Failed to read Initial GPU temperature or value out of range (${GPU_T}). Using CPU temperature for all fans."
    GPU_T=$CPU_T
    debug_log "Using CPU temperature (${CPU_T}°C) for GPU"
fi

# Ensure we have valid temperature readings
if is_valid_temp "$CPU_T" && is_valid_temp "$GPU_T"; then
   # Enable manual fan control and set fan PWM % via ipmitool
   info_log "Valid temperature readings - CPU: ${CPU_T}°C, GPU: ${GPU_T}°C. Enabling manual fan control."
   
   if [ "$DRY_RUN" = "y" ]; then
       debug_log "DRY-RUN: Would enable manual fan control"
   else
       /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD raw 0x30 0x30 0x01 0x00 > /dev/null
       info_log "Enabled dynamic fan control"
   fi
else
   error_log "Invalid temperature readings - CPU: ${CPU_T}°C, GPU: ${GPU_T}°C. Enabling stock Dell fan control."
   
   if [ "$DRY_RUN" = "y" ]; then
       debug_log "DRY-RUN: Would enable stock Dell fan control"
   else
       /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD raw 0x30 0x30 0x01 0x01 >> $LOG_FILE
   fi
   
   exit 0
fi

# Initialize variables
CPU_T_OLD=0
GPU_T_OLD=0
BASE_FAN_PERCENT=$FAN_MIN
GPU_EXTRA_PERCENT=0

# Function to set fan speed for all fans at once
set_all_fans_speed() {
    local speed="$1"
    local hex_speed=$(printf '0x%02x' $speed)
    
    # In dry-run mode, only log what would happen
    if [ "$DRY_RUN" = "y" ]; then
        debug_log "DRY-RUN: Would set all fans speed to $speed%"
        return 0
    fi
    
    # Sleep for 1 second before sending IPMI command
    sleep 1
    
    # Set speed for all fans with a single command
    if ! /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD raw 0x30 0x30 0x02 0xFF $hex_speed 2>/dev/null; then
        error_log "Failed to set all fans speed to $speed%"
        return 1
    fi
    return 0
}

# Function to set fan speed for specific fans
set_fan_speed() {
    local fan_list="$1"
    local speed="$2"
    local success_count=0
    local total_fans=0
    
    # Convert fan speed to hexadecimal
    local hex_speed=$(printf '0x%02x' $speed)
    
    # In dry-run mode, only log what would happen
    if [ "$DRY_RUN" = "y" ]; then
        debug_log "DRY-RUN: Would set fans $fan_list speed to $speed%"
        return 0
    fi
    
    # Sleep for 1 second before sending IPMI command
    sleep 1
    
    # Set speed for each fan in the list
    IFS=',' read -ra FANS <<< "$fan_list"
    for fan in "${FANS[@]}"; do
        total_fans=$((total_fans + 1))
        if /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD raw 0x30 0x30 0x02 $fan $hex_speed 2>/dev/null; then
            success_count=$((success_count + 1))
        else
            warn_log "Failed to set fan $fan speed to $speed%, continuing with other fans"
        fi
    done
    
    # Only return failure if all fans failed
    if [ $success_count -eq 0 ] && [ $total_fans -gt 0 ]; then
        error_log "Failed to set any GPU fans to $speed%"
        return 1
    fi
    
    # Return success if at least one fan was set successfully
    if [ $success_count -lt $total_fans ]; then
        warn_log "Set $success_count out of $total_fans GPU fans to $speed%"
    else
        debug_log "Successfully set all $total_fans GPU fans to $speed%"
    fi
    
    return 0
}

# Function to calculate fan speed based on temperature
calculate_fan_speed() {
    local temp="$1"
    local min_temp="$2"
    local max_temp="$3"
    local apply_min="${4:-y}"  # Optional parameter to apply FAN_MIN limit, defaults to "y"
    local fan_percent
    
    # First check if we're outside the temperature range
    if [ "$temp" -le "$min_temp" ]; then
        fan_percent=0
    elif [ "$temp" -ge "$max_temp" ]; then
        fan_percent=100
    else
        # Calculate percentage based on temperature range (linear interpolation)
        # Using integer arithmetic: ((temp - min_temp) * 100) / (max_temp - min_temp)
        local range=$((max_temp - min_temp))
        local temp_diff=$((temp - min_temp))
        local numerator=$((temp_diff * 100))
        fan_percent=$((numerator / range))
        
        # Ensure we get a valid percentage
        if [ "$fan_percent" -gt 100 ]; then
            fan_percent=100
        elif [ "$fan_percent" -lt 0 ]; then
            fan_percent=0
        fi
    fi
    
    # Apply minimum fan speed limit if requested
    if [ "$apply_min" = "y" ] && [ "$fan_percent" -lt "$FAN_MIN" ]; then
        fan_percent="$FAN_MIN"
    fi
    
    echo "$fan_percent"
}


# Function to validate configuration
validate_config() {
    local error_found=0
    
    # Check if all required variables are set
    local required_vars=(
        "IDRAC_IP" "IDRAC_USER" "IDRAC_PASSWORD"  # iDRAC settings
        "FAN_MIN"  # Fan settings
        "CPU_MIN_TEMP" "CPU_MAX_TEMP" "CPU_TEMP_FAIL_THRESHOLD"  # CPU temperature settings
        "GPU_MIN_TEMP" "GPU_MAX_TEMP" "GPU_TEMP_FAIL_THRESHOLD"  # GPU temperature settings
        "GPU_FANS"  # Fan zone settings
        "HYST_WARMING" "HYST_COOLING"  # Hysteresis settings
        "LOOP_TIME" "LOG_FREQUENCY" "LOG_FILE"  # Operational settings
    )
    
    for var in "${required_vars[@]}"; do
        if [ -z "${!var}" ]; then
            error_log "Required variable $var is not set"
            error_found=1
        fi
    done
    
    # Validate numeric values and ranges
    if ! [[ "$FAN_MIN" =~ ^[0-9]+$ ]] || [ "$FAN_MIN" -lt 0 ] || [ "$FAN_MIN" -gt 100 ]; then
        error_log "FAN_MIN must be between 0 and 100"
        error_found=1
    fi
    
    # Validate CPU temperature settings
    if ! [[ "$CPU_MIN_TEMP" =~ ^[0-9]+$ ]] || [ "$CPU_MIN_TEMP" -lt 0 ] || [ "$CPU_MIN_TEMP" -gt 100 ]; then
        error_log "CPU_MIN_TEMP must be between 0 and 100"
        error_found=1
    fi
    
    if ! [[ "$CPU_MAX_TEMP" =~ ^[0-9]+$ ]] || [ "$CPU_MAX_TEMP" -lt 0 ] || [ "$CPU_MAX_TEMP" -gt 100 ]; then
        error_log "CPU_MAX_TEMP must be between 0 and 100"
        error_found=1
    fi
    
    if [ "$CPU_MIN_TEMP" -ge "$CPU_MAX_TEMP" ]; then
        error_log "CPU_MIN_TEMP must be less than CPU_MAX_TEMP"
        error_found=1
    fi
    
    if [ "$CPU_TEMP_FAIL_THRESHOLD" -le "$CPU_MAX_TEMP" ]; then
        error_log "CPU_TEMP_FAIL_THRESHOLD must be greater than CPU_MAX_TEMP"
        error_found=1
    fi
    
    # Validate GPU temperature settings
    if ! [[ "$GPU_MIN_TEMP" =~ ^[0-9]+$ ]] || [ "$GPU_MIN_TEMP" -lt 0 ] || [ "$GPU_MIN_TEMP" -gt 100 ]; then
        error_log "GPU_MIN_TEMP must be between 0 and 100"
        error_found=1
    fi
    
    if ! [[ "$GPU_MAX_TEMP" =~ ^[0-9]+$ ]] || [ "$GPU_MAX_TEMP" -lt 0 ] || [ "$GPU_MAX_TEMP" -gt 100 ]; then
        error_log "GPU_MAX_TEMP must be between 0 and 100"
        error_found=1
    fi
    
    if [ "$GPU_MIN_TEMP" -ge "$GPU_MAX_TEMP" ]; then
        error_log "GPU_MIN_TEMP must be less than GPU_MAX_TEMP"
        error_found=1
    fi
    
    if [ "$GPU_TEMP_FAIL_THRESHOLD" -le "$GPU_MAX_TEMP" ]; then
        error_log "GPU_TEMP_FAIL_THRESHOLD must be greater than GPU_MAX_TEMP"
        error_found=1
    fi
    
    # Validate GPU fan settings
    if ! [[ "$GPU_FANS" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
        error_log "GPU_FANS must be a comma-separated list of fan numbers"
        error_found=1
    fi
    
    if ! [[ "$LOOP_TIME" =~ ^[0-9]+$ ]] || [ "$LOOP_TIME" -lt 1 ]; then
        error_log "LOOP_TIME must be a positive integer"
        error_found=1
    fi
    
    if ! [[ "$LOG_FREQUENCY" =~ ^[0-9]+$ ]] || [ "$LOG_FREQUENCY" -lt 1 ]; then
        error_log "LOG_FREQUENCY must be a positive integer"
        error_found=1
    fi
    
    # Validate iDRAC IP format
    if ! [[ "$IDRAC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        error_log "IDRAC_IP must be a valid IP address"
        error_found=1
    fi
    
    # Validate DRY_RUN setting
    if [ -n "$DRY_RUN" ] && [ "$DRY_RUN" != "y" ] && [ "$DRY_RUN" != "n" ]; then
        warn_log "Invalid DRY_RUN value '$DRY_RUN'. Must be 'y' or 'n'. Defaulting to 'n'."
        DRY_RUN="n"  # Default to normal operation
        # Not incrementing error_found since this shouldn't stop the program
    fi
    
    # Validate GPU settings if GPU monitoring is enabled
    if [ "$GPU_MONITORING" = "y" ]; then
        # Check if all GPU variables are set
        local gpu_vars=(
            "GPU_MIN_TEMP" "GPU_MAX_TEMP" "GPU_FAIL_THRESHOLD"  # Temperature settings
            "GPU_HYST_WARMING" "GPU_HYST_COOLING"  # Hysteresis settings
            "GPU_FAN_IDS"  # Fan IDs
        )
        
        for var in "${gpu_vars[@]}"; do
            if [ -z "${!var}" ]; then
                error_log "Required GPU variable $var is not set"
                error_found=1
            fi
        done
        
        # Validate GPU temperature ranges
        if ! [[ "$GPU_MIN_TEMP" =~ ^[0-9]+$ ]] || [ "$GPU_MIN_TEMP" -lt 0 ] || [ "$GPU_MIN_TEMP" -gt 100 ]; then
            error_log "GPU_MIN_TEMP must be between 0 and 100"
            error_found=1
        fi
        
        if ! [[ "$GPU_MAX_TEMP" =~ ^[0-9]+$ ]] || [ "$GPU_MAX_TEMP" -lt 0 ] || [ "$GPU_MAX_TEMP" -gt 100 ]; then
            error_log "GPU_MAX_TEMP must be between 0 and 100"
            error_found=1
        fi
        
        if [ "$GPU_MIN_TEMP" -ge "$GPU_MAX_TEMP" ]; then
            error_log "GPU_MIN_TEMP must be less than GPU_MAX_TEMP"
            error_found=1
        fi
        
        if [ "$GPU_FAIL_THRESHOLD" -le "$GPU_MAX_TEMP" ]; then
            error_log "GPU_FAIL_THRESHOLD must be greater than GPU_MAX_TEMP"
            error_found=1
        fi
        
        # Validate GPU fan IDs format (comma-separated numbers)
        if ! [[ "$GPU_FAN_IDS" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
            error_log "GPU_FAN_IDS must be comma-separated numbers"
            error_found=1
        fi
    fi
    
    return $error_found
}

# Function to safely get file modification time
get_mod_time() {
    local mod_time
    if ! mod_time=$(stat -c %Y "$CONFIG_FILE" 2>/dev/null); then
        error_log "Cannot read modification time of $CONFIG_FILE"
        return 1
    fi
    echo "$mod_time"
    return 0
}

# Validate initial configuration
if ! validate_config; then
    error_log "Initial configuration is invalid. Please check config.env"
    exit 1
fi

# Get initial config file modification time
if ! LAST_MOD_TIME=$(get_mod_time); then
    error_log "Cannot access config file. Using default settings."
    LAST_MOD_TIME=0
fi

# Function to check if config has changed and reload if needed
check_and_reload_config() {
    local current_mod_time
    
    # Check if config file exists and is readable
    if [ ! -f "$CONFIG_FILE" ] || [ ! -r "$CONFIG_FILE" ]; then
        error_log "Config file $CONFIG_FILE is not accessible"
        return 1
    fi
    
    # Get current modification time
    if ! current_mod_time=$(get_mod_time); then
        return 1
    fi
    
    if [ "$current_mod_time" != "$LAST_MOD_TIME" ]; then
        config_log "Configuration file changed, reloading settings..."
        
        # Create a temporary file for the new configuration
        local temp_config
        temp_config=$(mktemp)
        if [ ! -f "$temp_config" ]; then
            error_log "Cannot create temporary file for config validation"
            return 1
        fi
        
        # Copy current environment variables that we want to preserve
        declare -p > "$temp_config"
        
        # Source the new config file
        if ! source "$CONFIG_FILE"; then
            error_log "Failed to load new configuration"
            rm -f "$temp_config"
            return 1
        fi
        
        # Validate the new configuration
        if ! validate_config; then
            error_log "New configuration is invalid. Reverting to previous settings."
            source "$temp_config"
            rm -f "$temp_config"
            return 1
        fi
        
        # Clean up and update modification time
        rm -f "$temp_config"
        LAST_MOD_TIME=$current_mod_time
        config_log "Configuration reloaded successfully"
    fi
}

# Initialize variables
CPU_T_OLD=0
GPU_T_OLD=0
BASE_FAN_PERCENT=$FAN_MIN
GPU_EXTRA_PERCENT=0

# Beginning of monitoring and control loop
   # Debug: Log current settings at start of loop
   debug_log "Settings - FAN_MIN: $FAN_MIN%, CPU_MIN_TEMP: ${CPU_MIN_TEMP}°C, CPU_MAX_TEMP: ${CPU_MAX_TEMP}°C, GPU_MIN_TEMP: ${GPU_MIN_TEMP}°C, GPU_MAX_TEMP: ${GPU_MAX_TEMP}°C"
   debug_log "Previous state - CPU_OLD: ${CPU_T_OLD}°C, GPU_OLD: ${GPU_T_OLD}°C, BASE_FAN: ${BASE_FAN_PERCENT}%, GPU_EXTRA: ${GPU_EXTRA_PERCENT}%"
while true; do
   DATE=$(date +%H:%M:%S)
   
   # Check if config file has changed
   check_and_reload_config

   # Get CPU temperature
   CPU_T=$(get_cpu_temp)
   debug_log "Read CPU temperature: ${CPU_T}°C"
   if ! is_valid_temp "$CPU_T"; then
       error_log "Failed to read CPU temperature or value out of range (${CPU_T}). Enabling stock Dell fan control."
       
       if [ "$DRY_RUN" = "y" ]; then
           debug_log "DRY-RUN: Would enable stock Dell fan control due to CPU temperature read failure"
       else
           /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD raw 0x30 0x30 0x01 0x01 2>/dev/null
       fi
       
       exit 1
   fi

   # Get GPU temperature
   GPU_T=$(get_gpu_temp)
   debug_log "Read GPU temperature: ${GPU_T}°C"
   if ! is_valid_temp "$GPU_T"; then
       warn_log "Failed to read GPU temperature or value out of range (${GPU_T}). Using CPU temperature for all fans."
       GPU_T=$CPU_T
       debug_log "Using CPU temperature (${CPU_T}°C) for GPU"
   fi
   
   # Validate temperature readings
   debug_log "Checking if temperature readings are valid (CPU: ${CPU_T}°C, GPU: ${GPU_T}°C)"
   if is_valid_temp "$CPU_T" && is_valid_temp "$GPU_T"; then
      # Check for critical temperature thresholds
      if [ "$CPU_T" -ge $CPU_TEMP_FAIL_THRESHOLD ]; then
         error_log "CRITICAL!!!! CPU Temperature ${CPU_T}°C exceeds shutdown threshold of ${CPU_TEMP_FAIL_THRESHOLD}°C"
         error_log "INITIATING EMERGENCY SHUTDOWN"
         /usr/sbin/shutdown now
         exit 0
      fi
      
      if [ "$GPU_T" -ge $GPU_TEMP_FAIL_THRESHOLD ]; then
         error_log "CRITICAL!!!! GPU Temperature ${GPU_T}°C exceeds shutdown threshold of ${GPU_TEMP_FAIL_THRESHOLD}°C"
         error_log "INITIATING EMERGENCY SHUTDOWN"
         /usr/sbin/shutdown now
         exit 0
      fi
      
      # Calculate temperature changes for hysteresis
      CPU_CHANGE_COOLING=$((CPU_T_OLD-CPU_T))
      CPU_CHANGE_WARMING=$((CPU_T-CPU_T_OLD))
      GPU_CHANGE_COOLING=$((GPU_T_OLD-GPU_T))
      GPU_CHANGE_WARMING=$((GPU_T-GPU_T_OLD))
      
      debug_log "Temperature changes:"
      debug_log "CPU - Cooling: ${CPU_CHANGE_COOLING}°C, Warming: ${CPU_CHANGE_WARMING}°C (threshold: ${HYST_COOLING}°C, ${HYST_WARMING}°C)"
      debug_log "GPU - Cooling: ${GPU_CHANGE_COOLING}°C, Warming: ${GPU_CHANGE_WARMING}°C (threshold: ${HYST_COOLING}°C, ${HYST_WARMING}°C)"

      # Check if temperature changes exceed hysteresis thresholds
      if [ $((CPU_T_OLD-CPU_T)) -ge $HYST_COOLING ] || [ $((CPU_T-CPU_T_OLD)) -ge $HYST_WARMING ] || \
         [ $((GPU_T_OLD-GPU_T)) -ge $HYST_COOLING ] || [ $((GPU_T-GPU_T_OLD)) -ge $HYST_WARMING ]; then
         
         debug_log "Temperature change exceeds hysteresis threshold"
         info_log "Temperature change detected (CPU: ${CPU_T}°C, GPU: ${GPU_T}°C)"
         
         # Update last temperatures for future comparisons
         CPU_T_OLD=$CPU_T
         GPU_T_OLD=$GPU_T
         
         # Calculate base fan speed from CPU temperature (applies to all fans)
         BASE_FAN_PERCENT=$(calculate_fan_speed "$CPU_T" "$CPU_MIN_TEMP" "$CPU_MAX_TEMP")
         
         # Calculate GPU fan speed without applying FAN_MIN limit
         gpu_required_percent=$(calculate_fan_speed "$GPU_T" "$GPU_MIN_TEMP" "$GPU_MAX_TEMP" "n")
         debug_log "Raw GPU fan speed calculation: ${gpu_required_percent}% (temp: ${GPU_T}°C, range: ${GPU_MIN_TEMP}°C-${GPU_MAX_TEMP}°C)"
         
         # Calculate extra cooling needed for GPU
         if [ "$GPU_T" -gt "$GPU_MIN_TEMP" ]; then
            debug_log "GPU temp ${GPU_T}°C > min temp ${GPU_MIN_TEMP}°C, calculating extra cooling"
            
            # Calculate extra cooling needed - FIX: Check if gpu_required_percent is set and is a number
            if [ -n "$gpu_required_percent" ] && [ "$gpu_required_percent" -gt 0 ]; then
                # Start with the raw GPU fan speed
                GPU_EXTRA_PERCENT="$gpu_required_percent"
                debug_log "Starting with raw GPU fan speed: ${GPU_EXTRA_PERCENT}%"
                
                # Subtract base fan speed to get the extra cooling needed
                if [ "$BASE_FAN_PERCENT" -gt 0 ]; then
                    GPU_EXTRA_PERCENT=$((GPU_EXTRA_PERCENT - BASE_FAN_PERCENT))
                    debug_log "After subtracting base fan speed: ${gpu_required_percent}% - ${BASE_FAN_PERCENT}% = ${GPU_EXTRA_PERCENT}%"
                fi
                
                # Ensure extra cooling is at least 0
                if [ "$GPU_EXTRA_PERCENT" -lt 0 ]; then
                    debug_log "Extra cooling was negative, setting to 0%"
                    GPU_EXTRA_PERCENT=0
                fi
            else
                debug_log "No extra cooling needed (required: ${gpu_required_percent}%)"
                GPU_EXTRA_PERCENT=0
            fi
         else
            debug_log "GPU temp ${GPU_T}°C <= min temp ${GPU_MIN_TEMP}°C, no extra cooling needed"
            GPU_EXTRA_PERCENT=0
         fi
         
         # Periodic manual control check (every 10 cycles)
         if [ "$CONTROL" -eq 10 ]; then
            CONTROL=0
            if [ "$DRY_RUN" = "y" ]; then
                debug_log "DRY-RUN: Would verify manual fan control"
            else
                /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD raw 0x30 0x30 0x01 0x00 > /dev/null
                info_log "Manual fan control verified"
            fi
         else
            CONTROL=$(( CONTROL + 1 ))
         fi
         
         # Set base speed for all fans with a single command
         debug_log "Setting base fan speed for all fans to ${BASE_FAN_PERCENT}%"
         if ! set_all_fans_speed "$BASE_FAN_PERCENT"; then
             error_log "Failed to set base fan speeds. Enabling stock Dell fan control."
             
             if [ "$DRY_RUN" = "y" ]; then
                 debug_log "DRY-RUN: Would enable stock Dell fan control due to fan speed setting failure"
             else
                 /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD raw 0x30 0x30 0x01 0x01 2>/dev/null
             fi
             
             exit 1
         fi
         
         # If GPU needs extra cooling, increase GPU fan speeds - FIX: Check if GPU_EXTRA_PERCENT is set and is a number
         if [ -n "$GPU_EXTRA_PERCENT" ] && [ "$GPU_EXTRA_PERCENT" -gt 0 ]; then
             gpu_final_percent=$((BASE_FAN_PERCENT + GPU_EXTRA_PERCENT))
             if [ "$gpu_final_percent" -gt 100 ]; then
                gpu_final_percent=100
             fi
             debug_log "Setting GPU fans (${GPU_FANS}) to ${gpu_final_percent}% (base ${BASE_FAN_PERCENT}% + extra ${GPU_EXTRA_PERCENT}%)"
             
             if ! set_fan_speed "$GPU_FANS" "$gpu_final_percent"; then
                 error_log "Failed to set GPU fan speeds. Enabling stock Dell fan control."
                 
                 if [ "$DRY_RUN" = "y" ]; then
                     debug_log "DRY-RUN: Would enable stock Dell fan control due to GPU fan speed setting failure"
                 else
                     /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD raw 0x30 0x30 0x01 0x01 2>/dev/null
                 fi
                 
                 exit 1
             fi
             info_log "Updated - CPU Temp: ${CPU_T}°C (All Fans: ${BASE_FAN_PERCENT}%), GPU Temp: ${GPU_T}°C (GPU Fans: +${GPU_EXTRA_PERCENT}% = ${gpu_final_percent}%)"
         else
             info_log "Updated - CPU Temp: ${CPU_T}°C (All Fans: ${BASE_FAN_PERCENT}%), GPU Temp: ${GPU_T}°C (No extra cooling needed)"
         fi
      else
         # Log based on LOG_FREQUENCY or if DEBUG is enabled
         if [ "$DEBUG" = "y" ] || [ "$((CONTROL % LOG_FREQUENCY))" -eq 0 ]; then
            if [ "$GPU_EXTRA_PERCENT" -gt 0 ]; then
                gpu_final_percent=$((BASE_FAN_PERCENT + GPU_EXTRA_PERCENT))
                info_log "System stable - CPU Temp: ${CPU_T}°C (All Fans: ${BASE_FAN_PERCENT}%), GPU Temp: ${GPU_T}°C (GPU Fans: +${GPU_EXTRA_PERCENT}% = ${gpu_final_percent}%)"
            else
                info_log "System stable - CPU Temp: ${CPU_T}°C (All Fans: ${BASE_FAN_PERCENT}%), GPU Temp: ${GPU_T}°C (No extra cooling needed)"
            fi
         fi
      fi
   else
      # Error handling: Invalid temperature reading
      error_log "Invalid temperature reading (CPU: ${CPU_T}°C, GPU: ${GPU_T}°C). Reverting to stock Dell fan control"
      
      if [ "$DRY_RUN" = "y" ]; then
          debug_log "DRY-RUN: Would enable stock Dell fan control due to invalid temperature readings"
      else
          /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD raw 0x30 0x30 0x01 0x01 >> $LOG_FILE
      fi
      
      exit 0
   fi
   
   # Sleep for configured interval
   sleep $LOOP_TIME
done
