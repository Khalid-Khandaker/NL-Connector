#!/usr/bin/env bash
set -euo pipefail

# ============================
# Retention configuration
# ============================
RETENTION_DAYS=30

ERROR_DIR="/opt/nl-connector/error"
ARCHIVE_DIR="/opt/nl-connector/archive"

# ============================
# 1) Clean ERROR folders
# Structure:
#   /opt/nl-connector/error/<run_id>/
# ============================
if [ -d "$ERROR_DIR" ]; then
  find "$ERROR_DIR" \
    -mindepth 1 -maxdepth 1 \
    -type d \
    -mtime +$RETENTION_DAYS \
    -exec rm -rf {} +
fi

# ============================
# 2) Clean ARCHIVE folders
# Structure:
#   /opt/nl-connector/archive/<YYYYMMDD>/
# ============================
if [ -d "$ARCHIVE_DIR" ]; then
  find "$ARCHIVE_DIR" \
    -mindepth 1 -maxdepth 1 \
    -type d \
    -mtime +$RETENTION_DAYS \
    -exec rm -rf {} +
fi
