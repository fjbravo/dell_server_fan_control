#!/bin/bash

# Function to check if MQTT is configured
mqtt_is_configured() {
    # Check if all required MQTT variables are set
    if [ -z "$MQTT_BROKER" ] || [ -z "$MQTT_PORT" ]; then
        return 1  # Not configured
    fi
    return 0  # Configured
}

# MQTT timeout in seconds (how long to wait for broker connection)
MQTT_TIMEOUT=3

# Maximum consecutive MQTT failures before disabling
MQTT_MAX_FAILURES=3

# Track consecutive MQTT failures
MQTT_FAILURE_COUNT=0

# Function to publish a message to an MQTT topic
mqtt_publish() {
    local topic="$1"
    local message="$2"
    
    # Check if MQTT is configured
    if ! mqtt_is_configured; then
        debug_log "MQTT not configured, skipping publish"
        return 0
    fi
    
    # Check if MQTT has been disabled due to failures
    if [ "$MQTT_FAILURE_COUNT" -ge "$MQTT_MAX_FAILURES" ]; then
        debug_log "MQTT publishing disabled due to consecutive failures"
        return 0
    fi
    
    # Check if mosquitto_pub command exists
    if ! command -v mosquitto_pub >/dev/null 2>&1; then
        warn_log "mosquitto_pub command not found. MQTT publishing disabled."
        return 1
    fi
    
    # Build the base command
    local mqtt_cmd="mosquitto_pub -h $MQTT_BROKER -p $MQTT_PORT"
    
    # Add timeout to prevent hanging
    mqtt_cmd="$mqtt_cmd -W $MQTT_TIMEOUT"
    
    # Add authentication if configured
    if [ -n "$MQTT_USER" ] && [ -n "$MQTT_PASS" ]; then
        mqtt_cmd="$mqtt_cmd -u $MQTT_USER -P $MQTT_PASS"
    fi
    
    # Add TLS if configured
    if [ "$MQTT_TLS" = "y" ]; then
        mqtt_cmd="$mqtt_cmd --tls-version tlsv1.2"
        
        # Add CA certificate if provided
        if [ -n "$MQTT_CA_CERT" ] && [ -f "$MQTT_CA_CERT" ]; then
            mqtt_cmd="$mqtt_cmd --cafile $MQTT_CA_CERT"
        fi
        
        # Add client certificate if provided
        if [ -n "$MQTT_CLIENT_CERT" ] && [ -f "$MQTT_CLIENT_CERT" ]; then
            mqtt_cmd="$mqtt_cmd --cert $MQTT_CLIENT_CERT"
        fi
        
        # Add client key if provided
        if [ -n "$MQTT_CLIENT_KEY" ] && [ -f "$MQTT_CLIENT_KEY" ]; then
            mqtt_cmd="$mqtt_cmd --key $MQTT_CLIENT_KEY"
        fi
    fi
    
    # Add topic and message
    local full_topic="servers/${HOSTNAME}/$topic"
    mqtt_cmd="$mqtt_cmd -t \"$full_topic\" -m \"$message\""
    
    # Execute the command
    if [ "$DRY_RUN" = "y" ]; then
        debug_log "DRY-RUN: Would publish to MQTT: $mqtt_cmd"
        return 0
    fi
    
    # Run in background to prevent blocking
    (
        # Use eval to properly handle the quoted arguments
        if ! eval $mqtt_cmd >/dev/null 2>&1; then
            warn_log "Failed to publish to MQTT topic: $full_topic"
            # Increment failure counter (atomic operation)
            echo "$((MQTT_FAILURE_COUNT + 1))" > /tmp/mqtt_failure_count.$$
            return 1
        else
            # Reset failure counter on success
            echo "0" > /tmp/mqtt_failure_count.$$
            debug_log "Published to MQTT topic: $full_topic"
            return 0
        fi
    ) &
    
    # Update failure counter from background process if file exists
    if [ -f "/tmp/mqtt_failure_count.$$" ]; then
        MQTT_FAILURE_COUNT=$(cat /tmp/mqtt_failure_count.$$)
        rm -f /tmp/mqtt_failure_count.$$
        
        # Log if MQTT has been disabled
        if [ "$MQTT_FAILURE_COUNT" -ge "$MQTT_MAX_FAILURES" ]; then
            warn_log "MQTT publishing disabled after $MQTT_MAX_FAILURES consecutive failures"
        fi
    fi
    
    return 0
}

