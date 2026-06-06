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

BACKUP_KEY="${1:-latest.zip}"

log() { echo "[restore $(date '+%Y-%m-%d %H:%M:%S')] $*"; }

if [ -z "$R2_ENDPOINT" ]; then
  log "ERROR: R2 endpoint not found in $ENV_FILE"
  exit 1
fi

if [ ! -f /home/mcs/.aws/credentials ]; then
  log "ERROR: AWS credentials not found at /home/mcs/.aws/credentials"
  exit 1
fi

SERVER_DIR=$(set +o pipefail; find "$SERVERS_DIR" -mindepth 1 -maxdepth 1 -type d | head -1)
if [ -z "$SERVER_DIR" ]; then
  log "ERROR: No server directory found in $SERVERS_DIR"
  exit 1
fi

log "Downloading s3://$R2_BUCKET/$BACKUP_KEY from R2..."
HOME=/home/mcs aws s3 cp \
  "s3://$R2_BUCKET/$BACKUP_KEY" \
  "$IMPORT_DIR/restore_target.zip" \
  --endpoint-url "$R2_ENDPOINT"

# ─────────────────────────────────────────────────────────
# FIX [HIGH-3]: Graceful MC shutdown BEFORE stopping Crafty
# Send /stop via Crafty API and poll until server is stopped.
# ─────────────────────────────────────────────────────────
CREDS_FILE="/home/mcs/docker/config/crafty-login.txt"
if [ -f "$CREDS_FILE" ]; then
  log "Attempting graceful Minecraft server shutdown via Crafty API..."
  CRAFTY_PASS=$(grep '^password:' "$CREDS_FILE" | awk '{print $2}' || echo "")

  if [ -n "$CRAFTY_PASS" ]; then
    LOGIN_RES=$(curl -s -k --max-time 10 -X POST "https://127.0.0.1:8443/api/v2/auth/login" \
      -H "Content-Type: application/json" \
      -d "{\"username\": \"admin\", \"password\": \"$CRAFTY_PASS\"}" 2>/dev/null || echo "")
    TOKEN=$(echo "$LOGIN_RES" | jq -r '.data.token // empty' 2>/dev/null || echo "")

    if [ -n "$TOKEN" ]; then
      SERVER_ID=$(curl -s -k --max-time 10 "https://127.0.0.1:8443/api/v2/servers" \
        -H "Authorization: Bearer $TOKEN" 2>/dev/null \
        | jq -r '.data[0].server_id // empty' 2>/dev/null || echo "")

      if [ -n "$SERVER_ID" ]; then
        log "Sending stop_server action for $SERVER_ID..."
        curl -s -k --max-time 10 -X POST \
          "https://127.0.0.1:8443/api/v2/servers/$SERVER_ID/action/stop_server" \
          -H "Authorization: Bearer $TOKEN" > /dev/null 2>/dev/null || true

        # Poll until MC is stopped or 120s timeout
        STOP_WAIT=0
        STOP_TIMEOUT=120
        while [ "$STOP_WAIT" -lt "$STOP_TIMEOUT" ]; do
          STATUS=$(curl -s -k --max-time 5 "https://127.0.0.1:8443/api/v2/servers/$SERVER_ID" \
            -H "Authorization: Bearer $TOKEN" 2>/dev/null \
            | jq -r '.data.running // true' 2>/dev/null || echo "true")
          if [ "$STATUS" = "false" ]; then
            log "Minecraft server stopped gracefully."
            break
          fi
          sleep 5
          STOP_WAIT=$((STOP_WAIT + 5))
          log "Waiting for MC to stop... ($STOP_WAIT/$STOP_TIMEOUT)"
        done

        if [ "$STOP_WAIT" -ge "$STOP_TIMEOUT" ]; then
          log "WARNING: MC did not stop within ${STOP_TIMEOUT}s — proceeding anyway."
        fi
      fi
    else
      log "WARNING: Could not authenticate with Crafty — will do hard stop."
    fi
  fi
else
  log "WARNING: crafty-login.txt not found — will do hard stop."
fi

log "Stopping Crafty container..."
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

# FIX [HIGH-2]: Full replacement, not merge overlay.
# Move current server dir to a timestamped backup first (rollback path),
# then extract fresh. Only delete old dir after verifying jar exists.
TIMESTAMP=$(date +%s)
PRE_RESTORE_BACKUP="${SERVER_DIR}.pre-restore-$TIMESTAMP"

log "Moving current server dir to $PRE_RESTORE_BACKUP (rollback available)..."
mv "$SERVER_DIR" "$PRE_RESTORE_BACKUP"

mkdir -p "$SERVER_DIR"
cp -a "$SRC_DIR"/. "$SERVER_DIR"/
chown -R mcs:mcs "$SERVER_DIR"
rm -rf "$TMP_DIR"

# Verify jar exists in restored dir before cleaning up pre-restore backup
if find "$SERVER_DIR" -maxdepth 2 -name '*.jar' -print -quit 2>/dev/null | grep -q .; then
  log "Restore verified (jar found). Cleaning up pre-restore backup..."
  rm -rf "$PRE_RESTORE_BACKUP"
else
  log "WARNING: No jar found in restored server dir. Pre-restore backup kept at: $PRE_RESTORE_BACKUP"
fi

# Keep a local copy
cp "$IMPORT_DIR/restore_target.zip" "$BACKUPS_DIR/latest.zip"
chown mcs:mcs "$BACKUPS_DIR/latest.zip"
rm -f "$IMPORT_DIR/restore_target.zip"

log "Restore complete. Starting Crafty..."
docker start crafty_container

log "Done. Server should be back online in ~30s after Forge loads."
log "Check: docker logs crafty_container -f"