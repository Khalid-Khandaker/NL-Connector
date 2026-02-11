# Demo checklist

## Pre-demo
- Windows share accessible and writable:
  - \\WINDOWS_IP\NiceLabelIn works on Windows
- Ubuntu mount works:
  - sudo -u nlconnector touch /mnt/nicelabel/in/demo_test.txt
- Timer running:
  - systemctl list-timers | grep nl-connector

## Demo flow
1) Insert/trigger a READY batch from upstream system (or demo rows in Supabase).
2) Show connector logs:
   - tail -n 30 /var/log/nl-connector/connector.log
3) Show CSV appears in Windows watch folder.
4) Show NiceLabel Automation picks up the file (prints or moves/archives per their config).
5) Demo a validation failure:
   - invalid qty
   - show /opt/nl-connector/error/<run_id>/<site>/ files
6) Explain responsibility boundaries and support process.
