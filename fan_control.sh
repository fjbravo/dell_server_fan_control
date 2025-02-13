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

# Initialize control counter and other variables
CONTROL=0
T_OLD=0
FAN_PERCENT=$FAN_MIN

# Function to reload configuration
reload_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        echo "$DATE ⚙ Configuration reloaded" >> $LOG_FILE
    fi
}

# Beginning of monitoring and control loop
while true; do
   DATE=$(date +%H:%M:%S)
   
   # Reload config every 60 seconds (when CONTROL is 0)
   if [ "$CONTROL" -eq 0 ]; then
       reload_config
   fi

   # Get highest CPU package temperature from all CPU sensors
   T=$(get_cpu_temp)
   if [ $? -ne 0 ]; then
       echo "$DATE ⚠ Error: Failed to read temperature. Enabling stock Dell fan control." >> $LOG_FILE
       /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD raw 0x30 0x30 0x01 0x01 2>/dev/null
       exit 1
   fi
   
   # Validate temperature reading (must be between 1-99°C)
   if [ "$T" -ge 1 ] && [ "$T" -le 99 ]; then
      # Check for critical temperature threshold
      if [ "$T" -ge $TEMP_FAIL_THRESHOLD ]; then
         # Emergency shutdown if temperature exceeds safe threshold
         echo "$DATE ⚠ CRITICAL!!!! Temperature ${T}°C exceeds shutdown threshold of ${TEMP_FAIL_THRESHOLD}°C" >> $LOG_FILE
         echo "$DATE ⚠ INITIATING EMERGENCY SHUTDOWN" >> $LOG_FILE
         /usr/sbin/shutdown now
         exit 0
      fi
      
      # Check if temperature change exceeds hysteresis thresholds
      # Only adjust fans if temp has changed significantly to prevent constant adjustments
      if [ $((T_OLD-T)) -ge $HYST_COOLING ]  || [ $((T-T_OLD)) -ge $HYST_WARMING ]; then
         echo "$DATE ⚡ Temperature change detected (${T}°C)" >> $LOG_FILE
         # Update last temperature for future comparisons
         T_OLD=$T
         
         # Calculate required fan speed
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
         
         # Periodic manual control check (every 10 cycles)
         if [ "$CONTROL" -eq 10 ]; then
            CONTROL=0
            /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD raw 0x30 0x30 0x01 0x00  > /dev/null
            echo "$DATE ✓ Manual fan control verified" >> $LOG_FILE
         else
            CONTROL=$(( CONTROL + 1 ))
         fi
         
         # Apply fan speed
         HEXADECIMAL_FAN_SPEED=$(printf '0x%02x' $FAN_PERCENT)
         if ! /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD raw 0x30 0x30 0x02 0xff $HEXADECIMAL_FAN_SPEED 2>/dev/null; then
             echo "$DATE ⚠ Error: Failed to set fan speed. Enabling stock Dell fan control." >> $LOG_FILE
             /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD raw 0x30 0x30 0x01 0x01 2>/dev/null
             exit 1
         fi
         echo "$DATE ✓ Updated - Temp: ${T}°C, Fan: ${FAN_PERCENT}%" >> $LOG_FILE
      else
         # Log based on LOG_FREQUENCY or if DEBUG is enabled
         if [ "$DEBUG" = "y" ] || [ "$((CONTROL % LOG_FREQUENCY))" -eq 0 ]; then
            echo "$DATE ✓ System stable - Temp: ${T}°C, Fan: ${FAN_PERCENT}%" >> $LOG_FILE
         fi
      fi
   else
      # Error handling: Invalid temperature reading
      echo "$DATE ⚠ Error: Invalid temperature reading (${T}°C). Reverting to stock Dell fan control" >> $LOG_FILE
      /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD raw 0x30 0x30 0x01 0x01 >> $LOG_FILE
      exit 0
   fi
   #end loop, and sleep for how ever many seconds LOOP_TIME is set to above.
   sleep $LOOP_TIME;
   done
