#!/bin/bash
# ─────────────────────────────────────────────────────────
# mc-backup-sync.sh
# Idempotent script — syncs the newest Crafty backup to R2.
# Triggered by systemd timer every 5 minutes.
#
# Only uploads zips that have been unmodified for ≥2 minutes
# (ensures Crafty has finished writing before upload).
# Tracks last uploaded filename to skip duplicates.
# Retains the 3 most recent timestamped backups in R2.
# ─────────────────────────────────────────────────────────
set -euo pipefail

LOG=/var/log/mc-backup-sync.log
exec >> "$LOG" 2>&1
echo "[sync $(date '+%Y-%m-%d %H:%M:%S')] Starting backup sync..."

# ── Config ──────────────────────────────────────────────
CONFIG_FILE="/home/mcs/.aws/config"
ENV_FILE="/home/mcs/docker/.env"
BACKUPS_DIR="/home/mcs/docker/backups"
TRACKING_FILE="$BACKUPS_DIR/.last-uploaded"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "ERROR: AWS config not found at $CONFIG_FILE"
  exit 1
fi
if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: .env not found at $ENV_FILE"
  exit 1
fi

R2_ENDPOINT=$(awk -F'=' '/endpoint_url/ {gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}' "$CONFIG_FILE" 2>/dev/null || echo "")
R2_BUCKET=$(grep r2_bucket "$ENV_FILE" 2>/dev/null | cut -d= -f2- || echo "mc-server-backup")

if [ -z "$R2_ENDPOINT" ]; then
  echo "ERROR: Could not read R2 endpoint from $CONFIG_FILE"
  exit 1
fi

# ── Find newest stable backup ───────────────────────────
# Only consider zips last modified ≥2 minutes ago (Crafty has finished writing)
NEWEST_ZIP=$(find "$BACKUPS_DIR" -name '*.zip' -mmin +2 -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | awk '{print $2}')

if [ -z "$NEWEST_ZIP" ]; then
  echo "No stable backup zip found (all zips modified in last 2 min or directory empty)."
  exit 0
fi

# NEWEST_ZIP is now the full path from find
NEWEST_FILE=$(basename "$NEWEST_ZIP")

# ── Check if already uploaded ───────────────────────────
if [ -f "$TRACKING_FILE" ]; then
  LAST_UPLOADED=$(cat "$TRACKING_FILE" 2>/dev/null || echo "")
  if [ "$LAST_UPLOADED" = "$NEWEST_FILE" ]; then
    echo "Backup '$NEWEST_FILE' already uploaded — skipping."
    exit 0
  fi
fi

# ── Verify file size ────────────────────────────────────
ZIPSIZE=$(stat -c%s "$NEWEST_ZIP" 2>/dev/null || echo "0")
if [ "$ZIPSIZE" -lt 1024 ]; then
  echo "ERROR: Backup zip '$NEWEST_FILE' is too small ($ZIPSIZE bytes). Skipping."
  exit 0
fi

# ── Upload to R2 ────────────────────────────────────────
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
echo "Uploading '$NEWEST_FILE' ($ZIPSIZE bytes) to R2..."

HOME=/home/mcs aws s3 cp "$NEWEST_ZIP" "s3://$R2_BUCKET/latest.zip" \
  --endpoint-url "$R2_ENDPOINT" \
  || { echo "ERROR: Failed to upload latest.zip to R2"; exit 1; }

HOME=/home/mcs aws s3 cp "$NEWEST_ZIP" "s3://$R2_BUCKET/backups/$TIMESTAMP.zip" \
  --endpoint-url "$R2_ENDPOINT" \
  || { echo "ERROR: Failed to upload $TIMESTAMP.zip to R2"; exit 1; }

echo "[sync $(date '+%Y-%m-%d %H:%M:%S')] Upload complete: backups/$TIMESTAMP.zip"

# ── Prune R2 — retain only 3 most recent ─────────────────
echo "Pruning R2 backups (retain 3 most recent)..."
HOME=/home/mcs aws s3 ls "s3://$R2_BUCKET/backups/" --endpoint-url "$R2_ENDPOINT" 2>/dev/null \
  | sort | head -n -3 | awk '{print $NF}' | while read -r old; do
    if [ -n "$old" ]; then
      HOME=/home/mcs aws s3 rm "s3://$R2_BUCKET/backups/$old" --endpoint-url "$R2_ENDPOINT" 2>/dev/null
      echo "Pruned old backup: $old"
    fi
  done

# ── Update tracking file ─────────────────────────────────
echo "$NEWEST_FILE" > "$TRACKING_FILE"
chown mcs:mcs "$TRACKING_FILE" 2>/dev/null || true
echo "[sync $(date '+%Y-%m-%d %H:%M:%S')] Sync complete. Tracking: $NEWEST_FILE"
