#!/bin/bash

# Enable error tracing
set -x

# A simple bash script that uses lm_sensors to check CPU temps, and ipmitool to adjust fan speeds on iDRAC based systems.
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
    echo "Error: Configuration file not found at $CONFIG_FILE"
    exit 1
fi






# Get system date & time for timestamp and logging
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
DATE=$(date +%d-%m-%Y\ %H:%M:%S)

# Create logs directory if it doesn't exist
LOG_DIR=$(dirname "$LOG_FILE")
if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
    echo "Error: Failed to create log directory: $LOG_DIR" >&2
    exit 1
fi

# Ensure log directory is writable
if ! [ -w "$LOG_DIR" ]; then
    echo "Error: Log directory is not writable: $LOG_DIR" >&2
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
echo "Date $DATE --- Starting Dell IPMI fan control service...">> $LOG_FILE
echo "Date $DATE --- iDRAC IP = "$IDRAC_IP"">> $LOG_FILE
echo "Date $DATE --- iDRAC user = "$IDRAC_USER"">> $LOG_FILE
echo "Date $DATE --- Minimum fan speed = "$FAN_MIN"%">> $LOG_FILE
echo "Date $DATE --- CPU fan curve min point = "$CPU_MIN_TEMP"c">> $LOG_FILE
echo "Date $DATE --- CPU fan curve max point = "$CPU_MAX_TEMP"c">> $LOG_FILE
echo "Date $DATE --- CPU shutdown temp = "$CPU_TEMP_FAIL_THRESHOLD"c">> $LOG_FILE
echo "Date $DATE --- GPU fan curve min point = "$GPU_MIN_TEMP"c">> $LOG_FILE
echo "Date $DATE --- GPU fan curve max point = "$GPU_MAX_TEMP"c">> $LOG_FILE
echo "Date $DATE --- GPU shutdown temp = "$GPU_TEMP_FAIL_THRESHOLD"c">> $LOG_FILE
echo "Date $DATE --- GPU-specific fans = "$GPU_FANS"">> $LOG_FILE
echo "Date $DATE --- Degrees warmer before increasing fan speed = "$HYST_WARMING"c">> $LOG_FILE
echo "Date $DATE --- Degrees cooler before decreasing fan speed = "$HYST_COOLING"c">> $LOG_FILE
echo "Date $DATE --- Time between temperature checks = "$LOOP_TIME" seconds">> $LOG_FILE
echo "Date $DATE --- Current log file: $LOG_FILE">> $LOG_FILE
echo "Date $DATE --- Latest log symlink: $LATEST_LOG">> $LOG_FILE
# Function to check IPMI connectivity and initialize if needed
check_ipmi() {
    # Check if ipmitool exists
    if ! command -v ipmitool >/dev/null 2>&1; then
        echo "Error: 'ipmitool' command not found. Please install ipmitool package." >&2
        return 1
    fi

    # Basic connectivity test first
    if ! /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD chassis power status 2>/dev/null; then
        echo "Error: Cannot connect to IPMI. Check iDRAC settings:" >&2
        echo "  - IP: $IDRAC_IP" >&2
        echo "  - User: $IDRAC_USER" >&2
        echo "  - Password: [hidden]" >&2
        echo "  - Ensure IPMI over LAN is enabled in iDRAC" >&2
        return 1
    fi

    # Enable IPMI LAN channel
    echo "Initializing IPMI LAN channel..." >&2
    /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD lan set 1 access on >/dev/null 2>&1
    /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD lan set 1 privilege 4 >/dev/null 2>&1

    # Try to enable manual fan control
    echo "Attempting to enable manual fan control..." >&2
    if ! /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD raw 0x30 0x30 0x01 0x00 2>/dev/null; then
        echo "Error: Cannot enable manual fan control. Check iDRAC user permissions." >&2
        return 1
    fi

    # Verify we can read fan status
    if ! /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD sdr type fan >/dev/null 2>&1; then
        echo "Error: Cannot read fan status. IPMI configuration may be incorrect." >&2
        return 1
    fi

    return 0
}

# Function to get GPU temperature
get_gpu_temp() {
    # Check if nvidia-smi command exists
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        echo "Error: 'nvidia-smi' command not found. Please install NVIDIA drivers." >&2
        return 1
    fi

    local temp
    temp=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null)
    
    # Check if we got a valid temperature reading
    if [ -z "$temp" ] || ! [[ "$temp" =~ ^[0-9]+$ ]]; then
        echo "Error: Could not read GPU temperature. Check if NVIDIA GPU is present and drivers are loaded." >&2
        return 1
    fi
    
    echo "$temp"
    return 0
}

