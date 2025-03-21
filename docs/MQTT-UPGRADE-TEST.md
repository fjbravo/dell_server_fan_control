# MQTT Upgrade Test Scenarios

This document outlines test scenarios for verifying the upgrade process from non-MQTT to MQTT-enabled versions of the Dell Server Fan Control system.

## Test Environment Setup

Before running the tests, prepare the following environments:

1. **Fresh System**: A clean system with no previous installation
2. **Legacy System**: A system with v1.1.0 installed (pre-MQTT version)
3. **Existing MQTT System**: A system with v1.2.0 already installed with custom MQTT settings

## Test Scenario 1: Fresh Installation

**Objective**: Verify that a fresh installation includes MQTT components and proper configuration.

### Steps:

1. Run the installation script on a clean system:
   ```bash
   sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/fjbravo/dell_server_fan_control/feature/server-monitoring/install.sh)"
   ```

2. Verify dependencies:
   ```bash
   dpkg -l | grep mosquitto-clients
   ```

3. Check configuration:
   ```bash
   grep -A 15 "MQTT Settings" /usr/local/bin/dell-fan-control/config.env
   ```

4. Verify service status:
   ```bash
   sudo systemctl status dell_ipmi_fan_control
   ```

5. Check logs for MQTT initialization:
   ```bash
   sudo grep -i mqtt /var/log/fan_control.log
   ```

### Expected Results:

- mosquitto-clients package is installed
- config.env contains MQTT settings section with empty MQTT_BROKER
- Service starts successfully
- Logs show "MQTT not configured, skipping publish" messages

## Test Scenario 2: Upgrade from v1.1.0 (non-MQTT)

**Objective**: Verify that upgrading from a pre-MQTT version preserves existing settings and adds MQTT configuration.

### Preparation:

1. Install v1.1.0 (pre-MQTT version)
2. Configure with custom settings (CPU/GPU temperatures, fan assignments)
3. Verify the system is working correctly

### Steps:

1. Run the upgrade:
   ```bash
   sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/fjbravo/dell_server_fan_control/feature/server-monitoring/install.sh)"
   ```

2. Verify dependencies:
   ```bash
   dpkg -l | grep mosquitto-clients
   ```

3. Check configuration preservation:
   ```bash
   grep -A 5 "CPU_MIN_TEMP" /usr/local/bin/dell-fan-control/config.env
   ```

4. Check MQTT settings were added:
   ```bash
   grep -A 15 "MQTT Settings" /usr/local/bin/dell-fan-control/config.env
   ```

5. Verify service status:
   ```bash
   sudo systemctl status dell_ipmi_fan_control
   ```

6. Check logs for MQTT initialization:
   ```bash
   sudo grep -i mqtt /var/log/fan_control.log
   ```

### Expected Results:

- Original custom settings are preserved
- MQTT settings section is added with empty MQTT_BROKER
- mosquitto-clients package is installed
- Service restarts successfully
- Logs show "MQTT not configured, skipping publish" messages

## Test Scenario 3: Manual MQTT Configuration

**Objective**: Verify that MQTT can be manually configured after upgrade.

### Steps:

1. Edit configuration to enable MQTT:
   ```bash
   sudo nano /usr/local/bin/dell-fan-control/config.env
   ```
   
   Set:
   ```
   MQTT_BROKER="localhost"
   MQTT_PORT="1883"
   ```

2. Restart the service:
   ```bash
   sudo systemctl restart dell_ipmi_fan_control
   ```

3. Check logs for MQTT connection:
   ```bash
   sudo grep -i mqtt /var/log/fan_control.log
   ```

4. Subscribe to MQTT topics to verify publishing:
   ```bash
   mosquitto_sub -h localhost -t "servers/$(hostname)/#" -v
   ```

### Expected Results:

- Service restarts successfully
- Logs show MQTT connection attempts
- MQTT messages are published to the broker

## Test Scenario 4: Migration Script

**Objective**: Verify that the migration script correctly adds MQTT settings to an existing configuration.

### Steps:

