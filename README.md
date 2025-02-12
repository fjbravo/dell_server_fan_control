# dell_server_fan_control
Simple linux bash scripts to get the highest CPU temperature from lm-sensors, and set the fan speed according to user settings via ipmitool.

Disclaimer: I am not responsible for what this does to your hardware. It is entirely your responsibility to monitor what is going on with your hardware. Use at your own risk.

I made this to run on my proxmox server, which runs Debian. YMMV. My used Poweredge R730xd came with a bad motherboard. After replacing with a used motherboard from eBay, I found that board would not increase the fan speed when cpu temps were hight. It could hit thermal throttle with no increase in fan speed. 

Instead of setting the fans to a constant speed (creating too much noise, and increasing power draw for no reason), I wrote this script that figures out what percentage the fans should be based on CPU temps and user settings. 

I've seen other scripts out there, and while they do work, many send unnecessary commands, have limited ranges for fan speed, don't have hystoresis, or were simply not designed to control a system's fan speeds entirely.

With the main fan control script, simply set the MIN_TEMP to where the fan speed should be 0%. Set MAX_TEMP where the fan should be 100% and FAN_MIN to the bare minimum fan speed if you would like them not to go below a certain PWM percentage. Set the hysteresis options, other described variables and follow below.

If you set the FAN_MIN to 15, and set MIN_TEMP to 40, fan speeds will stay at 15 until the calculated fan speed exceeds 15%. This means you won't see an increase in fan speeds until somewhere above 4x or 5x degrees depending on all 3 variables. You may have to play around with values to find the ranges you are looking for.

Installation:

To install the application, run:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/fjbravo/dell_server_fan_control/feature/add-installation-script/install.sh)"
```

Note: Ensure IPMI is enabled in your iDRAC settings before installation.

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

### Temperature Control Settings
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

### Monitoring Settings
```bash
LOOP_TIME="10"              # How often to check temperatures (in seconds)
LOG_FREQUENCY="6"           # How often to log when system is stable (in cycles)
LOG_FILE="/var/log/fan_control.log"  # Log file location
CLEAR_LOG="y"              # Clear log on service start (y/n)
DEBUG="n"                  # Enable verbose logging (y/n)
```

### Dynamic Configuration
The service automatically reloads the configuration every 60 seconds. You can modify settings while the service is running:
1. Edit config.env: `sudo nano /usr/local/bin/dell-fan-control/config.env`
2. Changes will take effect within 60 seconds
3. No service restart required

### Monitoring Commands
```bash
# View real-time fan control logs
sudo tail -f /var/log/fan_control.log

# View service logs
sudo journalctl -fu dell_ipmi_fan_control    # Follow logs in real-time
sudo journalctl -u dell_ipmi_fan_control     # Show all logs

# Check service status
sudo systemctl status dell_ipmi_fan_control

# Service control
sudo systemctl stop dell_ipmi_fan_control     # Stop the service
sudo systemctl start dell_ipmi_fan_control    # Start the service
sudo systemctl restart dell_ipmi_fan_control  # Restart the service
```

### Log Messages
The log file shows different types of messages:
- ✓ Normal operation (e.g., "System stable - Temp: 45°C, Fan: 35%")
- ⚡ Changes detected (e.g., "Temperature change detected")
- ↑↓ Fan speed adjustments
- ⚠ Warnings and critical events
- ⚙ Configuration changes
