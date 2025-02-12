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

# Beginning of loop to check and set temps. Adjust time
while true; do
   # Get highest package temp from sensors.
   T=$(sensors coretemp-isa-0000 coretemp-isa-0001 | grep Package | cut -c17-18 | sort -n | tail -1) > /dev/null
   # Ensure Temps are still valid values.
   if [ "$T" -ge 1 ] && [ "$T" -le 99 ]; then
      # Make sure the CPU isn't over TEMP_FAIL_THRESHOLD.
      if [ "$T" -ge $TEMP_FAIL_THRESHOLD ]; then
         # Shutdown system if temps are too high
         echo "CRITICAL!!!! TEMP_FAIL_THRESHOLD met. Shutting system down immediately.">> $LOG_FILE
         /usr/sbin/shutdown now
         exit 0
         fi
      # Check and see if temps have varied enough to merit changing fan speed.
      if [ $((T_OLD-T)) -ge $HYST_COOLING ]  || [ $((T-T_OLD)) -ge $HYST_WARMING ]; then
         # Set hysteresis variable
         T_OLD=$T
         # Calculate the percentage between MAX_TEMP and MIN_TEMP the cpu is currently at and set speed accordingly.
         FAN_CUR="$(( T - MIN_TEMP ))"
         FAN_MAX="$(( MAX_TEMP - MIN_TEMP ))"
         FAN_PERCENT=`echo "$FAN_MAX" "$FAN_CUR" | awk '{printf "%d\n", ($2/$1)*100}'`
         # Ensure fans are at or above FAN_MIN
         if [ "$FAN_PERCENT" -lt "$FAN_MIN" ]; then
            FAN_PERCENT="$FAN_MIN"
            fi
         # Cap Fans at 100%
         if [ "$FAN_PERCENT" -gt 100 ]; then
            FAN_PERCENT="100"
            fi
         # Make sure we still have manual control every 10 speed updates
         if [ "$CONTROL" -eq 10 ]; then
            CONTROL=0
            DATE=$(date +%H:%M:%S)
            echo "$DATE--> Ensuring manual fan control"  >> $LOG_FILE
            /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD raw 0x30 0x30 0x01 0x00  > /dev/null
            else
            CONTROL=$(( CONTROL + 1 ))
            fi
         # Convert to HEX for ipmi
         HEXADECIMAL_FAN_SPEED=$(printf '0x%02x' $FAN_PERCENT)
         # Log current time, temp, and fan speed.
         DATE=$(date +%H:%M:%S)
         echo "$DATE - Temp: $T --> Fan: $FAN_PERCENT%">> $LOG_FILE
         # Set fan speed via ipmitool
         /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD raw 0x30 0x30 0x02 0xff $HEXADECIMAL_FAN_SPEED > /dev/null
         fi
      #if temps are invalid, go back do Dell Control and exit app
      else
      echo "$DATE--> Somethings not right. No valid data from sensors. Enabling stock Dell fan control">> $LOG_FILE
      /usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD raw 0x30 0x30 0x01 0x01 >> $LOG_FILE
      exit 0
      fi
   #end loop, and sleep for how ever many seconds LOOP_TIME is set to above.
   sleep $LOOP_TIME;
   done
