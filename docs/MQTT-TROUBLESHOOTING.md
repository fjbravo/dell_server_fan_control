# MQTT Troubleshooting Guide

This document provides detailed troubleshooting steps for common MQTT issues with the Dell Server Fan Control system.

## Table of Contents

- [Diagnosing MQTT Issues](#diagnosing-mqtt-issues)
- [Common Error Patterns](#common-error-patterns)
- [Docker-Specific Issues](#docker-specific-issues)
- [Network Connectivity](#network-connectivity)
- [Authentication Problems](#authentication-problems)
- [TLS/SSL Issues](#tlsssl-issues)
- [Circuit Breaker Recovery](#circuit-breaker-recovery)
- [Performance Considerations](#performance-considerations)

## Diagnosing MQTT Issues

### Check System Logs

The fan control system logs MQTT-related issues:

```bash
# View the last 50 log entries
tail -n 50 /var/log/fan_control.log | grep -i mqtt

# Search for MQTT failures
grep -i "mqtt.*fail" /var/log/fan_control.log

# Check for circuit breaker activation
grep -i "mqtt.*disabled" /var/log/fan_control.log
```

### Verify MQTT Configuration

Check your current MQTT settings:

```bash
# Display MQTT settings
grep "^MQTT_" /path/to/config.env
```

### Test MQTT Connectivity

Test basic connectivity to your MQTT broker:

```bash
# Install netcat if needed
sudo apt-get install netcat

# Test TCP connectivity to broker
nc -zv your-mqtt-broker 1883

# For TLS connections
nc -zv your-mqtt-broker 8883
```

## Common Error Patterns

### 1. "MQTT not configured, skipping publish"

**Cause**: MQTT_BROKER is empty or not set in config.env.

**Solution**: 
```bash
# Edit config.env
MQTT_BROKER="your-broker-address"
MQTT_PORT="1883"
```

### 2. "mosquitto_pub command not found"

**Cause**: Mosquitto clients are not installed.

**Solution**:
```bash
# Debian/Ubuntu
sudo apt-get install mosquitto-clients

# RHEL/CentOS
sudo yum install mosquitto-clients
```

### 3. "Failed to publish to MQTT topic"

**Cause**: Connection issues with the MQTT broker.

**Solutions**:
- Verify broker is running
- Check network connectivity
- Increase timeout: `MQTT_TIMEOUT="5"`
- Verify authentication credentials

### 4. "MQTT publishing disabled after X consecutive failures"

**Cause**: Circuit breaker has tripped due to multiple failures.

**Solutions**:
- Fix the underlying connection issue
- Restart the fan control service to reset the circuit breaker
- Increase failure threshold: `MQTT_MAX_FAILURES="5"`

## Docker-Specific Issues

### Container Won't Start

```bash
# Check for port conflicts
sudo lsof -i :1883

# Verify Docker logs
docker logs mqtt-broker

# Check container status
docker ps -a | grep mqtt-broker
```

**Common Solutions**:
- Change the host port mapping: `-p 1884:1883`
- Stop any existing Mosquitto service: `sudo systemctl stop mosquitto`
- Check disk space: `df -h`

### Volume Permission Issues

```bash
# Check volume permissions
ls -la ~/mosquitto/

# Fix permissions
sudo chown -R 1883:1883 ~/mosquitto/
# OR
sudo chmod -R 777 ~/mosquitto/  # Less secure but works for testing
```

### Configuration Problems

```bash
# Validate Mosquitto config
docker exec mqtt-broker mosquitto_sub -h localhost -t test

# Check config file
cat ~/mosquitto/config/mosquitto.conf
```

**Common Solutions**:
- Ensure config file has correct line endings (LF, not CRLF)
- Verify config file is mounted correctly
- Check for syntax errors in config

## Network Connectivity

### Firewall Issues

```bash
# Check if firewall is blocking MQTT
sudo iptables -L | grep 1883

# Allow MQTT traffic
sudo iptables -A INPUT -p tcp --dport 1883 -j ACCEPT
sudo iptables -A OUTPUT -p tcp --dport 1883 -j ACCEPT

# For persistent rules
sudo apt-get install iptables-persistent
sudo netfilter-persistent save
```

### DNS Resolution

```bash
# Test DNS resolution
nslookup your-mqtt-broker

# Add entry to hosts file if needed
echo "192.168.1.100 your-mqtt-broker" | sudo tee -a /etc/hosts
```

### Network Latency

```bash
# Test network latency
ping -c 10 your-mqtt-broker

# Increase timeout for high-latency connections
# Edit config.env
MQTT_TIMEOUT="10"
```

## Authentication Problems

### Username/Password Issues

```bash
# Test authentication
mosquitto_pub -h your-mqtt-broker -p 1883 -u username -P password -t test -m "test"

# Check broker logs for auth failures
docker logs mqtt-broker | grep -i auth

# Reset password in Docker
docker exec -it mqtt-broker mosquitto_passwd -c /mosquitto/config/passwd username
```

### Permission Denied

```bash
# Check ACLs if configured
cat ~/mosquitto/config/acl.conf

# Test with specific topic
mosquitto_pub -h your-mqtt-broker -t "allowed/topic" -m "test"
```

## TLS/SSL Issues

### Certificate Validation Failures

```bash
# Check certificate validity
openssl x509 -in /path/to/ca.crt -text -noout

# Test TLS connection
openssl s_client -connect your-mqtt-broker:8883

# Verify certificate chain
openssl verify -CAfile /path/to/ca.crt /path/to/client.crt
```

### Certificate Path Issues

```bash
# Check file permissions
ls -la /path/to/certificates/

# Ensure paths in config.env are absolute
MQTT_CA_CERT="/absolute/path/to/ca.crt"
```

### TLS Version Compatibility

```bash
# Test with specific TLS version
mosquitto_pub -h your-mqtt-broker -p 8883 --tls-version tlsv1.2 \
  --cafile /path/to/ca.crt -t test -m "test"
```

## Circuit Breaker Recovery

The fan control system implements a circuit breaker pattern to prevent MQTT issues from affecting core functionality.

### Manual Reset

```bash
# Restart the service to reset the circuit breaker
sudo systemctl restart dell_ipmi_fan_control
```

### Automatic Recovery

The system automatically attempts to reconnect periodically:

```bash
# Check for recovery attempts in logs
grep -i "re-enable mqtt" /var/log/fan_control.log
```

### Adjusting Circuit Breaker Parameters

```bash
# Edit config.env to adjust parameters
MQTT_MAX_FAILURES="5"  # Increase threshold before disabling
MQTT_TIMEOUT="5"       # Increase timeout for slow connections
```

## Performance Considerations

### Reducing MQTT Traffic

If MQTT publishing is causing high CPU usage:

```bash
# Reduce update frequency by increasing loop time
# Edit config.env
LOOP_TIME="30"  # Check every 30 seconds instead of default
```

### Monitoring Resource Usage

```bash
# Monitor CPU usage of fan control script
top -p $(pgrep -f fan_control.sh)

# Check for memory leaks
watch -n 1 "ps -o pid,ppid,cmd,%mem,%cpu --sort=-%mem | head -n 20"
```

### Broker Performance

```bash
# Check broker resource usage
docker stats mqtt-broker

# Monitor broker connections
docker exec mqtt-broker mosquitto_sub -t '$SYS/broker/clients/connected' -v
```

## Advanced Debugging

### Packet Capture

For detailed analysis of MQTT traffic:

```bash
# Install tcpdump
sudo apt-get install tcpdump

# Capture MQTT traffic
sudo tcpdump -i any port 1883 -w mqtt_capture.pcap

# Analyze with Wireshark
wireshark mqtt_capture.pcap
```

### Enabling Verbose Logging

```bash
# Enable debug logging in config.env
DEBUG="y"

# Restart the service
sudo systemctl restart dell_ipmi_fan_control

# Watch logs in real-time
tail -f /var/log/fan_control.log | grep -i mqtt
```

### Testing with Minimal Configuration

To isolate issues, test with a minimal configuration:

```bash
# Create a test config
cat > /tmp/test_mqtt.conf << EOF
listener 1883
allow_anonymous true
EOF

# Run a test broker
docker run -d --name mqtt-test -p 1884:1883 \
  -v /tmp/test_mqtt.conf:/mosquitto/config/mosquitto.conf \
  eclipse-mosquitto

# Test with the minimal broker
mosquitto_pub -h localhost -p 1884 -t test -m "test"
```
