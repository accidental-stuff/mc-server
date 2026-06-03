#!/bin/bash
set -euo pipefail

mkdir -p /var/log
exec >> /var/log/mc-startup.log 2>&1
echo ""
echo "=========================================="
echo "Starting deployment at $(date)"
echo "=========================================="

export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y ca-certificates curl unzip jq awscli
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

id -u mcs >/dev/null 2>&1 || useradd -m -s /bin/bash mcs
usermod -aG docker mcs

mkdir -p /home/mcs/docker/backups \
         /home/mcs/docker/import \
         /home/mcs/docker/import/upload \
         /home/mcs/docker/servers \
         /home/mcs/docker/config \
         /home/mcs/docker/logs

cat > /home/mcs/docker/docker-compose.yml << 'COMP'
${docker_compose}
COMP

# ─────────────────────────────────────────────────────────
# DOWNLOAD BACKUP FROM R2 **BEFORE** STARTING DOCKER
# This avoids the race condition where Crafty's container
# manipulates the import/upload/ directory while we write.
# ─────────────────────────────────────────────────────────
if [ -n "${r2_access_key}" ] && [ -n "${r2_secret_key}" ]; then
  # Check disk space — need at least 2GB free
  AVAIL_KB=$(df /home --output=avail | tail -1)
  if [ "$AVAIL_KB" -lt 2097152 ]; then
    echo "ERROR: Less than 2GB disk space available ($AVAIL_KB KB). Aborting."
    exit 1
  fi

  echo "Downloading backup from R2..."
  AWS_ACCESS_KEY_ID="${r2_access_key}" \
  AWS_SECRET_ACCESS_KEY="${r2_secret_key}" \
  aws s3 cp "s3://${r2_bucket}/latest.zip" "/home/mcs/docker/import/upload/latest.zip" \
    --endpoint-url "${r2_endpoint}" \
    || { echo "ERROR: Failed to download backup from R2. Aborting."; exit 1; }

  # Verify the file actually exists on disk after download
  if [ ! -f "/home/mcs/docker/import/upload/latest.zip" ]; then
    echo "ERROR: aws s3 cp reported success but file not found at /home/mcs/docker/import/upload/latest.zip. Aborting."
    exit 1
  fi

  # Verify zip is not empty or corrupt
  ZIPSIZE=$(stat -c%s "/home/mcs/docker/import/upload/latest.zip" 2>/dev/null || echo "0")
  if [ "$ZIPSIZE" -lt 1024 ]; then
    echo "ERROR: Downloaded zip is too small ($ZIPSIZE bytes) — likely empty or corrupt. Aborting."
    exit 1
  fi

  unzip -t /home/mcs/docker/import/upload/latest.zip > /dev/null \
    || { echo "ERROR: Backup zip failed integrity check — corrupt or incomplete. Aborting."; exit 1; }

  # Touch the file to update its modification time to the current time.
  # This prevents Crafty's startup maintenance task from deleting it if the backup
  # was created/uploaded to R2 more than 24 hours ago.
  touch /home/mcs/docker/import/upload/latest.zip

  echo "Backup downloaded and verified ($ZIPSIZE bytes)."

  # Create .env for mc-restore.sh
  cat > /home/mcs/docker/.env << ENVFILE
r2_endpoint=${r2_endpoint}
r2_bucket=${r2_bucket}
ENVFILE

  # Create AWS credentials for mc-restore.sh
  mkdir -p /home/mcs/.aws
  cat > /home/mcs/.aws/credentials << AWSCREDS
[default]
aws_access_key_id=${r2_access_key}
aws_secret_access_key=${r2_secret_key}
AWSCREDS
  cat > /home/mcs/.aws/config << AWSCONF
[default]
endpoint_url=${r2_endpoint}
AWSCONF
  chmod 600 /home/mcs/.aws/credentials /home/mcs/.aws/config
  chown -R mcs:mcs /home/mcs/.aws
fi

# ─────────────────────────────────────────────────────────
# SET OWNERSHIP & PERMISSIONS
# chown first, then chmod to ensure correct final state
# ─────────────────────────────────────────────────────────
chown -R mcs:mcs /home/mcs/docker
chmod 777 /home/mcs/docker/import/upload

# ─────────────────────────────────────────────────────────
# DEPLOY MC-RESTORE.SH
# ─────────────────────────────────────────────────────────
cat > /usr/local/bin/mc-restore.sh << 'RESTORE'
${mc_restore}
RESTORE
chmod +x /usr/local/bin/mc-restore.sh

# ─────────────────────────────────────────────────────────
# START DOCKER COMPOSE
# Backup is already downloaded & verified at this point.
# ─────────────────────────────────────────────────────────
cd /home/mcs/docker || { echo "ERROR: cannot cd to /home/mcs/docker"; exit 1; }
docker compose up -d || { echo "ERROR: docker compose up -d failed"; exit 1; }