1. Create a backup of the current config:
   ```bash
   sudo cp /usr/local/bin/dell-fan-control/config.env /usr/local/bin/dell-fan-control/config.env.backup
   ```

2. Remove MQTT settings (simulating pre-MQTT version):
   ```bash
   sudo sed -i '/MQTT/d' /usr/local/bin/dell-fan-control/config.env
   sudo sed -i '/mqtt/d' /usr/local/bin/dell-fan-control/config.env
   ```

3. Run the migration script:
   ```bash
   sudo /usr/local/bin/dell-fan-control/migrate_config.sh
   ```

4. Check the updated configuration:
   ```bash
   grep -A 15 "MQTT Settings" /usr/local/bin/dell-fan-control/config.env
   ```

### Expected Results:

- Script runs without errors
- MQTT settings section is added to the configuration
- Original settings are preserved

## Test Scenario 5: Upgrade with Existing MQTT Settings

**Objective**: Verify that upgrading a system that already has MQTT configured preserves those settings.

### Preparation:

1. Configure system with custom MQTT settings:
   ```
   MQTT_BROKER="test.mosquitto.org"
   MQTT_PORT="1883"
   MQTT_USER="testuser"
   MQTT_PASS="testpass"
   ```

2. Verify MQTT is working

### Steps:

1. Run the upgrade:
   ```bash
   sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/fjbravo/dell_server_fan_control/feature/server-monitoring/install.sh)"
   ```

2. Check configuration preservation:
   ```bash
   grep -A 15 "MQTT Settings" /usr/local/bin/dell-fan-control/config.env
   ```

3. Verify service status:
   ```bash
   sudo systemctl status dell_ipmi_fan_control
   ```

4. Check logs for MQTT connection:
   ```bash
   sudo grep -i mqtt /var/log/fan_control.log
   ```

### Expected Results:

- Custom MQTT settings are preserved
- Service restarts successfully
- MQTT connection is established with the configured broker

## Test Scenario 6: Rollback

**Objective**: Verify that the backup created during upgrade can be used to restore the previous version if needed.

### Steps:

1. Locate the backup directory:
   ```bash
   ls -la /tmp/dell-fan-control-backup-*
   ```

2. Stop the service:
   ```bash
   sudo systemctl stop dell_ipmi_fan_control
   ```

3. Restore from backup:
   ```bash
   sudo cp -r /tmp/dell-fan-control-backup-XXXXXXXX_XXXXXX/* /usr/local/bin/dell-fan-control/
   sudo cp /tmp/dell-fan-control-backup-XXXXXXXX_XXXXXX/dell_ipmi_fan_control.service /etc/systemd/system/
   ```

4. Reload systemd and restart:
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl start dell_ipmi_fan_control
   ```

5. Verify service status:
   ```bash
   sudo systemctl status dell_ipmi_fan_control
   ```

### Expected Results:

- Service is restored to the previous version
- Original configuration is restored
- Service starts successfully

## Test Scenario 7: Edge Cases

### Test 7.1: Interrupted Upgrade

**Objective**: Verify system integrity when upgrade is interrupted.

### Steps:

1. Start the upgrade process
2. Interrupt it (e.g., Ctrl+C or kill the process)
3. Run the upgrade again
4. Verify system status

### Expected Results:

- Second upgrade completes successfully
- System is in a consistent state
- Service starts correctly

### Test 7.2: Missing Dependencies

**Objective**: Verify that the installer handles missing dependencies correctly.

### Steps:

1. Remove mosquitto-clients:
   ```bash
   sudo apt-get remove mosquitto-clients
   ```

2. Run the upgrade
3. Verify dependencies installation

### Expected Results:

- Installer detects missing mosquitto-clients
- Dependency is automatically installed
- Upgrade completes successfully

## Reporting Issues

If any test fails, please report the issue with:

1. Test scenario that failed
2. Expected vs. actual results
3. Relevant log entries
4. System information (OS version, hardware)

Submit issues to: https://github.com/fjbravo/dell_server_fan_control/issues