# Function to get CPU temperature
get_cpu_temp() {
    # Check if sensors command exists
    if ! command -v sensors >/dev/null 2>&1; then
        echo "Error: 'sensors' command not found. Please install lm-sensors package." >&2
        return 1
    fi

    # Check if sensors are detected
    if ! sensors >/dev/null 2>&1; then
        echo "Error: No sensors detected. Please run 'sensors-detect' as root." >&2
        return 1
    fi

    local temp
    temp=$(sensors coretemp-isa-0000 coretemp-isa-0001 2>/dev/null | grep Package | cut -c17-18 | sort -n | tail -1)
    
    # Check if we got a valid temperature reading
    if [ -z "$temp" ]; then
        echo "Error: Could not read CPU temperature. Check if coretemp module is loaded." >&2
        echo "Available sensors:" >&2
        sensors -A >&2
        return 1
    fi
    
    echo "$temp"
    return 0
}

# Check IPMI connectivity first
if ! check_ipmi; then
    exit 1
fi

# Get initial CPU temperature
CPU_T=$(get_cpu_temp)
   [ "$DEBUG" = "y" ] && echo "$DATE 🔍 DEBUG: Read CPU temperature: ${CPU_T}°C" >> $LOG_FILE
if [ $? -ne 0 ]; then
    echo "$DATE ⚠ Error: Failed to read CPU temperature. Enabling stock Dell fan control." >> $LOG_FILE
    /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD raw 0x30 0x30 0x01 0x01 >> $LOG_FILE
    exit 1
fi

# Get initial GPU temperature (non-fatal if it fails)
GPU_T=$(get_gpu_temp)
if [ $? -ne 0 ]; then
    echo "$DATE ⚠ Warning: Failed to read GPU temperature. Using CPU temperature for all fans." >> $LOG_FILE
    GPU_T=$CPU_T
   [ "$DEBUG" = "y" ] && echo "$DATE 🔍 DEBUG: Read GPU temperature: ${GPU_T}°C" >> $LOG_FILE
fi

# Ensure we have valid temperature readings
if [ "$CPU_T" -ge 1 ] && [ "$CPU_T" -le 99 ] && [ "$GPU_T" -ge 1 ] && [ "$GPU_T" -le 99 ]; then
   # Enable manual fan control and set fan PWM % via ipmitool
   echo "$DATE ✓ Valid temperature readings - CPU: ${CPU_T}°C, GPU: ${GPU_T}°C. Enabling manual fan control." >> $LOG_FILE
   /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD raw 0x30 0x30 0x01 0x00 > /dev/null
   echo "$DATE ✓ Enabled dynamic fan control" >> $LOG_FILE
else
   echo "$DATE ⚠ Error: Invalid temperature readings - CPU: ${CPU_T}°C, GPU: ${GPU_T}°C. Enabling stock Dell fan control." >> $LOG_FILE
   /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD raw 0x30 0x30 0x01 0x01 >> $LOG_FILE
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
    
    # Sleep for 1 second before sending IPMI command
    sleep 1
    
    # Set speed for all fans with a single command
    if ! /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD raw 0x30 0x30 0x02 0xFF $hex_speed 2>/dev/null; then
        echo "$DATE ⚠ Error: Failed to set all fans speed to $speed%" >&2
        return 1
    fi
    return 0
}

# Function to set fan speed for specific fans
set_fan_speed() {
    local fan_list="$1"
    local speed="$2"
    local success=0
    
    # Convert fan speed to hexadecimal
    local hex_speed=$(printf '0x%02x' $speed)
    
    # Sleep for 1 second before sending IPMI command
    sleep 1
    
    # Set speed for each fan in the list
    IFS=',' read -ra FANS <<< "$fan_list"
    for fan in "${FANS[@]}"; do
        if ! /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD raw 0x30 0x30 0x02 $fan $hex_speed 2>/dev/null; then
            echo "$DATE ⚠ Error: Failed to set fan $fan speed to $speed%" >&2
            success=1
        fi
    done
    
    return $success
}