echo "Waiting for Crafty to start..."
CREDS_WAIT=0
CREDS_TIMEOUT=300
until [ -f /home/mcs/docker/config/default-creds.txt ] \
   || grep -q 'Your default admin password is:' /home/mcs/docker/logs/crafty.log 2>/dev/null
do
  if [ "$CREDS_WAIT" -ge "$CREDS_TIMEOUT" ]; then
    echo "ERROR: Crafty did not produce credentials within $CREDS_TIMEOUT seconds. Aborting."
    exit 1
  fi
  sleep 5
  CREDS_WAIT=$((CREDS_WAIT + 5))
done

if [ -f /home/mcs/docker/config/default-creds.txt ]; then
  CRAFTY_PASS=$(jq -r .password /home/mcs/docker/config/default-creds.txt)
else
  # Disable pipefail inside subshell to prevent SIGPIPE (exit code 141) from head/awk early exit
  CRAFTY_PASS=$(set +o pipefail; grep 'Your default admin password is:' /home/mcs/docker/logs/crafty.log \
    | grep -v 'Warning' | head -n1 | awk '{print $NF}' | tr -d '\r')
fi

if [ -z "$CRAFTY_PASS" ]; then
  echo "ERROR: Could not extract Crafty admin password. Aborting."
  exit 1
fi

cat > /home/mcs/docker/config/crafty-login.txt << LOGIN
username: admin
password: $CRAFTY_PASS
LOGIN
chmod 600 /home/mcs/docker/config/crafty-login.txt
chown mcs:mcs /home/mcs/docker/config/crafty-login.txt

echo "Waiting for Crafty API to come up..."
API_READY=0
i=1
while [ "$i" -le 60 ]
do
  # Write response to temp file; if file is non-empty, Crafty is answering
  curl -s -k -o /tmp/crafty_probe.json \
    -X POST "https://127.0.0.1:8443/api/v2/auth/login" \
    -H "Content-Type: application/json" \
    -d '{"username":"admin","password":"probe"}' 2>/dev/null || true

  if [ -s /tmp/crafty_probe.json ]; then
    echo "Crafty API is ready."
    API_READY=1
    break
  fi
  echo "API not ready yet, retrying in 5s... ($i/60)"
  sleep 5
  i=$((i + 1))
done

if [ "$API_READY" -eq 0 ]; then
  echo "ERROR: Crafty API did not become ready after 300s. Aborting."
  exit 1
fi

# Retry login up to 3 times in case Crafty needs a moment after API comes up
TOKEN=""
for attempt in 1 2 3; do
  LOGIN_RES=$(curl -s -k -X POST "https://127.0.0.1:8443/api/v2/auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"username\": \"admin\", \"password\": \"$CRAFTY_PASS\"}")
  TOKEN=$(echo "$LOGIN_RES" | jq -r '.data.token // empty')
  if [ -n "$TOKEN" ]; then
    break
  fi
  echo "Login attempt $attempt failed (response: $LOGIN_RES), retrying in 5s..."
  sleep 5
done

if [ -z "$TOKEN" ]; then
  echo "ERROR: Failed to authenticate with Crafty after 3 attempts. Aborting."
  exit 1
fi

SERVERS_RES=$(curl -s -k -X GET "https://127.0.0.1:8443/api/v2/servers" \
  -H "Authorization: Bearer $TOKEN")

# Verify the API returned a valid response before reading .data.length
SERVERS_STATUS=$(echo "$SERVERS_RES" | jq -r '.status // empty' 2>/dev/null || echo "")
if [ "$SERVERS_STATUS" != "ok" ]; then
  echo "ERROR: Could not list servers (response: $SERVERS_RES). Aborting."
  exit 1
fi

SERVER_EXIST=$(echo "$SERVERS_RES" | jq '.data | length' 2>/dev/null || echo "0")

IMPORT_ZIP=/home/mcs/docker/import/upload/latest.zip
ARCHIVE_NAME=latest.zip

