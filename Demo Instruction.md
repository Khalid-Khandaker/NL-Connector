# NiceLabel Connector – Demo Instruction

This guide explains how to run a **demo test** of the NiceLabel Connector system after cloning the repository.

Follow the steps carefully in order.

---

# Step 1 — Clone the Repository

Inside your Ubuntu machine, open a terminal and run:

```bash
git clone https://github.com/Khalid-Khandaker/NL-Connector
```

Enter the project folder:

```bash
cd NL-Connector
```

---

# Step 2 — Prepare Configuration Files

Copy the template configuration files:

```bash
cp config/config.env.template config/config.env
cp config/smb-credentials.template config/smb-credentials
```

These files store environment variables and Windows share credentials.

---

# Step 3 — Configure Environment Variables

Edit the environment file:

```bash
nano config/config.env
```

Populate the required values.

Example:

```env
TEMPLATE_PATH=C:\NiceLabel\MyTemplatesFolder\
LABEL_PATH=C:\NiceLabel\Output\
```

Explanation:

| Variable | Description |
|--------|-------------|
| TEMPLATE_PATH | Location of NiceLabel template files |
| LABEL_PATH | Folder where generated labels will be saved |

⚠️ Adjust these paths according to your NiceLabel installation.

---

# Step 4 — Configure SMB Credentials

Edit the SMB credentials file:

```bash
nano config/smb-credentials
```

Fill in your Windows machine login details.

Example:

```ini
username=your_desktop_username
password=your_desktop_password
```

These credentials allow the Ubuntu connector to write files to the Windows share folder.

---

# Step 5 — Run the Installer

From the project root folder, run:

```bash
sudo WINDOWS_IP=192.168.1.188 SHARE_NAME=NiceLabelHotIn ./install.sh
```

Explanation:

| Variable | Description |
|--------|-------------|
| WINDOWS_IP | IP address of the Windows machine running NiceLabel |
| SHARE_NAME | Name of the Windows shared folder |

Example Windows shared folder:

```text
C:\NiceLabel\HotIn
```

Example share name:

```text
NiceLabelHotIn
```

⚠️ Make sure the Windows shared folder allows **write access**.

---

# Step 6 — Start the Required API

Before running the selector, make sure the CalcMenu API server (`app.py`) is running.

If this API is not running, the selector will not be able to fetch recipe data.

Run it using the appropriate command for your environment.

You may verify it by calling its health endpoint if available.

---

# Step 7 — Run the Selector Service

This service fetches **recipes ready for printing** from the CalcMenu database and inserts them into Supabase.

Run manually:

```bash
sudo systemctl start selector.service
```

You can verify activity using logs or API calls.

---

# Step 8 — Run the Connector Service

This service performs the following:

- Reads recipes stored in Supabase
- Validates recipe fields
- Generates CSV files
- Sends files to the Windows shared folder

Run manually:

```bash
sudo systemctl start nl-connector.service
```

---

# Step 9 — Verify Label Output

Check the following locations:

## On Ubuntu

The connector should successfully deliver the CSV file to the mounted Windows share.

## On Windows

Check the NiceLabel input/shared folder and the configured label output folder.

Expected behavior:

1. CSV file is created
2. NiceLabel Automation detects the file
3. Labels are generated and saved in the output folder

Example output folder:

```text
C:\NiceLabel\Output\
```

---

# Important Notes

Before running the demo, ensure the following are ready:

- CalcMenu API server (`app.py`) is running
- Supabase database is accessible
- NiceLabel Automation is configured
- Windows shared folder permissions are correct
- Template and label paths in `config.env` are correct

If these services are not available, the demo will not work correctly.

---

# Demo Summary

If everything is configured properly, the connector will:

1. Fetch recipe data from CalcMenu
2. Store it in Supabase
3. Generate CSV files
4. Deliver them to NiceLabel
5. Automatically produce printable labels

