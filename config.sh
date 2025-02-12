#!/bin/bash

#-----USER DEFINED VARIABLES-----
# iDRAC
IDRAC_IP="192.168.0.20"
IDRAC_USER="root"
IDRAC_PASSWORD="calvin"

# Thermal
# FAN_MIN sets the minimum PWM speed percentage for the fans.
FAN_MIN="12"
# Set the MIN_TEMP to where the fan speed curve will start at 0. If FAN_MIN is set above, fan speeds will be the higher value of FAN_MIN and calculated curve percentage.
MIN_TEMP="40"
# MAX_TEMP is where fans will reach 100% PWM.
MAX_TEMP="80"
# If TEMP_FAIL_THRESHOLD temperature is reached, execute system shutdown
TEMP_FAIL_THRESHOLD="83"
# Set HYST_COOLING and HYST_WARMING to how many degrees change you want before adjusting fan speed. Larger numbers will decrease minor fan changes.
HYST_WARMING="3"
HYST_COOLING="4"

# Misc
# How many seconds between cpu temp checks and fan changes.
LOOP_TIME="10"
# Set LOG_FILE location.
LOG_FILE=/var/log/fan_control.log
# Clear log on script start. Set to CLEAR_LOG="y" to enable
CLEAR_LOG="y"
#-----END USER DEFINED VARIABLES-----