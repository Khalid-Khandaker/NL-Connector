# NiceLabel Connector Repository Guide

## What this repository is for

This repository contains the main parts of the NiceLabel Connector solution used to move label data from CalcMenu into NiceLabel in a controlled, traceable way.

In simple terms, the system does this:

1. A small Flask API (`app.py`) connects to SQL Server / CalcMenu and exposes clean endpoints.
2. The selector service (`selector.py`) calls that API and pushes candidate label rows into Supabase.
3. Supabase acts as the queue and validation layer.
4. The connector service (`connector.py`) reads approved rows from Supabase, validates them again, creates a CSV file, and drops that CSV into the Windows NiceLabel watch folder.
5. NiceLabel reads the CSV and generates label output such as PDF files.
6. Supporting scripts manage schedules, retention cleanup, installation, and uninstallation.

This means the system is not just a “script that prints labels.” It is a small pipeline with checkpoints, logs, and recovery behavior.

---

## The big picture

### End-to-end flow

```text
SQL Server / CalcMenu stored procedures
        ↓
Flask API (app.py)
        ↓
selector.py
        ↓
Supabase queue / validation table
        ↓
connector.py
        ↓
CSV file in Windows SMB watch folder
        ↓
NiceLabel Automation
        ↓
Printed labels / output PDF
```

### Why the design is useful

This design separates data retrieval from printing.

That gives the business several advantages:

- label data can be checked before it is sent to NiceLabel
- queue state can be seen in Supabase
- failures are easier to diagnose
- printing is less tightly coupled to the database
- batch history is easier to explain to business users

---

## Main components in this repository

### 1) `app.py` — CalcMenu API bridge

`app.py` is a Flask service that connects to SQL Server using ODBC and exposes the endpoints that `selector.py` depends on. It provides:

- `GET /health`
- `GET /recipes/ready-for-print`
- `GET /recipes/label-data`

Important note:

If `app.py` is not running, `selector.py` cannot fetch recipes or recipe details. In other words, the selector does **not** talk directly to SQL Server in the current design. It talks to this API layer first.

What this API does:

- uses environment variables such as SQL server, database, user, and password
- requires an API key through the `X-API-Key` header for the recipe endpoints
- executes stored procedures such as:
  - `dbo.NiceLabel_GetTop10RecipesToPrint`
  - `dbo.NiceLabel_GetRecipeDetails`
- returns structured JSON to the selector

This API layer makes the selector simpler and gives you one stable interface between SQL Server and the rest of the connector system.

### 2) `selector.py` — fetch and queue service

The selector is responsible for calling the CalcMenu API, transforming the response into queue rows, grouping rows into batches, and inserting those rows into Supabase.

#### What it does at a high level:

- loads environment variables from `/opt/nl-connector/config/.env`
- calls the API endpoint for recipes ready to print
- filters recipes using an allowed `CodeListe` list
- fetches detailed label data for each allowed recipe
- creates queue rows
- inserts rows into Supabase
- writes JSON log lines to the connector log file

#### Data written to Supabase

The selector writes the following fields into Supabase:

| Field            | Description              |
|------------------|--------------------------|
| batch_id         | Batch identifier         |
| site             | Site code                |
| template_name    | NiceLabel template       |
| language         | Language                 |
| product_name     | Product name             |
| allergens_short  | Allergen summary         |
| ingredients      | Ingredients              |
| qty              | Quantity                 |
| price            | Product price            |
| currency         | Currency                 |
| date_prepared    | Date prepared            |
| use_by           | Expiry / use-by date     |
| barcode          | Barcode                  |
| status           | Queue status             |

Supabase acts as a live queue for the connector.

The selector uses a lock file so two selector runs do not overlap.

### 3) `connector.py` — CSV Generator and Delivery Service

The connector is the second stage of the pipeline. It reads queued rows from Supabase and prepares the CSV that NiceLabel expects.

#### What it does at a high level:

- acquires a global lock so only one connector run is active
- finds the oldest `READY` batch in Supabase
- claims that batch by changing status from `READY` to `VALIDATING`
- validates each row
- sorts rows for better NiceLabel behavior
- builds output file names
- writes the CSV atomically into staging
- copies the CSV to the SMB watch folder
- archives the delivered CSV
- updates the Supabase rows to `SENT`
- writes logs and validation artifacts when needed

This service is where queue data becomes actual NiceLabel input files.

