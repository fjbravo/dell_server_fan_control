#!/bin/bash

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
