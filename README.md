# dell_server_fan_control
Linux bash scripts to control Dell server fans based on CPU and GPU temperatures using lm-sensors and nvidia-smi, with fan speed control via ipmitool.

Disclaimer: I am not responsible for what this does to your hardware. It is entirely your responsibility to monitor what is going on with your hardware. Use at your own risk.

I made this to run on my proxmox server, which runs Debian. YMMV. My used Poweredge R730xd came with a bad motherboard. After replacing with a used motherboard from eBay, I found that board would not increase the fan speed when cpu temps were hight. It could hit thermal throttle with no increase in fan speed. 

Instead of setting the fans to a constant speed (creating too much noise, and increasing power draw for no reason), I wrote this script that figures out what percentage the fans should be based on CPU temps and user settings. 

I've seen other scripts out there, and while they do work, many send unnecessary commands, have limited ranges for fan speed, don't have hystoresis, or were simply not designed to control a system's fan speeds entirely.

With the main fan control script, simply set the MIN_TEMP to where the fan speed should be 0%. Set MAX_TEMP where the fan should be 100% and FAN_MIN to the bare minimum fan speed if you would like them not to go below a certain PWM percentage. Set the hysteresis options, other described variables and follow below.

If you set the FAN_MIN to 15, and set MIN_TEMP to 40, fan speeds will stay at 15 until the calculated fan speed exceeds 15%. This means you won't see an increase in fan speeds until somewhere above 4x or 5x degrees depending on all 3 variables. You may have to play around with values to find the ranges you are looking for.

Installation:

To install the standard version (CPU monitoring only), run:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/fjbravo/dell_server_fan_control/main/install.sh)"
```

To install the version with GPU temperature monitoring, run:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/fjbravo/dell_server_fan_control/gpu-temp-monitoring/install.sh)"
```

Notes: 
- Ensure IPMI is enabled in your iDRAC settings before installation
- For GPU monitoring, ensure NVIDIA drivers are installed and nvidia-smi is available
- The GPU monitoring version requires additional configuration (see GPU Settings below)

The installation script will:
1. Check and install required dependencies
2. Detect NVIDIA GPU if present
3. Install scripts and service
4. Create initial configuration
5. Start the fan control service

### Uninstallation

To uninstall the application, run:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/fjbravo/dell_server_fan_control/main/uninstall.sh)"
```

The uninstall script will:
1. Stop and disable the service
2. Create a backup of your configuration
3. Remove all installed files
4. Restore Dell's default fan control
5. Clean up systemd configuration

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

# CPU Temperature Settings
CPU_MIN_TEMP="40"           # Temperature at which CPU fans start ramping up
CPU_MAX_TEMP="80"           # Temperature at which CPU fans reach 100%
CPU_TEMP_FAIL_THRESHOLD="83" # Emergency shutdown temperature for CPU

# GPU Temperature Settings (only in GPU monitoring version)
GPU_MIN_TEMP="30"           # Temperature at which GPU fans start ramping up
GPU_MAX_TEMP="85"           # Temperature at which GPU fans reach 100%
GPU_TEMP_FAIL_THRESHOLD="90" # Emergency shutdown temperature for GPU

# Fan Zone Settings (only in GPU monitoring version)
GPU_FANS="1,2"             # Comma-separated list of fans near the GPU (e.g., "1,2")
CPU_FANS="3,4,5,6"         # Comma-separated list of fans for CPU cooling

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

### GPU Temperature Monitoring
The GPU monitoring version provides intelligent fan control that considers both CPU and GPU temperatures:

1. Base Fan Speed:
   - All fans respond to CPU temperature as a baseline
   - This ensures proper cooling for the entire system
   - Base speed is calculated using CPU_MIN_TEMP and CPU_MAX_TEMP

2. GPU-Specific Cooling:
   - If GPU temperature requires higher fan speeds than the CPU-based baseline:
     * Only the GPU-designated fans (GPU_FANS) get an extra speed boost
     * Extra speed = GPU required speed - CPU baseline speed
   - When GPU temperature is under control:
     * GPU fans run at the same speed as other fans
     * No extra power or noise when not needed

Example Scenario:
- CPU temperature requires 40% fan speed
- GPU temperature requires 60% fan speed
- Result:
  * All fans run at 40% (base speed from CPU temp)
  * GPU fans get additional 20% (running at 60%)
  * When GPU cools down, GPU fans return to base speed

### Log Messages
The log file shows different types of messages:
- ✓ Normal operation (e.g., "System stable - CPU Temp: 45°C (All Fans: 35%), GPU Temp: 55°C (GPU Fans: +10% = 45%)")
- ⚡ Changes detected (e.g., "Temperature change detected")
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
