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
echo "Date $DATE --- Fan curve min point (MIN_TEMP) = "$MIN_TEMP"c">> $LOG_FILE
echo "Date $DATE --- Fan curve max point (MAX_TEMP) = "$MAX_TEMP"c">> $LOG_FILE
echo "Date $DATE --- System shutdown temp = "$TEMP_FAIL_THRESHOLD"c">> $LOG_FILE
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

# Function to get GPU temperature
get_gpu_temp() {
    # Check if nvidia-smi exists
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        echo "Error: 'nvidia-smi' command not found. Please install NVIDIA drivers." >&2
        return 1
    fi

    # Get GPU temperature
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

# Function to set fan speed for specific fans
set_fan_speed() {
    local fan_ids="$1"
    local speed="$2"
    local success=0
    
    # Convert speed to hexadecimal
    local hex_speed=$(printf '0x%02x' "$speed")
    
    # Set speed for each fan ID
    IFS=',' read -ra FAN_ARRAY <<< "$fan_ids"
    for fan_id in "${FAN_ARRAY[@]}"; do
        if ! /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD raw 0x30 0x30 0x02 "$fan_id" "$hex_speed" 2>/dev/null; then
            echo "$DATE ⚠ Error: Failed to set fan $fan_id speed to $speed%" >&2
            success=1
        fi
    done
    
    return $success
}

# Check IPMI connectivity first
if ! check_ipmi; then
    exit 1
fi

# Get highest temp of any cpu package.
T_CHECK=$(get_cpu_temp)
if [ $? -ne 0 ]; then
    echo "$DATE ⚠ Error: Temperature check failed. Enabling stock Dell fan control." >> $LOG_FILE
    /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD raw 0x30 0x30 0x01 0x01 >> $LOG_FILE
    exit 1
fi
# Ensure we have a value returned between 0 and 100.
if [ " $T_CHECK" -ge 1 ] && [ "$T_CHECK" -le 99 ]; then
   # Enable manual fan control and set fan PWM % via ipmitool
   echo "$DATE--> We seem to be getting valid temps from sensors! Enabling manual fan control"  >> $LOG_FILE
   /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD raw 0x30 0x30 0x01 0x00  > /dev/null
   echo "$DATE--> Enabled dynamic fan control" >> $LOG_FILE
   # If some error happens, go back do Dell Control
   else
   echo "$DATE--> Somethings not right. No valid data from sensors. Enabling stock Dell fan control and quitting." >> $LOG_FILE
   /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD raw 0x30 0x30 0x01 0x01 >> $LOG_FILE
   exit 0
   fi

# Initialize variables
T_OLD=0
GPU_T_OLD=0
FAN_PERCENT=$FAN_MIN
GPU_FAN_PERCENT=$FAN_MIN
CONTROL=0  # Initialize control counter for manual control verification

# Function to validate configuration
validate_config() {
    local error_found=0
    
    # Check if all required variables are set
    local required_vars=(
        "IDRAC_IP" "IDRAC_USER" "IDRAC_PASSWORD"  # iDRAC settings
        "FAN_MIN" "MIN_TEMP" "MAX_TEMP" "TEMP_FAIL_THRESHOLD"  # Temperature settings
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
    
    if ! [[ "$MIN_TEMP" =~ ^[0-9]+$ ]] || [ "$MIN_TEMP" -lt 0 ] || [ "$MIN_TEMP" -gt 100 ]; then
        echo "$DATE ⚠ Error: MIN_TEMP must be between 0 and 100" >&2
        error_found=1
    fi
    
    if ! [[ "$MAX_TEMP" =~ ^[0-9]+$ ]] || [ "$MAX_TEMP" -lt 0 ] || [ "$MAX_TEMP" -gt 100 ]; then
        echo "$DATE ⚠ Error: MAX_TEMP must be between 0 and 100" >&2
        error_found=1
    fi
    
    if [ "$MIN_TEMP" -ge "$MAX_TEMP" ]; then
        echo "$DATE ⚠ Error: MIN_TEMP must be less than MAX_TEMP" >&2
        error_found=1
    fi
    
    if [ "$TEMP_FAIL_THRESHOLD" -le "$MAX_TEMP" ]; then
        echo "$DATE ⚠ Error: TEMP_FAIL_THRESHOLD must be greater than MAX_TEMP" >&2
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
                echo "$DATE ⚠ Error: Required GPU variable $var is not set" >&2
                error_found=1
            fi
        done
        
        # Validate GPU temperature ranges
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
        
        if [ "$GPU_FAIL_THRESHOLD" -le "$GPU_MAX_TEMP" ]; then
            echo "$DATE ⚠ Error: GPU_FAIL_THRESHOLD must be greater than GPU_MAX_TEMP" >&2
            error_found=1
        fi
        
        # Validate GPU fan IDs format (comma-separated numbers)
        if ! [[ "$GPU_FAN_IDS" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
            echo "$DATE ⚠ Error: GPU_FAN_IDS must be comma-separated numbers" >&2
            error_found=1
        fi
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

# Beginning of monitoring and control loop
while true; do
   DATE=$(date +%H:%M:%S)
   
   # Check if config file has changed
   check_and_reload_config

   # Get highest CPU package temperature from all CPU sensors
   T=$(get_cpu_temp)
   if [ $? -ne 0 ]; then
       echo "$DATE ⚠ Error: Failed to read CPU temperature. Enabling stock Dell fan control." >> $LOG_FILE
       /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD raw 0x30 0x30 0x01 0x01 2>/dev/null
       exit 1
   fi
   
   # Get GPU temperature if GPU monitoring is enabled
   if [ "$GPU_MONITORING" = "y" ]; then
       GPU_T=$(get_gpu_temp)
       if [ $? -ne 0 ]; then
           echo "$DATE ⚠ Warning: Failed to read GPU temperature. Disabling GPU monitoring." >> $LOG_FILE
           GPU_MONITORING="n"
       fi
   fi
   
   # Validate CPU temperature reading (must be between 1-99°C)
   if [ "$T" -ge 1 ] && [ "$T" -le 99 ]; then
      # Check for critical CPU temperature threshold
      if [ "$T" -ge $TEMP_FAIL_THRESHOLD ]; then
         # Emergency shutdown if temperature exceeds safe threshold
         echo "$DATE ⚠ CRITICAL!!!! CPU Temperature ${T}°C exceeds shutdown threshold of ${TEMP_FAIL_THRESHOLD}°C" >> $LOG_FILE
         echo "$DATE ⚠ INITIATING EMERGENCY SHUTDOWN" >> $LOG_FILE
         /usr/sbin/shutdown now
         exit 0
      fi
      
      # Check if CPU temperature change exceeds hysteresis thresholds
      if [ $((T_OLD-T)) -ge $HYST_COOLING ] || [ $((T-T_OLD)) -ge $HYST_WARMING ]; then
         echo "$DATE ⚡ CPU Temperature change detected (${T}°C)" >> $LOG_FILE
         # Update last temperature for future comparisons
         T_OLD=$T
         
         # Calculate required fan speed for CPU
         FAN_CUR="$(( T - MIN_TEMP ))"
         FAN_MAX="$(( MAX_TEMP - MIN_TEMP ))"
         FAN_PERCENT=`echo "$FAN_MAX" "$FAN_CUR" | awk '{printf "%d\n", ($2/$1)*100}'`
         
         # Apply fan speed limits
         if [ "$FAN_PERCENT" -lt "$FAN_MIN" ]; then
            echo "$DATE ↑ Setting minimum fan speed: ${FAN_MIN}%" >> $LOG_FILE
            FAN_PERCENT="$FAN_MIN"
         elif [ "$FAN_PERCENT" -gt 100 ]; then
            echo "$DATE ↓ Capping at maximum fan speed: 100%" >> $LOG_FILE
            FAN_PERCENT="100"
         fi
         
         # Apply CPU fan speed to all fans
         HEXADECIMAL_FAN_SPEED=$(printf '0x%02x' $FAN_PERCENT)
         if ! /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD raw 0x30 0x30 0x02 0xff $HEXADECIMAL_FAN_SPEED 2>/dev/null; then
             echo "$DATE ⚠ Error: Failed to set fan speed. Enabling stock Dell fan control." >> $LOG_FILE
             /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD raw 0x30 0x30 0x01 0x01 2>/dev/null
             exit 1
         fi
         echo "$DATE ✓ Updated CPU fans - Temp: ${T}°C, Fan: ${FAN_PERCENT}%" >> $LOG_FILE
      fi
      
      # Handle GPU temperature if GPU monitoring is enabled
      if [ "$GPU_MONITORING" = "y" ] && [ "$GPU_T" -ge 1 ] && [ "$GPU_T" -le 99 ]; then
         # Check for critical GPU temperature threshold
         if [ "$GPU_T" -ge $GPU_FAIL_THRESHOLD ]; then
            echo "$DATE ⚠ CRITICAL!!!! GPU Temperature ${GPU_T}°C exceeds shutdown threshold of ${GPU_FAIL_THRESHOLD}°C" >> $LOG_FILE
            echo "$DATE ⚠ INITIATING EMERGENCY SHUTDOWN" >> $LOG_FILE
            /usr/sbin/shutdown now
            exit 0
         fi
         
         # Check if GPU temperature change exceeds hysteresis thresholds
         if [ $((GPU_T_OLD-GPU_T)) -ge $GPU_HYST_COOLING ] || [ $((GPU_T-GPU_T_OLD)) -ge $GPU_HYST_WARMING ]; then
            echo "$DATE ⚡ GPU Temperature change detected (${GPU_T}°C)" >> $LOG_FILE
            # Update last GPU temperature for future comparisons
            GPU_T_OLD=$GPU_T
            
            # Calculate required fan speed for GPU
            GPU_FAN_CUR="$(( GPU_T - GPU_MIN_TEMP ))"
            GPU_FAN_MAX="$(( GPU_MAX_TEMP - GPU_MIN_TEMP ))"
            GPU_FAN_PERCENT=`echo "$GPU_FAN_MAX" "$GPU_FAN_CUR" | awk '{printf "%d\n", ($2/$1)*100}'`
            
            # Apply fan speed limits
            if [ "$GPU_FAN_PERCENT" -lt "$FAN_MIN" ]; then
               echo "$DATE ↑ Setting minimum GPU fan speed: ${FAN_MIN}%" >> $LOG_FILE
               GPU_FAN_PERCENT="$FAN_MIN"
            elif [ "$GPU_FAN_PERCENT" -gt 100 ]; then
               echo "$DATE ↓ Capping at maximum GPU fan speed: 100%" >> $LOG_FILE
               GPU_FAN_PERCENT="100"
            fi
            
            # Apply GPU fan speed to GPU-specific fans
            if ! set_fan_speed "$GPU_FAN_IDS" "$GPU_FAN_PERCENT"; then
                echo "$DATE ⚠ Error: Failed to set GPU fan speed. Continuing with CPU-only control." >> $LOG_FILE
                GPU_MONITORING="n"
            else
                echo "$DATE ✓ Updated GPU fans - Temp: ${GPU_T}°C, Fan: ${GPU_FAN_PERCENT}%" >> $LOG_FILE
            fi
         fi
      fi
      
      # Periodic manual control check (every 10 cycles)
      if [ "$CONTROL" -eq 10 ]; then
         CONTROL=0
         /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD raw 0x30 0x30 0x01 0x00  > /dev/null
         echo "$DATE ✓ Manual fan control verified" >> $LOG_FILE
      else
         CONTROL=$(( CONTROL + 1 ))
      fi
      
      # Log system status based on LOG_FREQUENCY or if DEBUG is enabled
      if [ "$DEBUG" = "y" ] || [ "$((CONTROL % LOG_FREQUENCY))" -eq 0 ]; then
         if [ "$GPU_MONITORING" = "y" ]; then
            echo "$DATE ✓ System stable - CPU Temp: ${T}°C, CPU Fan: ${FAN_PERCENT}%, GPU Temp: ${GPU_T}°C, GPU Fan: ${GPU_FAN_PERCENT}%" >> $LOG_FILE
         else
            echo "$DATE ✓ System stable - CPU Temp: ${T}°C, Fan: ${FAN_PERCENT}%" >> $LOG_FILE
         fi
      fi
   else
      # Error handling: Invalid CPU temperature reading
      echo "$DATE ⚠ Error: Invalid CPU temperature reading (${T}°C). Reverting to stock Dell fan control" >> $LOG_FILE
      /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD raw 0x30 0x30 0x01 0x01 >> $LOG_FILE
      exit 0
   fi
   
   #end loop, and sleep for how ever many seconds LOOP_TIME is set to above.
   sleep $LOOP_TIME;
done
