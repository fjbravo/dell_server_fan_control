#!/bin/bash

# Enable error tracing
set -x

# Get the directory where the script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Source all library files
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/ipmi_control.sh"
source "$SCRIPT_DIR/lib/temperature.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/mqtt.sh"

# Source configuration file (looking in the same directory as the script)
CONFIG_FILE="$SCRIPT_DIR/config.env"

# Check if config file exists and source it
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    early_log "ERROR" "Configuration file not found at $CONFIG_FILE"
    exit 1
fi

# Set default values for MQTT timeout settings if not defined in config
if [ -z "$MQTT_TIMEOUT" ]; then
    MQTT_TIMEOUT=3
fi

if [ -z "$MQTT_MAX_FAILURES" ]; then
    MQTT_MAX_FAILURES=3
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

# Check if log file exists and rename it with timestamp
if [ -f "$LOG_FILE" ]; then
    # Get timestamp for backup
    timestamp=$(date +%Y%m%d_%H%M%S)
    # Move existing log to backup with timestamp
    mv "$LOG_FILE" "${LOG_FILE}_${timestamp}"
fi

# Create log file directory if it doesn't exist
touch "$LOG_FILE" 2>/dev/null || true

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
if [ "$DRY_RUN" = "y" ]; then
    config_log "DRY-RUN MODE ENABLED (fan changes will be logged but not executed)"
fi

# Function to log current system status has been moved to logging.sh

# Function to check IPMI connectivity and initialize if needed
check_ipmi() {
    # Check if ipmitool exists
    if ! command -v ipmitool >/dev/null 2>&1; then
        early_log "ERROR" "'ipmitool' command not found. Please install ipmitool package."
        return 1
    fi

    # Basic connectivity test first
    if ! send_ipmi_command "CHECK_POWER_STATUS"; then
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
    send_ipmi_command "ENABLE_LAN_CHANNEL"
    send_ipmi_command "SET_LAN_PRIVILEGE"

    # Try to enable manual fan control
    early_log "INFO" "Attempting to enable manual fan control..."
    if ! send_ipmi_command "ENABLE_MANUAL_CONTROL"; then
        early_log "ERROR" "Cannot enable manual fan control. Check iDRAC user permissions."
        return 1
    fi

    # Disable 3rd Party PCIe Response
    early_log "INFO" "Disabling 3rd Party PCIe Response..."
    if ! send_ipmi_command "DISABLE_PCIE_RESPONSE"; then
        early_log "WARNING" "Failed to disable 3rd Party PCIe Response. Fan control may still work."
        # Not returning error as this is not critical for fan control
    fi

    # Verify we can read fan status
    if ! send_ipmi_command "READ_FAN_STATUS"; then
        early_log "ERROR" "Cannot read fan status. IPMI configuration may be incorrect."
        return 1
    fi

    return 0
}

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
        send_ipmi_command "DISABLE_MANUAL_CONTROL"
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
       send_ipmi_command "ENABLE_MANUAL_CONTROL"
       info_log "Enabled dynamic fan control"
   fi
   
# Get all CPU and GPU temperatures for logging
CPU_ALL_T=$(get_all_cpu_temps)
GPU_ALL_T=$(get_all_gpu_temps)

# Log initial system status
log_system_status "$CPU_ALL_T" "$GPU_ALL_T" "$BASE_FAN_PERCENT" "$GPU_FANS" "$GPU_EXTRA_PERCENT"

# Publish initial status to MQTT
mqtt_publish_status "starting" "Dell IPMI fan control service starting"
else
   error_log "Invalid temperature readings - CPU: ${CPU_T}°C, GPU: ${GPU_T}°C. Enabling stock Dell fan control."
   
   if [ "$DRY_RUN" = "y" ]; then
       debug_log "DRY-RUN: Would enable stock Dell fan control"
   else
       send_ipmi_command "DISABLE_MANUAL_CONTROL"
   fi
   
   exit 0
fi

# Initialize variables
CPU_T_OLD=0
GPU_T_OLD=0
BASE_FAN_PERCENT=$FAN_MIN
GPU_EXTRA_PERCENT=0
FAILSAFE_ACTIVE=0
SYSTEM_STATUS="normal"

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

# Beginning of monitoring and control loop
   # Debug: Log current settings at start of loop
   debug_log "Settings - FAN_MIN: $FAN_MIN%, CPU_MIN_TEMP: ${CPU_MIN_TEMP}°C, CPU_MAX_TEMP: ${CPU_MAX_TEMP}°C, GPU_MIN_TEMP: ${GPU_MIN_TEMP}°C, GPU_MAX_TEMP: ${GPU_MAX_TEMP}°C"
   debug_log "Previous state - CPU_OLD: ${CPU_T_OLD}°C, GPU_OLD: ${GPU_T_OLD}°C, BASE_FAN: ${BASE_FAN_PERCENT}%, GPU_EXTRA: ${GPU_EXTRA_PERCENT}%"
