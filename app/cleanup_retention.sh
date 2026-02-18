#!/usr/bin/env bash
set -euo pipefail

RETENTION_DAYS=30

ERROR_DIR="/opt/nl-connector/error"
ARCHIVE_DIR="/opt/nl-connector/archive"

if [ -d "$ERROR_DIR" ]; then
  find "$ERROR_DIR" \
    -mindepth 1 -maxdepth 1 \
    -type d \
    -mtime +$RETENTION_DAYS \
    -exec rm -rf {} +
fi

if [ -d "$ARCHIVE_DIR" ]; then
  find "$ARCHIVE_DIR" \
    -mindepth 1 -maxdepth 1 \
    -type d \
    -mtime +$RETENTION_DAYS \
    -exec rm -rf {} +
fi
