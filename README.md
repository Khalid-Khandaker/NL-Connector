# NiceLabel Connector (Headless)

## What it does
- Reads READY rows from Supabase
- Validates against the CSV contract
- Generates a CSV per batch_id
- Copies the CSV into the Windows NiceLabel watch folder via SMB
- Archives successful files and stores validation failures under /opt/nl-connector/error

## Customer responsibilities
Customer owns:
- NiceLabel template design
- NiceLabel Automation configuration
- printer drivers and printer selection
- Windows watch folder path and permissions

Customer IT owns:
- SMB share setup
- network access between Ubuntu and Windows
- credential rotation for the share

## Install steps (Ubuntu)
1) Copy templates and fill them:
   - config/config.env.template -> config/config.env
   - config/smb-credentials.template -> config/smb-credentials

2) Run installer (requires Windows LAN IP, not VirtualBox 192.168.56.x):
   sudo WINDOWS_IP=<windows_wifi_or_ethernet_ip> ./install.sh

## Verify
- Timer:
  systemctl list-timers | grep nl-connector

- Logs:
  tail -n 50 /var/log/nl-connector/connector.log

- SMB mount:
  ls -la /mnt/nicelabel/in

## Stop/Start
- Stop:
  sudo systemctl stop nl-connector.timer

- Start:
  sudo systemctl start nl-connector.timer
