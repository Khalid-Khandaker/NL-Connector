# NiceLabel Connector — Demo Instruction

**Version:** Updated for the current scripts, wrappers, and systemd timer behavior  
**Audience:** Demo user, supervisor, tester, or installer  
**Goal:** Run a repeatable end-to-end demo from **CalcMenu → Supabase → CSV → NiceLabel watch folder → print/output**

---

## What this connector does

The NiceLabel Connector is a small pipeline with two main stages:

1. **Selector service** — gets recipes that are ready to print from the CalcMenu-side API and inserts them into Supabase.
2. **Connector service** — reads approved rows from Supabase, creates a CSV file, and sends that CSV into the Windows NiceLabel watch folder.

Supporting parts:

- **Control API** for manual triggering, status checks, diagnostics, logs, and share updates
- **systemd timers** for scheduled runs
- **cleanup retention** for archive/error housekeeping

---

## High-level flow

```text
CalcMenu API / database
        ↓
selector.py
        ↓
Supabase queue table
        ↓
connector.py
        ↓
CSV file on mounted Windows SMB share
        ↓
NiceLabel Automation watch folder
        ↓
Label output / PDF / print
```

---

## Important setup decision for the demo

For this demo, assume:

- **Ubuntu** runs the connector
- **Windows host machine** runs NiceLabel and Postman
- Postman will call the connector **from the host machine**

Because of that, the demo only works smoothly if the host machine can reach the Ubuntu control API.

### Recommended VM networking for the demo

Use **Bridged Adapter** for the Ubuntu VM.

Why this is recommended:

- the Ubuntu VM gets its own IP on the same network
- the Windows host can call the API directly with Postman
- this is simpler than relying on port forwarding rules

### Alternative

If you use **NAT**, then you will usually need **VirtualBox port forwarding** for the control API port.

### Recommended demo approach

Use **Bridged Adapter** whenever possible.

---

## What the tester should prepare before starting

### On Windows host

Prepare these before installation:

- NiceLabel installed and working
- NiceLabel Automation configured to watch a shared input folder
- a Windows folder shared over SMB, for example:
  - `C:\NiceLabel\HotIn`
- Postman installed
- credentials for the Windows share
- the Windows machine IP address

### On Ubuntu VM

Prepare these before installation:

- Ubuntu with internet access
- `git` installed
- permission to use `sudo`
- network path from Ubuntu to the Windows SMB share
- access to Supabase
- access to the CalcMenu-side API that selector will call

---

## Clone the repository

Inside Ubuntu:

```bash
git clone https://github.com/Khalid-Khandaker/NL-Connector.git
cd NL-Connector
```

If the repository name is different in your environment, use the actual repository URL.

---

## Create the local config files

Copy the templates first:

```bash
cp config/config.env.template config/config.env
cp config/smb-credentials.template config/smb-credentials
```

Now edit them.

---

## Fill in `config/config.env`

Open the file:

```bash
nano config/config.env
```

Use your real values. Example structure only:

```env
# Supabase
SUPABASE_URL=https://your-project.supabase.co
SUPABASE_SERVICE_ROLE_KEY=your_service_role_key
SUPABASE_TABLE=csv_records

# CalcMenu API used by selector
CALCMENU_API_BASE_URL=http://<CALCMENU_API_HOST>:<PORT>
CALCMENU_API_KEY=your_calcmenu_api_key

# Control API used for demo and support
CONTROL_API_KEY=your_control_api_key
CONTROL_API_HOST=0.0.0.0
CONTROL_API_PORT=8088

# Windows share mount
WINDOWS_HOST=192.168.1.50
SHARE_NAME=NiceLabelHotIn
MOUNT_POINT=/mnt/nicelabel/in

# Schedules
SELECTOR_TIMES=06:00
CONNECTOR_MODE=schedule
CONNECTOR_TIMES=06:05,11:05,17:05
CONNECTOR_INTERVAL=2s
CONNECTOR_TRIGGER_AFTER_SELECTOR=false
CLEANUP_RETENTION_DAYS=30
CLEANUP_TIMES=06:30
```

### Notes

- `WINDOWS_HOST` should be the **Windows machine IP or resolvable hostname**.
- `SHARE_NAME` should be the **Windows share name**, not the full Windows path.
- `MOUNT_POINT` is the Linux mount path on Ubuntu.
- If Postman will call the API from the host machine, use:
  - `CONTROL_API_HOST=0.0.0.0`
- Keep `CONTROL_API_PORT=8088` unless you have a reason to change it.

---

## Fill in `config/smb-credentials`

Open the file:

```bash
nano config/smb-credentials
```

Example:

```ini
username=your_windows_username
password=your_windows_password
domain=
```

### Notes

- Leave `domain=` blank only if your setup does not need it.
- The Windows share must allow both:
  - **share permissions**
  - **NTFS permissions**

If either one blocks write access, the connector mount test will fail.

---

## Prepare the Windows share

On the Windows host:

1. Create the folder that NiceLabel will watch, for example:
   - `C:\NiceLabel\HotIn`
2. Share that folder in Windows.
3. Use the share name that matches your `.env`, for example:
   - `NiceLabelHotIn`
4. Confirm the Windows user in `smb-credentials` can write to it.
5. Confirm NiceLabel Automation is configured to watch that same folder.

### Important distinction

- **Windows path example:** `C:\NiceLabel\HotIn`
- **Share name example:** `NiceLabelHotIn`
- **Linux mount point example:** `/mnt/nicelabel/in`

These are three different things.

---

## Install the connector on Ubuntu

From the repository root:

