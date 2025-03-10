#!/bin/bash

# Function to check log file size and rotate if needed
check_log_size() {
    if [ -f "$LOG_FILE" ]; then
        # Get file size in bytes
        local size=$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null)
        if [ -n "$size" ] && [ "$size" -gt $((5 * 1024 * 1024)) ]; then  # 5MB in bytes
            local timestamp=$(date +%Y%m%d_%H%M%S)
            mv "$LOG_FILE" "${LOG_FILE}_${timestamp}"
            touch "$LOG_FILE" 2>/dev/null || true
        fi
    fi
    return 0
}

# Function to log status updates in the new format
log_status() {
    local type="$1"    # CPU Temps, All Fans, GPU Temps, GPU Fans
    local data="$2"    # The formatted data string
    
    # Check log size before writing
    check_log_size
    
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] STATUS | $type -> $data" >> $LOG_FILE
    return 0
}

# Function to log the complete system status
log_system_status() {
    local cpu_temps="$1"
    local gpu_temps="$2"
    local base_fan_percent="$3"
    local gpu_fans="$4"
    local gpu_extra_percent="${5:-0}"
    
    # Log CPU temperatures
    log_status "CPU Temps" "$(format_cpu_temps "$cpu_temps")"
    
    # Log all fan speeds
    log_status "All Fans" "$(format_all_fans "$base_fan_percent")"
    
    # Log GPU temperatures
    log_status "GPU Temps" "$(format_gpu_temps "$gpu_temps")"
    
    # Log GPU fan speeds
    if [ -n "$gpu_extra_percent" ] && [ "$gpu_extra_percent" -gt 0 ]; then
        gpu_final_percent=$((base_fan_percent + gpu_extra_percent))
        if [ "$gpu_final_percent" -gt 100 ]; then
            gpu_final_percent=100
        fi
        log_status "GPU Fans" "$(format_gpu_fans "$gpu_fans" "$gpu_final_percent")"
    else
        log_status "GPU Fans" "$(format_gpu_fans "$gpu_fans" "$base_fan_percent")"
    fi
    
    return 0
}

# Function to log changes in the new format
log_change() {
    local type="$1"    # All Fans, GPU Fans
    local data="$2"    # The formatted data string
    
    # Check log size before writing
    check_log_size
    
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] CHANGE | $type -> $data" >> $LOG_FILE
    return 0
}

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
        # Check log size before writing
        check_log_size
        
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG | $1" >> $LOG_FILE
    fi
    return 0  # Always return success to avoid affecting $?
}

# Function for info logging (legacy format, use log_status or log_change instead for new format)
info_log() {
    # Check log size before writing
    check_log_size
    
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO | $1" >> $LOG_FILE
    return 0
}

# Function for warning logging
warn_log() {
    # Check log size before writing
    check_log_size
    
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING | $1" >> $LOG_FILE
    return 0
}

# Function for error logging
error_log() {
    # Check log size before writing
    check_log_size
    
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR | $1" >> $LOG_FILE
    return 0
}

# Function for configuration logging
config_log() {
    # Check log size before writing
    check_log_size
    
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] CONFIG | $1" >> $LOG_FILE
    return 0
}

# Helper functions to format data for logging

# Format CPU temperatures
format_cpu_temps() {
    local temps="$1"
    local result=""
    local cpu_num=1
    
    # Split temperatures into array
    IFS=',' read -ra CPU_TEMPS <<< "$temps"
    
    # Format each CPU temperature
    for temp in "${CPU_TEMPS[@]}"; do
        if [ -n "$result" ]; then
            result="$result - "
        fi
        result="${result}CPU-$(printf "%02d" $cpu_num): $temp"
        ((cpu_num++))
    done
    
    echo "$result"
}

# Format all fan speeds
format_all_fans() {
    local speed="$1"
    echo "FAN-01: $speed - FAN-02: $speed - FAN-03: $speed - FAN-04: $speed - FAN-05: $speed - FAN-06: $speed"
}

# Format GPU temperatures
format_gpu_temps() {
    local temps="$1"
    local result=""
    local gpu_num=1
    
    # Split temperatures into array
    IFS=',' read -ra GPU_TEMPS <<< "$temps"
    
    # Format each GPU temperature
    for temp in "${GPU_TEMPS[@]}"; do
        if [ -n "$result" ]; then
            result="$result - "
        fi
        result="${result}GPU-$(printf "%02d" $gpu_num): $temp"
        ((gpu_num++))
    done
    
    echo "$result"
}

# Format GPU fan speeds
format_gpu_fans() {
    local fan_list="$1"
    local speed="$2"
    
    # Default to showing FAN-05 and FAN-06 as GPU fans
    if [[ "$fan_list" == "5,6" ]]; then
        echo "FAN-05: $speed - FAN-06: $speed"
    else
        # For custom GPU fan configurations, build the string dynamically
        local result=""
        IFS=',' read -ra FANS <<< "$fan_list"
        for fan in "${FANS[@]}"; do
            if [ -n "$result" ]; then
                result="$result - "
            fi
            result="${result}FAN-$(printf "%02d" $fan): $speed"
        done
        echo "$result"
    fi
}