if [ "$SERVER_EXIST" -eq 0 ]; then
  if [ ! -f "$IMPORT_ZIP" ]; then
    echo "ERROR: No Crafty import zip found at $IMPORT_ZIP. Aborting."
    exit 1
  fi

  echo "Creating new Minecraft server by importing $ARCHIVE_NAME with Crafty..."

  archive_internal_path=""
  # Disable pipefail inside subshell to prevent SIGPIPE (exit code 141) when awk exits early
  jarfile=$(set +o pipefail; unzip -l "$IMPORT_ZIP" | awk '/forge-.*-server\.jar$/{print $NF; exit}')
  if [ -z "$jarfile" ]; then
    jarfile=$(set +o pipefail; unzip -l "$IMPORT_ZIP" | awk '/\.jar$/{print $NF; exit}')
  fi
  if [ -z "$jarfile" ]; then
    echo "ERROR: Could not find a server jar inside $IMPORT_ZIP. Aborting."
    exit 1
  fi

  echo "Crafty import root: $archive_internal_path"
  echo "Crafty import jar: $jarfile"

  SERVER_PAYLOAD=$(jq -n \
    --arg archive_name "$ARCHIVE_NAME" \
    --arg archive_internal_path "$archive_internal_path" \
    --arg jarfile "$jarfile" \
    '{
      name: "Minecraft",
      autostart: true,
      autostart_delay: 10,
      monitoring_type: "minecraft_java",
      create_type: "minecraft_java",
      minecraft_java_monitoring_data: {
        host: "0.0.0.0",
        port: 25565
      },
      minecraft_java_create_data: {
        create_type: "import_server",
        import_server_create_data: {
          archive_name: $archive_name,
          archive_internal_path: $archive_internal_path,
          jarfile: $jarfile,
          mem_min: 1,
          mem_max: 2,
          server_properties_port: 25565,
          agree_to_eula: true
        }
      }
    }')

  CREATE_RES=$(curl -s -k -X POST "https://127.0.0.1:8443/api/v2/servers" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "$SERVER_PAYLOAD")

  CREATE_STATUS=$(echo "$CREATE_RES" | jq -r '.status // empty')
  if [ "$CREATE_STATUS" != "ok" ]; then
    echo "ERROR: Server creation failed (response: $CREATE_RES). Aborting."
    exit 1
  fi

  SERVER_ID=$(echo "$CREATE_RES" | jq -r '.data.new_server_id // .data.new_server_uuid // empty')

  if [ -z "$SERVER_ID" ]; then
    echo "ERROR: Could not retrieve newly created server ID (response: $CREATE_RES). Aborting."
    exit 1
  fi

  echo "Created Server UUID: $SERVER_ID"

else
  echo "Server already exists, skipping creation."
  SERVER_ID=$(echo "$SERVERS_RES" | jq -r '.data[0].server_id // empty')
fi

if [ -n "$SERVER_ID" ]; then
  echo "Waiting for Crafty import to complete..."

  server_dir="/home/mcs/docker/servers/$SERVER_ID"
  max_wait=600
  elapsed=0

  forge_args_file=""
  while [ "$elapsed" -lt "$max_wait" ]
  do
    forge_args_file=$(find "$server_dir/libraries/net/minecraftforge/forge" -name unix_args.txt -print -quit 2>/dev/null || true)
    if [ -f "$server_dir/user_jvm_args.txt" ] && [ -n "$forge_args_file" ]; then
      break
    fi
    sleep 5
    elapsed=$((elapsed + 5))
    echo "Still waiting for Forge... ($elapsed/$max_wait seconds)"
  done

  if [ -f "$server_dir/user_jvm_args.txt" ] && [ -n "$forge_args_file" ]; then
    echo "Crafty Forge import completed."

    echo "eula=true" > "$server_dir/eula.txt"
    chown -R mcs:mcs "$server_dir"
    echo "EULA accepted."

    # Dynamically resolve the Forge unix_args.txt path relative to server_dir
    # instead of hardcoding a specific Forge version
    forge_args_relative="$${forge_args_file#$server_dir/}"
    echo "Resolved Forge args path: $forge_args_relative"

    exec_command="java @user_jvm_args.txt @$${forge_args_relative} nogui \"\$@\""
    exec_payload=$(jq -n --arg execution_command "$exec_command" '{execution_command: $execution_command}')

    UPDATE_RES=$(curl -s -k -X PATCH "https://127.0.0.1:8443/api/v2/servers/$SERVER_ID" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "$exec_payload")
    UPDATE_STATUS=$(echo "$UPDATE_RES" | jq -r '.status // empty')
    if [ "$UPDATE_STATUS" != "ok" ]; then
      echo "ERROR: Failed to set Forge execution command (response: $UPDATE_RES). Aborting."
      exit 1
    fi
    echo "Forge execution command set: $exec_command"

    AUTO_RES=$(curl -s -k -X PATCH "https://127.0.0.1:8443/api/v2/servers/$SERVER_ID" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d '{"auto_start": true, "auto_start_delay": 10}')
    AUTO_STATUS=$(echo "$AUTO_RES" | jq -r '.status // empty')
    if [ "$AUTO_STATUS" != "ok" ]; then
      echo "ERROR: Failed to enable autostart (response: $AUTO_RES). Aborting."
      exit 1
    fi
    echo "Autostart enabled."

    echo "Starting Server $SERVER_ID..."
    START_RES=$(curl -s -k -X POST \
      "https://127.0.0.1:8443/api/v2/servers/$SERVER_ID/action/start_server" \
      -H "Authorization: Bearer $TOKEN")
    echo "Server start command sent (response: $START_RES)."

  else
    echo "ERROR: Crafty Forge import did not complete within $max_wait seconds. Aborting."
    exit 1
  fi
fi

echo "Deployment complete at $(date)."