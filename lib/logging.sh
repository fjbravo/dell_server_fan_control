#!/bin/bash

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
        echo "$DATE 🔍 DEBUG: $1" >> $LOG_FILE
    fi
    return 0  # Always return success to avoid affecting $?
}

# Function for info logging
info_log() {
    echo "$DATE ✓ $1" >> $LOG_FILE
    return 0
}

# Function for warning logging
warn_log() {
    echo "$DATE ⚠ Warning: $1" >> $LOG_FILE
    return 0
}

# Function for error logging
error_log() {
    echo "$DATE ⚠ Error: $1" >> $LOG_FILE
    return 0
}

# Function for configuration logging
config_log() {
    echo "$DATE 🔧 Config: $1" >> $LOG_FILE
    return 0
}
