# dell_server_fan_control
Linux bash scripts to control Dell server fans based on CPU and GPU temperatures using lm-sensors and nvidia-smi, with fan speed control via ipmitool.

Disclaimer: I am not responsible for what this does to your hardware. It is entirely your responsibility to monitor what is going on with your hardware. Use at your own risk.

## Features

### CPU Temperature Control
- Dynamic fan speed control based on CPU temperature
- Configurable minimum and maximum temperature thresholds
- Hysteresis to prevent rapid fan speed changes
- Emergency shutdown protection
- Minimum fan speed setting

### GPU Temperature Control (New!)
- NVIDIA GPU temperature monitoring via nvidia-smi
- Independent control of GPU-specific fans (default: fans 5 and 6)
- Separate temperature thresholds and hysteresis settings for GPU
- Automatic detection of NVIDIA GPUs
- Graceful fallback if GPU monitoring fails
- Automatic enabling/disabling based on GPU presence
- Can run with or without GPU monitoring enabled
- Safe initialization and error handling

### General Features
- Efficient IPMI commands to minimize system impact
- Dynamic configuration reloading
- Detailed logging with different message types
- Systemd service integration
- Easy installation and configuration

## Background
This script was originally created for a Proxmox server running on a Dell PowerEdge R730xd with a replacement motherboard that had issues with fan control. Instead of setting fans to a constant speed (creating unnecessary noise and power consumption), this script dynamically adjusts fan speeds based on temperature readings.

## Installation

To install the application with GPU monitoring support, run:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/fjbravo/dell_server_fan_control/feature/gpu-monitoring/install.sh)"
```

Prerequisites:
- IPMI must be enabled in your iDRAC settings
- For GPU monitoring: NVIDIA drivers must be installed

The installation script will:
- Install required dependencies (lm-sensors and ipmitool)
- Install the scripts to /usr/local/bin/dell-fan-control/
- Create and enable a systemd service
- Start the fan control service with default settings

Configuration:
-------------
All settings are stored in `/usr/local/bin/dell-fan-control/config.env`. The following options are available:

### iDRAC Settings
```bash
IDRAC_IP="192.168.0.20"      # IP address of your iDRAC
IDRAC_USER="root"            # iDRAC username
IDRAC_PASSWORD="calvin"      # iDRAC password
```

### CPU Temperature Control Settings
```bash
# Minimum fan speed (percentage)
FAN_MIN="12"                 # Fans will never go below this speed

# Temperature thresholds (in Celsius)
MIN_TEMP="40"               # Temperature at which fans start ramping up
MAX_TEMP="80"               # Temperature at which fans reach 100%
TEMP_FAIL_THRESHOLD="83"    # Emergency shutdown temperature

# Hysteresis settings (prevents rapid fan speed changes)
HYST_WARMING="3"            # Degrees increase needed before speeding up fans
HYST_COOLING="4"            # Degrees decrease needed before slowing down fans
```

### GPU Temperature Control Settings
```bash
# Enable/disable GPU monitoring
GPU_MONITORING="y"          # Set to "n" to disable GPU monitoring

# GPU temperature thresholds (in Celsius)
GPU_MIN_TEMP="30"          # Temperature at which GPU fans start ramping up
GPU_MAX_TEMP="75"          # Temperature at which GPU fans reach 100%
GPU_FAIL_THRESHOLD="90"    # Emergency shutdown temperature

# GPU hysteresis settings
GPU_HYST_WARMING="2"       # Degrees increase needed before speeding up fans
GPU_HYST_COOLING="3"       # Degrees decrease needed before slowing down fans