# Function to reset MQTT failure counter
mqtt_reset_failures() {
    MQTT_FAILURE_COUNT=0
    debug_log "MQTT failure counter reset"
}

# Function to publish system metrics
mqtt_publish_metrics() {
    local cpu_temps="$1"
    local gpu_temps="$2"
    local base_fan_percent="$3"
    local gpu_fans="$4"
    local gpu_extra_percent="${5:-0}"
    local status="$6"
    
    # Check if MQTT is configured
    if ! mqtt_is_configured; then
        return 0
    fi
    
    # Check if MQTT has been disabled due to failures
    if [ "$MQTT_FAILURE_COUNT" -ge "$MQTT_MAX_FAILURES" ]; then
        # Try to reset every 10 minutes (60 cycles with default 10s loop time)
        if [ "$((RANDOM % 60))" -eq 0 ]; then
            mqtt_reset_failures
            debug_log "Attempting to re-enable MQTT publishing"
        else
            return 0
        fi
    fi
    
    # Create JSON payload
    local timestamp=$(date +%s)
    local payload="{"
    payload+="\"timestamp\":$timestamp,"
    payload+="\"hostname\":\"$HOSTNAME\","
    payload+="\"status\":\"$status\","
    
    # Add CPU temperatures
    payload+="\"cpu_temps\":["
    local first=true
    IFS=',' read -ra CPU_TEMPS <<< "$cpu_temps"
    for temp in "${CPU_TEMPS[@]}"; do
        if [ "$first" = true ]; then
            first=false
        else
            payload+=","
        fi
        payload+="$temp"
    done
    payload+="],"
    
    # Add GPU temperatures if available
    payload+="\"gpu_temps\":["
    first=true
    if [ -n "$gpu_temps" ]; then
        IFS=',' read -ra GPU_TEMPS <<< "$gpu_temps"
        for temp in "${GPU_TEMPS[@]}"; do
            if [ "$first" = true ]; then
                first=false
            else
                payload+=","
            fi
            payload+="$temp"
        done
    fi
    payload+="],"
    
    # Add fan speeds
    payload+="\"base_fan_percent\":$base_fan_percent,"
    
    # Add GPU fan information if applicable
    if [ -n "$gpu_extra_percent" ] && [ "$gpu_extra_percent" -gt 0 ]; then
        gpu_final_percent=$((base_fan_percent + gpu_extra_percent))
        if [ "$gpu_final_percent" -gt 100 ]; then
            gpu_final_percent=100
        fi
        payload+="\"gpu_fan_percent\":$gpu_final_percent,"
    else
        payload+="\"gpu_fan_percent\":$base_fan_percent,"
    fi
    
    # Add GPU fan IDs
    payload+="\"gpu_fans\":["
    first=true
    IFS=',' read -ra FANS <<< "$gpu_fans"
    for fan in "${FANS[@]}"; do
        if [ "$first" = true ]; then
            first=false
        else
            payload+=","
        fi
        payload+="$fan"
    done
    payload+="],"
    
    # Add PID
    payload+="\"pid\":$$"
    
    # Close JSON
    payload+="}"
    
    # Publish metrics
    mqtt_publish "metrics" "$payload"
}

# Function to publish system status
mqtt_publish_status() {
    local status="$1"
    local message="$2"
    
    # Check if MQTT is configured
    if ! mqtt_is_configured; then
        return 0
    fi
    
    # Check if MQTT has been disabled due to failures
    if [ "$MQTT_FAILURE_COUNT" -ge "$MQTT_MAX_FAILURES" ]; then
        # For status messages, always try to send regardless of failure count
        # as these are typically important state changes
        mqtt_reset_failures
        debug_log "Attempting to send status message despite previous failures"
    fi
    
    # Create JSON payload
    local timestamp=$(date +%s)
    local payload="{"
    payload+="\"timestamp\":$timestamp,"
    payload+="\"hostname\":\"$HOSTNAME\","
    payload+="\"status\":\"$status\","
    payload+="\"message\":\"$message\""
    payload+="}"
    
    # Publish status
    mqtt_publish "status" "$payload"
}