# Function to calculate fan speed based on temperature
calculate_fan_speed() {
    local temp="$1"
    local min_temp="$2"
    local max_temp="$3"
    
    # Calculate percentage based on temperature range (linear interpolation)
    local fan_percent=`echo "$temp" "$min_temp" "$max_temp" | awk '{printf "%d\n", (($1-$2)/($3-$2))*100}'`
    
    # Apply fan speed limits
    if [ "$fan_percent" -lt "$FAN_MIN" ]; then
        fan_percent="$FAN_MIN"
    elif [ "$fan_percent" -gt 100 ]; then
        fan_percent="100"
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
            echo "$DATE ⚠ Error: Required variable $var is not set" >&2
            error_found=1
        fi
    done
    
    # Validate numeric values and ranges
    if ! [[ "$FAN_MIN" =~ ^[0-9]+$ ]] || [ "$FAN_MIN" -lt 0 ] || [ "$FAN_MIN" -gt 100 ]; then
        echo "$DATE ⚠ Error: FAN_MIN must be between 0 and 100" >&2
        error_found=1
    fi
    
    # Validate CPU temperature settings
    if ! [[ "$CPU_MIN_TEMP" =~ ^[0-9]+$ ]] || [ "$CPU_MIN_TEMP" -lt 0 ] || [ "$CPU_MIN_TEMP" -gt 100 ]; then
        echo "$DATE ⚠ Error: CPU_MIN_TEMP must be between 0 and 100" >&2
        error_found=1
    fi
    
    if ! [[ "$CPU_MAX_TEMP" =~ ^[0-9]+$ ]] || [ "$CPU_MAX_TEMP" -lt 0 ] || [ "$CPU_MAX_TEMP" -gt 100 ]; then
        echo "$DATE ⚠ Error: CPU_MAX_TEMP must be between 0 and 100" >&2
        error_found=1
    fi
    
    if [ "$CPU_MIN_TEMP" -ge "$CPU_MAX_TEMP" ]; then
        echo "$DATE ⚠ Error: CPU_MIN_TEMP must be less than CPU_MAX_TEMP" >&2
        error_found=1
    fi
    
    if [ "$CPU_TEMP_FAIL_THRESHOLD" -le "$CPU_MAX_TEMP" ]; then
        echo "$DATE ⚠ Error: CPU_TEMP_FAIL_THRESHOLD must be greater than CPU_MAX_TEMP" >&2
        error_found=1
    fi
    
    # Validate GPU temperature settings
    if ! [[ "$GPU_MIN_TEMP" =~ ^[0-9]+$ ]] || [ "$GPU_MIN_TEMP" -lt 0 ] || [ "$GPU_MIN_TEMP" -gt 100 ]; then
        echo "$DATE ⚠ Error: GPU_MIN_TEMP must be between 0 and 100" >&2
        error_found=1
    fi
    
    if ! [[ "$GPU_MAX_TEMP" =~ ^[0-9]+$ ]] || [ "$GPU_MAX_TEMP" -lt 0 ] || [ "$GPU_MAX_TEMP" -gt 100 ]; then
        echo "$DATE ⚠ Error: GPU_MAX_TEMP must be between 0 and 100" >&2
        error_found=1
    fi
    
    if [ "$GPU_MIN_TEMP" -ge "$GPU_MAX_TEMP" ]; then
        echo "$DATE ⚠ Error: GPU_MIN_TEMP must be less than GPU_MAX_TEMP" >&2
        error_found=1
    fi
    
    if [ "$GPU_TEMP_FAIL_THRESHOLD" -le "$GPU_MAX_TEMP" ]; then
        echo "$DATE ⚠ Error: GPU_TEMP_FAIL_THRESHOLD must be greater than GPU_MAX_TEMP" >&2
        error_found=1
    fi
    
    # Validate GPU fan settings
    if ! [[ "$GPU_FANS" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
        echo "$DATE ⚠ Error: GPU_FANS must be a comma-separated list of fan numbers" >&2
        error_found=1
    fi
    
    if ! [[ "$LOOP_TIME" =~ ^[0-9]+$ ]] || [ "$LOOP_TIME" -lt 1 ]; then
        echo "$DATE ⚠ Error: LOOP_TIME must be a positive integer" >&2
        error_found=1
    fi
    
    if ! [[ "$LOG_FREQUENCY" =~ ^[0-9]+$ ]] || [ "$LOG_FREQUENCY" -lt 1 ]; then
        echo "$DATE ⚠ Error: LOG_FREQUENCY must be a positive integer" >&2
        error_found=1
    fi
    
    # Validate iDRAC IP format
    if ! [[ "$IDRAC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$DATE ⚠ Error: IDRAC_IP must be a valid IP address" >&2
        error_found=1
    fi
    
    return $error_found
}

# Function to safely get file modification time
get_mod_time() {
    local mod_time
    if ! mod_time=$(stat -c %Y "$CONFIG_FILE" 2>/dev/null); then
        echo "$DATE ⚠ Error: Cannot read modification time of $CONFIG_FILE" >&2
        return 1
    fi
    echo "$mod_time"
    return 0
}

# Validate initial configuration
if ! validate_config; then
    echo "$DATE ⚠ Error: Initial configuration is invalid. Please check config.env" >&2
    exit 1
fi

# Get initial config file modification time
if ! LAST_MOD_TIME=$(get_mod_time); then
    echo "$DATE ⚠ Error: Cannot access config file. Using default settings." >> $LOG_FILE
    LAST_MOD_TIME=0
fi

# Function to check if config has changed and reload if needed
check_and_reload_config() {
    local current_mod_time
    
    # Check if config file exists and is readable
    if [ ! -f "$CONFIG_FILE" ] || [ ! -r "$CONFIG_FILE" ]; then
        echo "$DATE ⚠ Error: Config file $CONFIG_FILE is not accessible" >&2
        return 1
    fi
    
    # Get current modification time
    if ! current_mod_time=$(get_mod_time); then
        return 1
    fi
    
    if [ "$current_mod_time" != "$LAST_MOD_TIME" ]; then
        echo "$DATE ⚙ Configuration file changed, reloading settings..." >> $LOG_FILE
        
        # Create a temporary file for the new configuration
        local temp_config
        temp_config=$(mktemp)
        if [ ! -f "$temp_config" ]; then
            echo "$DATE ⚠ Error: Cannot create temporary file for config validation" >&2
            return 1
        fi
        
        # Copy current environment variables that we want to preserve
        declare -p > "$temp_config"
        
        # Source the new config file
        if ! source "$CONFIG_FILE"; then
            echo "$DATE ⚠ Error: Failed to load new configuration" >&2
            rm -f "$temp_config"
            return 1
        fi
        
        # Validate the new configuration
        if ! validate_config; then
            echo "$DATE ⚠ Error: New configuration is invalid. Reverting to previous settings." >&2
            source "$temp_config"
            rm -f "$temp_config"
            return 1
        fi
        
        # Clean up and update modification time
        rm -f "$temp_config"
        LAST_MOD_TIME=$current_mod_time
        echo "$DATE ⚙ Configuration reloaded successfully" >> $LOG_FILE
    fi
}

# Initialize variables
CPU_T_OLD=0
GPU_T_OLD=0
BASE_FAN_PERCENT=$FAN_MIN
GPU_EXTRA_PERCENT=0

# Beginning of monitoring and control loop
   # Debug: Log current settings at start of loop
   if [ "$DEBUG" = "y" ]; then
      echo "$DATE 🔍 DEBUG: Settings - FAN_MIN: $FAN_MIN%, CPU_MIN_TEMP: ${CPU_MIN_TEMP}°C, CPU_MAX_TEMP: ${CPU_MAX_TEMP}°C, GPU_MIN_TEMP: ${GPU_MIN_TEMP}°C, GPU_MAX_TEMP: ${GPU_MAX_TEMP}°C" >> $LOG_FILE
      echo "$DATE 🔍 DEBUG: Previous state - CPU_OLD: ${CPU_T_OLD}°C, GPU_OLD: ${GPU_T_OLD}°C, BASE_FAN: ${BASE_FAN_PERCENT}%, GPU_EXTRA: ${GPU_EXTRA_PERCENT}%" >> $LOG_FILE
   fi
while true; do
   DATE=$(date +%H:%M:%S)
   
   # Check if config file has changed
   check_and_reload_config

   # Get CPU temperature
   CPU_T=$(get_cpu_temp)
   [ "$DEBUG" = "y" ] && echo "$DATE 🔍 DEBUG: Read CPU temperature: ${CPU_T}°C" >> $LOG_FILE
   if [ $? -ne 0 ]; then
       echo "$DATE ⚠ Error: Failed to read CPU temperature. Enabling stock Dell fan control." >> $LOG_FILE
       /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD raw 0x30 0x30 0x01 0x01 2>/dev/null
       exit 1
   fi

   # Get GPU temperature
   GPU_T=$(get_gpu_temp)
   if [ $? -ne 0 ]; then
       echo "$DATE ⚠ Warning: Failed to read GPU temperature. Using CPU temperature for all fans." >> $LOG_FILE
       GPU_T=$CPU_T
   [ "$DEBUG" = "y" ] && echo "$DATE 🔍 DEBUG: Read GPU temperature: ${GPU_T}°C" >> $LOG_FILE
   fi
   
   # Validate temperature readings (must be between 1-99°C)
      [ "$DEBUG" = "y" ] && echo "$DATE 🔍 DEBUG: Temperature readings are valid (CPU: ${CPU_T}°C, GPU: ${GPU_T}°C)" >> $LOG_FILE
   if [ "$CPU_T" -ge 1 ] && [ "$CPU_T" -le 99 ] && [ "$GPU_T" -ge 1 ] && [ "$GPU_T" -le 99 ]; then
      # Check for critical temperature thresholds
      if [ "$CPU_T" -ge $CPU_TEMP_FAIL_THRESHOLD ]; then
         echo "$DATE ⚠ CRITICAL!!!! CPU Temperature ${CPU_T}°C exceeds shutdown threshold of ${CPU_TEMP_FAIL_THRESHOLD}°C" >> $LOG_FILE
         echo "$DATE ⚠ INITIATING EMERGENCY SHUTDOWN" >> $LOG_FILE
         /usr/sbin/shutdown now
         exit 0
      fi
      
      if [ "$GPU_T" -ge $GPU_TEMP_FAIL_THRESHOLD ]; then
         echo "$DATE ⚠ CRITICAL!!!! GPU Temperature ${GPU_T}°C exceeds shutdown threshold of ${GPU_TEMP_FAIL_THRESHOLD}°C" >> $LOG_FILE
         echo "$DATE ⚠ INITIATING EMERGENCY SHUTDOWN" >> $LOG_FILE
         /usr/sbin/shutdown now
         exit 0
      fi
      
      # Calculate temperature changes for hysteresis
      CPU_CHANGE_COOLING=$((CPU_T_OLD-CPU_T))
      CPU_CHANGE_WARMING=$((CPU_T-CPU_T_OLD))
      GPU_CHANGE_COOLING=$((GPU_T_OLD-GPU_T))
      GPU_CHANGE_WARMING=$((GPU_T-GPU_T_OLD))
      
      if [ "$DEBUG" = "y" ]; then
         echo "$DATE 🔍 DEBUG: Temperature changes:" >> $LOG_FILE
         echo "$DATE 🔍 DEBUG: CPU - Cooling: ${CPU_CHANGE_COOLING}°C, Warming: ${CPU_CHANGE_WARMING}°C (threshold: ${HYST_COOLING}°C, ${HYST_WARMING}°C)" >> $LOG_FILE
         echo "$DATE 🔍 DEBUG: GPU - Cooling: ${GPU_CHANGE_COOLING}°C, Warming: ${GPU_CHANGE_WARMING}°C (threshold: ${HYST_COOLING}°C, ${HYST_WARMING}°C)" >> $LOG_FILE
      fi

      # Check if temperature changes exceed hysteresis thresholds
      if [ $CPU_CHANGE_COOLING -ge $HYST_COOLING ] || [ $((CPU_T-CPU_T_OLD)) -ge $HYST_WARMING ] || \
         [ $((GPU_T_OLD-GPU_T)) -ge $HYST_COOLING ] || [ $((GPU_T-GPU_T_OLD)) -ge $HYST_WARMING ]; then
         
         [ "$DEBUG" = "y" ] && echo "$DATE 🔍 DEBUG: Temperature change exceeds hysteresis threshold" >> $LOG_FILE
         echo "$DATE ⚡ Temperature change detected (CPU: ${CPU_T}°C, GPU: ${GPU_T}°C)" >> $LOG_FILE
         
         # Update last temperatures for future comparisons
         CPU_T_OLD=$CPU_T
         GPU_T_OLD=$GPU_T
         
         # Calculate base fan speed from CPU temperature (applies to all fans)
         BASE_FAN_PERCENT=$(calculate_fan_speed "$CPU_T" "$CPU_MIN_TEMP" "$CPU_MAX_TEMP")
         
         # Calculate GPU fan speed and determine if extra cooling is needed
         local gpu_required_percent=$(calculate_fan_speed "$GPU_T" "$GPU_MIN_TEMP" "$GPU_MAX_TEMP")
         if [ "$gpu_required_percent" -gt "$BASE_FAN_PERCENT" ]; then
            GPU_EXTRA_PERCENT=$((gpu_required_percent - BASE_FAN_PERCENT))
         else
            GPU_EXTRA_PERCENT=0
         fi
         
         # Periodic manual control check (every 10 cycles)
         if [ "$CONTROL" -eq 10 ]; then
            CONTROL=0
            /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD raw 0x30 0x30 0x01 0x00 > /dev/null
            echo "$DATE ✓ Manual fan control verified" >> $LOG_FILE
         else
            CONTROL=$(( CONTROL + 1 ))
         fi
         
         # Set base speed for all fans with a single command
         [ "$DEBUG" = "y" ] && echo "$DATE 🔍 DEBUG: Setting base fan speed for all fans to ${BASE_FAN_PERCENT}%" >> $LOG_FILE
         if ! set_all_fans_speed "$BASE_FAN_PERCENT"; then
             echo "$DATE ⚠ Error: Failed to set base fan speeds. Enabling stock Dell fan control." >> $LOG_FILE
             /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD raw 0x30 0x30 0x01 0x01 2>/dev/null
             exit 1
         fi
         
         # If GPU needs extra cooling, increase GPU fan speeds
         if [ "$GPU_EXTRA_PERCENT" -gt 0 ]; then
             local gpu_final_percent=$((BASE_FAN_PERCENT + GPU_EXTRA_PERCENT))
             if [ "$gpu_final_percent" -gt 100 ]; then
                gpu_final_percent=100
             [ "$DEBUG" = "y" ] && echo "$DATE 🔍 DEBUG: Setting GPU fans (${GPU_FANS}) to ${gpu_final_percent}% (base ${BASE_FAN_PERCENT}% + extra ${GPU_EXTRA_PERCENT}%)" >> $LOG_FILE
             fi
             if ! set_fan_speed "$GPU_FANS" "$gpu_final_percent"; then
                 echo "$DATE ⚠ Error: Failed to set GPU fan speeds. Enabling stock Dell fan control." >> $LOG_FILE
                 /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD raw 0x30 0x30 0x01 0x01 2>/dev/null
                 exit 1
             fi
             echo "$DATE ✓ Updated - CPU Temp: ${CPU_T}°C (All Fans: ${BASE_FAN_PERCENT}%), GPU Temp: ${GPU_T}°C (GPU Fans: +${GPU_EXTRA_PERCENT}% = ${gpu_final_percent}%)" >> $LOG_FILE
         else
             echo "$DATE ✓ Updated - CPU Temp: ${CPU_T}°C (All Fans: ${BASE_FAN_PERCENT}%), GPU Temp: ${GPU_T}°C (No extra cooling needed)" >> $LOG_FILE
         fi
      else
         # Log based on LOG_FREQUENCY or if DEBUG is enabled
         if [ "$DEBUG" = "y" ] || [ "$((CONTROL % LOG_FREQUENCY))" -eq 0 ]; then
            if [ "$GPU_EXTRA_PERCENT" -gt 0 ]; then
                local gpu_final_percent=$((BASE_FAN_PERCENT + GPU_EXTRA_PERCENT))
                echo "$DATE ✓ System stable - CPU Temp: ${CPU_T}°C (All Fans: ${BASE_FAN_PERCENT}%), GPU Temp: ${GPU_T}°C (GPU Fans: +${GPU_EXTRA_PERCENT}% = ${gpu_final_percent}%)" >> $LOG_FILE
            else
                echo "$DATE ✓ System stable - CPU Temp: ${CPU_T}°C (All Fans: ${BASE_FAN_PERCENT}%), GPU Temp: ${GPU_T}°C (No extra cooling needed)" >> $LOG_FILE
            fi
         fi
      fi
   else
      # Error handling: Invalid temperature reading
      echo "$DATE ⚠ Error: Invalid temperature reading (CPU: ${CPU_T}°C, GPU: ${GPU_T}°C). Reverting to stock Dell fan control" >> $LOG_FILE
      /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD raw 0x30 0x30 0x01 0x01 >> $LOG_FILE
      exit 0
   fi
   
   # Sleep for configured interval
   sleep $LOOP_TIME
done