# Fan assignment
GPU_FAN_IDS="5,6"         # Comma-separated list of fan IDs for GPU cooling
```

### Monitoring Settings
```bash
LOOP_TIME="10"              # How often to check temperatures (in seconds)
LOG_FREQUENCY="6"           # How often to log when system is stable (in cycles)
LOG_FILE="/var/log/fan_control.log"  # Base log file location (timestamped files will be created)
DEBUG="n"                  # Enable verbose logging (y/n)
```

### Version History

#### v1.1.0 (2024-02-14)
- Added GPU temperature monitoring and fan control
- Added automatic NVIDIA GPU detection
- Added GPU-specific configuration options
- Added graceful fallback for GPU monitoring
- Fixed initialization issues
- Added comprehensive troubleshooting guide
- Enhanced error handling and logging

#### v1.0.0
- Initial release with CPU temperature monitoring
- Basic fan speed control
- Dynamic configuration reloading
- Systemd service integration

### Dynamic Configuration
The service automatically reloads the configuration every 60 seconds. You can modify settings while the service is running:
1. Edit config.env: `sudo nano /usr/local/bin/dell-fan-control/config.env`
2. Changes will take effect within 60 seconds
3. No service restart required

### Monitoring Commands
```bash
# View fan control logs
sudo tail -f /var/log/latest_fan_control.log     # Follow latest log in real-time
ls -l /var/log/fan_control_*.log                 # List all historical logs
sudo cat /var/log/fan_control_20240213_*.log     # View specific day's logs

# View logs with timestamps
sudo tail -f /var/log/latest_fan_control.log | while read line; do echo "$(date): $line"; done

# View service logs (systemd)
sudo journalctl -u dell_ipmi_fan_control         # Show all logs
sudo journalctl -fu dell_ipmi_fan_control        # Follow logs in real-time
sudo journalctl -u dell_ipmi_fan_control -b      # Show logs since last boot
sudo journalctl -u dell_ipmi_fan_control -n 50   # Show last 50 lines
sudo journalctl -u dell_ipmi_fan_control --output=short-precise  # Show detailed timestamps

# Check service status
sudo systemctl status dell_ipmi_fan_control

# Service control
sudo systemctl stop dell_ipmi_fan_control     # Stop the service
sudo systemctl start dell_ipmi_fan_control    # Start the service
sudo systemctl restart dell_ipmi_fan_control  # Restart the service
```

### Log Messages
The log file shows different types of messages:
- ✓ Normal operation
  * CPU only: "System stable - CPU Temp: 45°C, Fan: 35%"
  * With GPU: "System stable - CPU Temp: 45°C, CPU Fan: 35%, GPU Temp: 65°C, GPU Fan: 75%"
- ⚡ Changes detected
  * "CPU Temperature change detected (50°C)"
  * "GPU Temperature change detected (70°C)"
- ↑↓ Fan speed adjustments
  * "Setting minimum fan speed: 12%"
  * "Setting minimum GPU fan speed: 12%"
- ⚠ Warnings and critical events
  * "CRITICAL!!!! CPU Temperature 83°C exceeds shutdown threshold"
  * "CRITICAL!!!! GPU Temperature 90°C exceeds shutdown threshold"
  * "Failed to read GPU temperature. Disabling GPU monitoring."
- ⚙ Configuration changes and status
  * "Manual fan control verified"
  * "Configuration reloaded"
  * "NVIDIA GPU detected" (during installation)

### Troubleshooting

#### GPU Monitoring Issues
1. If GPU monitoring fails:
   - The script will automatically disable GPU monitoring
   - CPU fan control will continue to work normally
   - Check nvidia-smi command manually: `nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits`
   - Verify NVIDIA drivers are installed: `nvidia-smi -L`

2. To re-enable GPU monitoring after fixing driver issues:
   - Edit config: `sudo nano /usr/local/bin/dell-fan-control/config.env`
   - Set `GPU_MONITORING="y"`
   - Wait for configuration reload (up to 60 seconds)

#### Fan Control
1. Default GPU fans (5,6) not optimal for your setup:
   - Check fan layout: `ipmitool sensor list | grep Fan`
   - Edit `GPU_FAN_IDS` in config.env with appropriate fan numbers
   - Multiple fans can be specified: e.g., `GPU_FAN_IDS="4,5,6"`

#### Common Issues
1. "integer expression expected" error:
   - Fixed in latest version
   - Reinstall using the installation command to update
   
2. GPU temperature not being detected:
   - Check if GPU is recognized: `lspci | grep -i nvidia`
   - Verify drivers are loaded: `lsmod | grep nvidia`
   - Check NVIDIA driver status: `systemctl status nvidia-*`

3. Fan speeds not changing:
   - Verify iDRAC settings allow fan control
   - Check iDRAC credentials in config.env
   - Ensure IPMI over LAN is enabled
   - Test manual fan control: `ipmitool raw 0x30 0x30 0x01 0x00`
