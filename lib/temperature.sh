#!/bin/bash

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

# Function to get all GPU temperatures
get_all_gpu_temps() {
    # Check if nvidia-smi command exists
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        early_log "ERROR" "'nvidia-smi' command not found. Please install NVIDIA drivers."
        return 1
    fi

    local temps
    temps=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null)
    
    # Check if we got any valid temperature readings
    if [ -z "$temps" ]; then
        early_log "ERROR" "Could not read GPU temperatures. Check if NVIDIA GPU is present and drivers are loaded."
        return 1
    fi
    
    # Replace newlines with commas
    temps=$(echo "$temps" | tr '\n' ',')
    # Remove trailing comma if present
    temps=${temps%,}
    
    echo "$temps"
    return 0
}

# Function to get GPU temperature (highest temperature for fan control)
get_gpu_temp() {
    # Check if nvidia-smi command exists
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        early_log "ERROR" "'nvidia-smi' command not found. Please install NVIDIA drivers."
        return 1
    fi

    local temp
    temp=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | sort -n | tail -1)
    
    # Check if we got a valid temperature reading
    if [ -z "$temp" ] || ! [[ "$temp" =~ ^[0-9]+$ ]]; then
        early_log "ERROR" "Could not read GPU temperature. Check if NVIDIA GPU is present and drivers are loaded."
        return 1
    fi
    
    echo "$temp"
    return 0
}

# Function to get all CPU temperatures
get_all_cpu_temps() {
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

    # Get all coretemp sensors
    local coretemp_sensors=$(sensors | grep -o "coretemp-isa-[0-9]*" | sort -u)
    
    # If no coretemp sensors found, return error
    if [ -z "$coretemp_sensors" ]; then
        early_log "ERROR" "No coretemp sensors found. Check if coretemp module is loaded."
        return 1
    fi
    
    local temps=""
    
    # Loop through each coretemp sensor and get its temperature
    for sensor in $coretemp_sensors; do
        local temp=$(sensors $sensor 2>/dev/null | grep Package | cut -c17-18)
        
        # Check if we got a valid temperature reading
        if [ -n "$temp" ] && [[ "$temp" =~ ^[0-9]+$ ]]; then
            if [ -n "$temps" ]; then
                temps="${temps},${temp}"
            else
                temps="${temp}"
            fi
        fi
    done
    
    # Check if we got any valid temperature readings
    if [ -z "$temps" ]; then
        early_log "ERROR" "Could not read CPU temperatures. Check if coretemp module is loaded."
        return 1
    fi
    
    echo "$temps"
    return 0
}

# Function to get CPU temperature (highest temperature for fan control)
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
