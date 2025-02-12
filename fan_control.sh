#!/bin/bash

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






# Clear logs on startup if enabled
if [ $CLEAR_LOG == "y" ]; then
   truncate -s 0 $LOG_FILE
   fi
# Get system date & time.
DATE=$(date +%d-%m-%Y\ %H:%M:%S)
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
if [ $CLEAR_LOG == "y" ]; then
   echo "Date $DATE --- Log clearing at startup is enabled">> $LOG_FILE
   else
   echo "Date $DATE --- Log clearing at startup is disabled">> $LOG_FILE
   fi
echo "Date $DATE --- Log file location is "$LOG_FILE" (You are looking at it silly.)">> $LOG_FILE
# Get highest temp of any cpu package.
T_CHECK=$(sensors coretemp-isa-0000 coretemp-isa-0001 | grep Package | cut -c17-18 | sort -n | tail -1) > /dev/null
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

# Initialize control counter
CONTROL=0

# Beginning of monitoring and control loop
while true; do
   DATE=$(date +%H:%M:%S)
   echo "$DATE --> Starting monitoring cycle..." >> $LOG_FILE
   
   # Step 1: Get highest CPU package temperature from all CPU sensors
   echo "$DATE [Step 1] Reading CPU temperatures from sensors..." >> $LOG_FILE
   T=$(sensors coretemp-isa-0000 coretemp-isa-0001 | grep Package | cut -c17-18 | sort -n | tail -1) > /dev/null
   
   # Step 2: Validate temperature reading (must be between 1-99°C)
   echo "$DATE [Step 2] Validating temperature reading..." >> $LOG_FILE
   if [ "$T" -ge 1 ] && [ "$T" -le 99 ]; then
      echo "$DATE [Step 2] ✓ Valid temperature reading: ${T}°C" >> $LOG_FILE
      
      # Step 3: Check for critical temperature threshold
      echo "$DATE [Step 3] Checking against critical threshold (${TEMP_FAIL_THRESHOLD}°C)..." >> $LOG_FILE
      if [ "$T" -ge $TEMP_FAIL_THRESHOLD ]; then
         # Emergency shutdown if temperature exceeds safe threshold
         echo "$DATE [Step 3] ⚠ CRITICAL!!!! Temperature ${T}°C exceeds shutdown threshold of ${TEMP_FAIL_THRESHOLD}°C" >> $LOG_FILE
         echo "$DATE [Step 3] ⚠ INITIATING EMERGENCY SHUTDOWN" >> $LOG_FILE
         /usr/sbin/shutdown now
         exit 0
      fi
      echo "$DATE [Step 3] ✓ Temperature below critical threshold" >> $LOG_FILE
      
      # Step 4: Check if temperature change exceeds hysteresis thresholds
      echo "$DATE [Step 4] Checking temperature change (Current: ${T}°C, Previous: ${T_OLD}°C)..." >> $LOG_FILE
      # Only adjust fans if temp has changed significantly to prevent constant adjustments
      if [ $((T_OLD-T)) -ge $HYST_COOLING ]  || [ $((T-T_OLD)) -ge $HYST_WARMING ]; then
         echo "$DATE [Step 4] ⚡ Significant temperature change detected" >> $LOG_FILE
         # Update last temperature for future comparisons
         T_OLD=$T
         
         # Step 5: Calculate required fan speed
         echo "$DATE [Step 5] Calculating required fan speed..." >> $LOG_FILE
         # Convert current temperature to a percentage between MIN_TEMP and MAX_TEMP
         FAN_CUR="$(( T - MIN_TEMP ))"
         FAN_MAX="$(( MAX_TEMP - MIN_TEMP ))"
         FAN_PERCENT=`echo "$FAN_MAX" "$FAN_CUR" | awk '{printf "%d\n", ($2/$1)*100}'`
         echo "$DATE [Step 5] ✓ Initial fan speed calculation: ${FAN_PERCENT}%" >> $LOG_FILE
         
         # Step 6: Apply fan speed limits
         echo "$DATE [Step 6] Applying fan speed limits..." >> $LOG_FILE
         # Ensure minimum fan speed
         if [ "$FAN_PERCENT" -lt "$FAN_MIN" ]; then
            echo "$DATE [Step 6] ↑ Applying minimum fan speed limit: ${FAN_MIN}%" >> $LOG_FILE
            FAN_PERCENT="$FAN_MIN"
         fi
         # Cap maximum fan speed
         if [ "$FAN_PERCENT" -gt 100 ]; then
            echo "$DATE [Step 6] ↓ Capping at maximum fan speed: 100%" >> $LOG_FILE
            FAN_PERCENT="100"
         fi
         echo "$DATE [Step 6] ✓ Final fan speed after limits: ${FAN_PERCENT}%" >> $LOG_FILE
         
         # Step 7: Periodic manual control check
         echo "$DATE [Step 7] Control verification check (cycle ${CONTROL}/10)..." >> $LOG_FILE
         # Every 10 cycles, ensure we still have manual fan control
         if [ "$CONTROL" -eq 10 ]; then
            CONTROL=0
            echo "$DATE [Step 7] ⚡ Verifying manual fan control is active" >> $LOG_FILE
            /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD raw 0x30 0x30 0x01 0x00  > /dev/null
            echo "$DATE [Step 7] ✓ Manual control verified" >> $LOG_FILE
         else
            CONTROL=$(( CONTROL + 1 ))
            echo "$DATE [Step 7] ✓ Control check not needed this cycle" >> $LOG_FILE
         fi
         
         # Step 8: Apply fan speed
         echo "$DATE [Step 8] Applying new fan speed settings..." >> $LOG_FILE
         # Convert percentage to hexadecimal for IPMI
         HEXADECIMAL_FAN_SPEED=$(printf '0x%02x' $FAN_PERCENT)
         # Send fan speed command to iDRAC
         /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD raw 0x30 0x30 0x02 0xff $HEXADECIMAL_FAN_SPEED > /dev/null
         echo "$DATE [Step 8] ✓ Fan speed updated - Temperature: ${T}°C, Fan Speed: ${FAN_PERCENT}%" >> $LOG_FILE
      else
         echo "$DATE [Step 4] ✓ No significant temperature change, maintaining current fan speed" >> $LOG_FILE
      fi
   else
      # Error handling: Invalid temperature reading
      echo "$DATE [Error] ⚠ Invalid temperature reading: ${T}°C" >> $LOG_FILE
      echo "$DATE [Error] ⚠ Reverting to stock Dell fan control for safety" >> $LOG_FILE
      /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD raw 0x30 0x30 0x01 0x01 >> $LOG_FILE
      exit 0
   fi
   #end loop, and sleep for how ever many seconds LOOP_TIME is set to above.
   sleep $LOOP_TIME;
   done
