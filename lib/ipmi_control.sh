#!/bin/bash

# Function to convert decimal to hexadecimal with optional prefix and padding
to_hex() {
    local value="$1"
    local prefix="${2:-0x}"  # Optional prefix parameter, defaults to "0x"
    local padding="${3:-2}"  # Optional padding parameter, defaults to 2 digits
    printf "${prefix}%0${padding}x" "$value"
}

# Function to send IPMI commands with centralized error handling
send_ipmi_command() {
    local command_type="$1"
    local args=("${@:2}")
    local success_count=0
    local total_fans=0
    
    # Base IPMI command
    local ipmi_base_cmd="/usr/bin/ipmitool -I lanplus -H $IDRAC_IP -U $IDRAC_USER -P $IDRAC_PASSWORD"
    
    case "$command_type" in
        "ENABLE_MANUAL_CONTROL")
            if [ "$DRY_RUN" = "y" ]; then
                debug_log "DRY-RUN: Would enable manual fan control"
                return 0
            fi
            if ! $ipmi_base_cmd raw 0x30 0x30 0x01 0x00 2>/dev/null; then
                error_log "Failed to enable manual fan control"
                return 1
            fi
            ;;
            
        "DISABLE_MANUAL_CONTROL")
            if [ "$DRY_RUN" = "y" ]; then
                debug_log "DRY-RUN: Would disable manual fan control"
                return 0
            fi
            if ! $ipmi_base_cmd raw 0x30 0x30 0x01 0x01 2>/dev/null; then
                error_log "Failed to disable manual fan control"
                return 1
            fi
            ;;
            
        "SET_ALL_FANS_SPEED")
            local speed="${args[0]}"
            local hex_speed=$(to_hex "$speed")
            
            if [ "$DRY_RUN" = "y" ]; then
                debug_log "DRY-RUN: Would set all fans speed to $speed%"
                return 0
            fi
            
            sleep 1
            if ! $ipmi_base_cmd raw 0x30 0x30 0x02 0xFF "$hex_speed" 2>/dev/null; then
                error_log "Failed to set all fans speed to $speed%"
                return 1
            fi
            ;;
            
        "SET_SPECIFIC_FANS_SPEED")
            local fan_list="${args[0]}"
            local speed="${args[1]}"
            local hex_speed=$(to_hex "$speed")
            
            if [ "$DRY_RUN" = "y" ]; then
                debug_log "DRY-RUN: Would set fans $fan_list speed to $speed%"
                return 0
            fi
            
            sleep 1
            IFS=',' read -ra FANS <<< "$fan_list"
            for fan in "${FANS[@]}"; do
                total_fans=$((total_fans + 1))
                local fan_hex=$(to_hex "$((fan - 1))")
                if $ipmi_base_cmd raw 0x30 0x30 0x02 "$fan_hex" "$hex_speed" 2>/dev/null; then
                    success_count=$((success_count + 1))
                else
                    warn_log "Failed to set fan $fan speed to $speed%, continuing with other fans"
                fi
            done
            
            if [ $success_count -eq 0 ] && [ $total_fans -gt 0 ]; then
                error_log "Failed to set any fans to $speed%"
                return 1
            fi
            
            if [ $success_count -lt $total_fans ]; then
                warn_log "Set $success_count out of $total_fans fans to $speed%"
            else
                debug_log "Successfully set all $total_fans fans to $speed%"
            fi
            ;;
            
        "DISABLE_PCIE_RESPONSE")
            if [ "$DRY_RUN" = "y" ]; then
                debug_log "DRY-RUN: Would disable PCIe response"
                return 0
            fi
            if ! $ipmi_base_cmd raw 0x30 0xce 0x00 0x16 0x05 0x00 0x00 0x00 0x05 0x00 0x01 0x00 0x00 2>/dev/null; then
                warn_log "Failed to disable PCIe response"
                return 1
            fi
            ;;
            
        "CHECK_POWER_STATUS")
            if ! $ipmi_base_cmd chassis power status 2>/dev/null; then
                error_log "Failed to check power status"
                return 1
            fi
            ;;
            
        "ENABLE_LAN_CHANNEL")
            if [ "$DRY_RUN" = "y" ]; then
                debug_log "DRY-RUN: Would enable LAN channel"
                return 0
            fi
            if ! $ipmi_base_cmd lan set 1 access on 2>/dev/null; then
                error_log "Failed to enable LAN channel"
                return 1
            fi
            ;;
            
        "SET_LAN_PRIVILEGE")
            if [ "$DRY_RUN" = "y" ]; then
                debug_log "DRY-RUN: Would set LAN privilege"
                return 0
            fi
            if ! $ipmi_base_cmd lan set 1 privilege 4 2>/dev/null; then
                error_log "Failed to set LAN privilege"
                return 1
            fi
            ;;
            
        "READ_FAN_STATUS")
            if ! $ipmi_base_cmd sdr type fan 2>/dev/null; then
                error_log "Failed to read fan status"
                return 1
            fi
            ;;
            
        *)
            error_log "Unknown IPMI command type: $command_type"
            return 1
            ;;
    esac
    
    return 0
}

# Wrapper functions for backward compatibility
set_all_fans_speed() {
    send_ipmi_command "SET_ALL_FANS_SPEED" "$1"
}

set_fan_speed() {
    send_ipmi_command "SET_SPECIFIC_FANS_SPEED" "$1" "$2"
}