```bash
sudo ./install.sh
```

### Optional

If needed, you may still pass mount values directly in the command line:

```bash
sudo WINDOWS_HOST=192.168.1.50 SHARE_NAME=NiceLabelHotIn MOUNT_POINT=/mnt/nicelabel/in ./install.sh
```

### What the installer does

The installer will:

- validate `config/config.env`
- validate `config/smb-credentials`
- create the dedicated Linux service user `nlconnector`
- install Python dependencies and ODBC driver
- copy app files into `/opt/nl-connector/app`
- copy config into `/opt/nl-connector/config/.env`
- create the main directories under `/opt/nl-connector`
- create the SMB mount entry
- mount the Windows share
- test write access to the mounted share
- install the systemd unit files and timer files
- apply schedules

---

## What gets installed where

Main paths after install:

| Path | Purpose |
|---|---|
| `/opt/nl-connector/app` | Python and shell scripts |
| `/opt/nl-connector/config/.env` | live environment config |
| `/opt/nl-connector/config/smb-credentials` | SMB credentials |
| `/opt/nl-connector/staging` | temporary CSV build area |
| `/opt/nl-connector/archive` | successfully sent CSV history |
| `/opt/nl-connector/error` | error snapshots and metadata |
| `/var/log/nl-connector` | logs |
| `/mnt/nicelabel/in` | mounted Windows share |

---

## Understand the systemd behavior

### Services

- `selector.service` → runs `selector.py`
- `nl-connector.service` → runs `connector.py`
- `cleanup-retention.service` → runs `cleanup_retention.sh`

These are **oneshot** services, meaning they run once per trigger and exit.

### Timers

The current timer behavior is not just the static `.timer` files in the repository.  
The installer also runs the schedule generator script, so the **real active schedule** comes from the values in `.env`.

That means the final timer behavior depends on:

- `SELECTOR_TIMES`
- `CONNECTOR_MODE`
- `CONNECTOR_INTERVAL`
- `CONNECTOR_TIMES`
- `CONNECTOR_TRIGGER_AFTER_SELECTOR`
- `CLEANUP_TIMES`

---

## Check whether install was successful

Run these in Ubuntu:

```bash
mount | grep nicelabel
systemctl status selector.timer --no-pager
systemctl status nl-connector.timer --no-pager
systemctl status cleanup-retention.timer --no-pager
systemctl list-timers --all | grep -E 'selector|nl-connector|cleanup-retention'
```

Also check the mount directly:

```bash
ls -la /mnt/nicelabel/in
```

If install succeeded, Ubuntu should be able to access the mounted Windows share.

---

## Optional manual commands directly in Ubuntu

These are useful if Postman is not being used.

### Run selector once

```bash
sudo systemctl start selector.service
```

or:

```bash
sudo nl-selector-run
```

### Run connector once

```bash
sudo systemctl start nl-connector.service
```

or:

```bash
sudo nl-connector-run
```

### Run cleanup once

```bash
sudo systemctl start cleanup-retention.service
```

### Re-apply timer schedules after changing `.env`

```bash
sudo nl-connector-apply-schedule
```

### Update the Windows share safely after install

```bash
sudo nl-connector-update-share --host 192.168.1.50 --share NiceLabelHotIn --mount /mnt/nicelabel/in
```

---

## Schedule Behavior

Explanation:

- The connector supports **manual testing** and **scheduled execution**.
- The static systemd unit files exist, but the active timer schedule is generated from `.env` using `apply_schedule.sh`.
- This makes the schedule flexible without editing the timer files manually.

### Example

If `.env` contains:

```env
CONNECTOR_MODE=schedule
CONNECTOR_TIMES=06:05,11:05,17:05
CONNECTOR_TRIGGER_AFTER_SELECTOR=false
```

then connector runs on those times only.

If `.env` contains:

```env
CONNECTOR_MODE=interval
CONNECTOR_INTERVAL=2s
```

then connector runs repeatedly by interval.

If `.env` contains:

```env
CONNECTOR_TRIGGER_AFTER_SELECTOR=true
```

then the schedule script adds a selector drop-in so that a successful selector run also triggers connector.

---

## Common issues and what they usually mean

### Problem: `mount` fails or write test fails

Likely causes:
- wrong `WINDOWS_HOST`
- wrong `SHARE_NAME`
- wrong username/password
- Windows share permissions not enough
- NTFS permissions not enough
- firewall or networking issue between VM and host

### Problem: Postman cannot reach the control API

Likely causes:
- control API not running
- wrong Ubuntu VM IP
- VM is NAT without port forwarding
- `CONTROL_API_HOST` not suitable
- firewall issue

### Problem: selector runs but nothing is queued

Likely causes:
- CalcMenu-side API returned no ready recipes
- API base URL or API key is wrong
- filter logic excludes current recipes
- Supabase config is wrong

### Problem: connector runs but nothing is printed

Likely causes:
- no eligible rows in Supabase
- validation failed and rows went to error
- CSV delivered but NiceLabel Automation not watching the correct folder
- template/output path mismatch on the Windows NiceLabel side

### Problem: timer behavior is not what you expected

Likely causes:
- `.env` was changed but schedules were not re-applied

Fix:

```bash
sudo nl-connector-apply-schedule
systemctl list-timers --all | grep -E 'selector|nl-connector|cleanup-retention'
```

---

## Uninstall if needed

To remove the connector-owned files, timers, services, mount entry, and deployment folders:

```bash
sudo ./uninstall.sh
```

This removes the connector deployment assets and related systemd items, while leaving shared system packages in place.

---
