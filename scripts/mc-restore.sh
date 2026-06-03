#!/bin/bash
# ─────────────────────────────────────────────────────────
# mc-restore.sh
# Run this on the server via SSH to force a world restore
# from R2 — even if the startup already ran.
#
# Usage:
#   ssh into the server:
#     gcloud compute ssh minecraft
#   then:
#     sudo bash /usr/local/bin/mc-restore.sh
#
# To restore a specific timestamped backup instead of latest:
#     sudo bash /usr/local/bin/mc-restore.sh backups/20260601_120000.zip
# ─────────────────────────────────────────────────────────
set -euo pipefail

# Source R2 config from .env (created by startup.sh)
ENV_FILE="/home/mcs/docker/.env"
if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: $ENV_FILE not found. Was the server provisioned correctly?"
  exit 1
fi

R2_ENDPOINT=$(grep r2_endpoint "$ENV_FILE" 2>/dev/null | cut -d= -f2- || echo "")
R2_BUCKET=$(grep r2_bucket "$ENV_FILE" 2>/dev/null | cut -d= -f2- || echo "mc-server-backup")

SERVERS_DIR="/home/mcs/docker/servers"
BACKUPS_DIR="/home/mcs/docker/backups"
IMPORT_DIR="/home/mcs/docker/import"
RESTORE_MARKER="$IMPORT_DIR/.latest_restored"

# Allow specifying a different backup key
BACKUP_KEY="${1:-latest.zip}"

log() { echo "[restore $(date '+%Y-%m-%d %H:%M:%S')] $*"; }

if [ -z "$R2_ENDPOINT" ]; then
  log "ERROR: R2 endpoint not found in $ENV_FILE"
  exit 1
fi

# Verify AWS credentials exist (created by startup.sh)
if [ ! -f /home/mcs/.aws/credentials ]; then
  log "ERROR: AWS credentials not found at /home/mcs/.aws/credentials"
  log "Was the server provisioned correctly?"
  exit 1
fi

SERVER_DIR=$(set +o pipefail; find "$SERVERS_DIR" -mindepth 1 -maxdepth 1 -type d | head -1)
if [ -z "$SERVER_DIR" ]; then
  log "ERROR: No server directory found in $SERVERS_DIR"
  log "Make sure Crafty has started at least once and created a server."
  exit 1
fi

log "Downloading s3://$R2_BUCKET/$BACKUP_KEY from R2..."
HOME=/home/mcs aws s3 cp \
  "s3://$R2_BUCKET/$BACKUP_KEY" \
  "$IMPORT_DIR/restore_target.zip" \
  --endpoint-url "$R2_ENDPOINT"

log "Stopping Crafty..."
docker stop crafty_container 2>/dev/null || true
sleep 5

log "Extracting into $SERVER_DIR ..."
TMP_DIR=$(mktemp -d)
unzip -q "$IMPORT_DIR/restore_target.zip" -d "$TMP_DIR"

shopt -s nullglob
TOP_LEVEL=("$TMP_DIR"/*)
shopt -u nullglob

SRC_DIR="$TMP_DIR"
if [ "${#TOP_LEVEL[@]}" -eq 1 ] && [ -d "${TOP_LEVEL[0]}" ]; then
  SRC_DIR="${TOP_LEVEL[0]}"
fi

cp -a "$SRC_DIR"/. "$SERVER_DIR"/
chown -R mcs:mcs "$SERVER_DIR"
rm -rf "$TMP_DIR"

# Reset restore marker so startup doesn't skip it next time
rm -f "$RESTORE_MARKER"
ZIP_HASH=$(sha256sum "$IMPORT_DIR/restore_target.zip" | awk '{print $1}')
echo "$ZIP_HASH" > "$RESTORE_MARKER"

# Keep a local copy
cp "$IMPORT_DIR/restore_target.zip" "$BACKUPS_DIR/latest.zip"
chown mcs:mcs "$BACKUPS_DIR/latest.zip"
rm -f "$IMPORT_DIR/restore_target.zip"

log "Restore complete. Starting Crafty..."
docker start crafty_container

log "Done! Server should be back online in ~30 seconds."
log "Check: docker logs crafty_container -f"