while true; do
   
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
           send_ipmi_command "DISABLE_MANUAL_CONTROL"
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
      
      # Failsafe: If GPU temperature is within 10 degrees of the shutdown threshold, set all fans to 100%
      if [ "$GPU_T" -ge $((GPU_TEMP_FAIL_THRESHOLD - 10)) ]; then
         warn_log "FAILSAFE ACTIVATED! GPU Temperature ${GPU_T}°C is within 10°C of shutdown threshold (${GPU_TEMP_FAIL_THRESHOLD}°C)"
         
         if [ "$DRY_RUN" = "y" ]; then
             debug_log "DRY-RUN: Would set all fans to 100% due to high GPU temperature"
         else
             set_all_fans_speed 100
             log_change "All Fans" "$(format_all_fans 100)"
         fi
         
         # Set flag to skip normal fan speed calculations for this cycle
         FAILSAFE_ACTIVE=1
      else
         # Reset failsafe flag if temperature is back to safe levels
         FAILSAFE_ACTIVE=0
      fi
      
      # Get all CPU and GPU temperatures for logging
      CPU_ALL_T=$(get_all_cpu_temps)
      GPU_ALL_T=$(get_all_gpu_temps)
      
      # Log current system status in every loop
      log_system_status "$CPU_ALL_T" "$GPU_ALL_T" "$BASE_FAN_PERCENT" "$GPU_FANS" "$GPU_EXTRA_PERCENT"
      
      # Determine system status
      if [ $FAILSAFE_ACTIVE -eq 1 ]; then
         SYSTEM_STATUS="critical"
      elif [ "$CPU_T" -ge $((CPU_MAX_TEMP - 5)) ] || [ "$GPU_T" -ge $((GPU_MAX_TEMP - 5)) ]; then
         SYSTEM_STATUS="escalating"
      else
         SYSTEM_STATUS="normal"
      fi
      
      # Publish metrics to MQTT
      mqtt_publish_metrics "$CPU_ALL_T" "$GPU_ALL_T" "$BASE_FAN_PERCENT" "$GPU_FANS" "$GPU_EXTRA_PERCENT" "$SYSTEM_STATUS"
      
      # Calculate temperature changes for hysteresis
      CPU_CHANGE_COOLING=$((CPU_T_OLD-CPU_T))
      CPU_CHANGE_WARMING=$((CPU_T-CPU_T_OLD))
      GPU_CHANGE_COOLING=$((GPU_T_OLD-GPU_T))
      GPU_CHANGE_WARMING=$((GPU_T-GPU_T_OLD))
      
      debug_log "Temperature changes:"
      debug_log "CPU - Cooling: ${CPU_CHANGE_COOLING}°C, Warming: ${CPU_CHANGE_WARMING}°C (threshold: ${HYST_COOLING}°C, ${HYST_WARMING}°C)"
      debug_log "GPU - Cooling: ${GPU_CHANGE_COOLING}°C, Warming: ${GPU_CHANGE_WARMING}°C (threshold: ${HYST_COOLING}°C, ${HYST_WARMING}°C)"

      # Check if temperature changes exceed hysteresis thresholds and failsafe is not active
      if [ $FAILSAFE_ACTIVE -eq 0 ] && \
         ([ $((CPU_T_OLD-CPU_T)) -ge $HYST_COOLING ] || [ $((CPU_T-CPU_T_OLD)) -ge $HYST_WARMING ] || \
          [ $((GPU_T_OLD-GPU_T)) -ge $HYST_COOLING ] || [ $((GPU_T-GPU_T_OLD)) -ge $HYST_WARMING ]); then
         
         debug_log "Temperature change exceeds hysteresis threshold"
         
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
                send_ipmi_command "ENABLE_MANUAL_CONTROL"
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
                 send_ipmi_command "DISABLE_MANUAL_CONTROL"
             fi
             
             exit 1
         fi
         
         # Log the change in fan speeds
         log_change "All Fans" "$(format_all_fans "$BASE_FAN_PERCENT")"
         
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
                     send_ipmi_command "DISABLE_MANUAL_CONTROL"
                 fi
                 
                 exit 1
             fi
             
             # Log the change in GPU fan speeds
             log_change "GPU Fans" "$(format_gpu_fans "$GPU_FANS" "$gpu_final_percent")"
         fi
      else
         # If failsafe is active, log that it's overriding normal fan control
         if [ $FAILSAFE_ACTIVE -eq 1 ]; then
            debug_log "FAILSAFE ACTIVE - All fans at 100%"
         fi
      fi
   else
      # Error handling: Invalid temperature reading
      error_log "Invalid temperature reading (CPU: ${CPU_T}°C, GPU: ${GPU_T}°C). Reverting to stock Dell fan control"
      
      if [ "$DRY_RUN" = "y" ]; then
          debug_log "DRY-RUN: Would enable stock Dell fan control due to invalid temperature readings"
      else
          send_ipmi_command "DISABLE_MANUAL_CONTROL"
      fi
      
      exit 0
   fi
   
   # Sleep for configured interval
   sleep $LOOP_TIME
done