#### Required Fields (Core Label Fields)

| Column           | Description                     |
|------------------|---------------------------------|
| batch_id         | Batch identifier                |
| site             | Site code                       |
| template_name    | NiceLabel template path         |
| language         | Language                        |
| product_name     | Product name                    |
| allergens_short  | Allergen summary                |
| qty              | Number of labels                |

#### Additional Supported Fields

| Column           | Description                             |
|------------------|-----------------------------------------|
| ingredients      | Ingredient list                         |
| price            | Product price                           |
| currency         | Currency code (PHP, USD, etc.)          |
| date_prepared    | Date prepared (YYYY-MM-DD)              |
| use_by           | Use-by / expiry date (YYYY-MM-DD)       |
| barcode          | Barcode value                           |
| output_file_name | Output PDF file path                    |

### 4) `control_api.py` — operations and support API

This Flask app is a support and diagnostics API for the connector environment.

Examples of what it can show:

- service health
- queue counts by status
- recent connector and selector log lines
- diagnostics for mount, staging, logs, and Supabase

This is useful for technical support, demos, and basic operational visibility.

### 5) `cleanup_retention.sh` — housekeeping

This script removes old folders from the archive and error directories based on retention days.

This keeps the environment from growing forever and helps protect disk space.

### 6) `apply_schedule.sh` — timer generator

This script reads the schedule values from `.env` and generates the systemd timers for:

- selector
- connector
- cleanup retention

This is important because the schedule is not hard-coded in just one timer file. It is generated from configuration.

### 7) `install.sh` and `uninstall.sh`

These scripts prepare and remove the Ubuntu-side deployment.

They handle tasks such as:

- dependency installation
- virtual environment creation
- Linux service user creation
- application file placement
- config file placement
- SMB mount setup
- systemd unit installation
- schedule application

---

## Understanding the status flow

The Supabase table is not just storage. It is the live queue.

Typical status movement is:

```text
READY → VALIDATING → SENT
                ↘
                 ERROR
```

### What each status means

- `READY` — selector inserted the row and it is waiting for connector processing
- `VALIDATING` — connector claimed the batch and is currently processing it
- `SENT` — connector successfully delivered the CSV row set for NiceLabel processing
- `ERROR` — validation or processing failed

This is one of the most important concepts for non-technical users. If they understand these four states, they understand most of the operational flow.

---

## How batch naming works

The selector creates a `batch_id` using a structured format:

```text
YYYYMMDD-ROWCOUNT-SITECODE-SEQ
```

Example:

```text
20260310-0010-1-005
```

Meaning:

- `20260310` = date of batch creation
- `0010` = number of rows in the batch, zero-padded to 4 digits
- `1` = site code or site-based identifier
- `005` = sequence number for that date/rowcount/site prefix

Why this matters:

- it is readable by humans
- it helps separate runs
- it helps support and troubleshooting
- it is useful when explaining what happened on a specific day

---

## What user should understand first

Before testing this project, the user should understand these five facts:

1. The Ubuntu connector machine is only one part of the system.
2. The CalcMenu API (`app.py`) must be reachable for selector to work.
3. Supabase is part of the live workflow, not just an optional database.
4. The Windows SMB watch folder must be reachable and writable for connector to work.
5. systemd timers and services are part of the expected design; this is not meant to be run only by hand.

---

## Typical daily workflow

A normal business-facing explanation would be:

1. Recipes become available in CalcMenu.
2. The API exposes those recipes.
3. The selector fetches and queues them.
4. Supabase holds the rows for validation and monitoring.
5. The connector builds a CSV for NiceLabel.
6. NiceLabel processes the CSV and creates the final label output.
7. Logs and archives remain available for support.

---

## Main folders on Ubuntu

Typical deployment folders include:

- `/opt/nl-connector/app` — Python scripts and shell scripts
- `/opt/nl-connector/config` — `.env` and SMB credentials
- `/opt/nl-connector/staging` — temporary CSV generation area
- `/opt/nl-connector/archive` — successfully delivered CSV history
- `/opt/nl-connector/error` — error snapshots and metadata
- `/var/log/nl-connector` — log files
- `/mnt/nicelabel/in` — mounted Windows NiceLabel watch folder

These are useful to know because most support work starts by checking one of these locations.

---

## What this repository is not

This repository is not only a Flask API project.
It is not only a Supabase project.
It is not only a NiceLabel automation project.

It is a small integrated operational system.
