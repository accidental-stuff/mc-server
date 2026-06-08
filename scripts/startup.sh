#!/bin/bash
set -euo pipefail

mkdir -p /var/log
exec >> /var/log/mc-startup.log 2>&1
echo ""
echo "=========================================="
echo "Starting deployment at $(date)"
echo "=========================================="

DEPLOY_MARKER="/home/mcs/.deployment-complete"
if [ -f "$DEPLOY_MARKER" ]; then
  echo "Deployment marker found — already deployed. Skipping."
  echo "If you need to re-deploy, run: sudo rm $DEPLOY_MARKER && sudo bash /opt/mc-startup.sh"
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y ca-certificates curl unzip jq python3

curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp/awscliv2-install
/tmp/awscliv2-install/aws/install
rm -rf /tmp/awscliv2.zip /tmp/awscliv2-install

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
         /home/mcs/docker/logs \
         /home/mcs/docker/caddy/data \
         /home/mcs/docker/caddy/config

if [ ! -f /swapfile ]; then
  echo "Creating 2GB swapfile..."
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo "Swap enabled."
fi

# Caddy reverse-proxies to Crafty on the internal Docker network.
# tls_insecure_skip_verify is safe here — traffic never leaves the host,
# and Crafty 8443 is bound to 127.0.0.1. Caddy terminates public TLS.
cat > /home/mcs/docker/caddy/Caddyfile << 'CADDYFILE'
${crafty_domain} {
    reverse_proxy crafty_container:8443 {
        transport http {
            tls_insecure_skip_verify
        }

        # Required for Crafty WSS — per https://docs.craftycontrol.com/pages/getting-started/proxies/
        header_up Upgrade {http.request.header.Upgrade}
        header_up Connection {http.request.header.Connection}
        header_up X-Forwarded-Proto https
        header_up X-Forwarded-For {remote_host}
        header_up Host {host}

        # Disable response buffering — required for live console output over WSS
        flush_interval -1
    }
}
CADDYFILE

cat > /home/mcs/docker/docker-compose.yml << 'COMP'
${docker_compose}
COMP

if [ -n "${r2_access_key}" ] && [ -n "${r2_secret_key}" ]; then
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

  if [ ! -f "/home/mcs/docker/import/upload/latest.zip" ]; then
    echo "ERROR: aws s3 cp reported success but file not found. Aborting."
    exit 1
  fi

  ZIPSIZE=$(stat -c%s "/home/mcs/docker/import/upload/latest.zip" 2>/dev/null || echo "0")
  if [ "$ZIPSIZE" -lt 1024 ]; then
    echo "ERROR: Downloaded zip is too small ($ZIPSIZE bytes). Aborting."
    exit 1
  fi

  unzip -t /home/mcs/docker/import/upload/latest.zip > /dev/null \
    || { echo "ERROR: Backup zip corrupt. Aborting."; exit 1; }

  touch /home/mcs/docker/import/upload/latest.zip
  echo "Backup downloaded and verified ($ZIPSIZE bytes)."

  cat > /home/mcs/docker/.env << ENVFILE
r2_bucket=${r2_bucket}
ENVFILE

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

chown -R mcs:mcs /home/mcs/docker
chmod 775 /home/mcs/docker/import/upload

cat > /usr/local/bin/mc-restore.sh << 'RESTORE'
${mc_restore}
RESTORE
chmod +x /usr/local/bin/mc-restore.sh

cat > /usr/local/bin/mc-backup-sync.sh << 'BACKUPSYNC'
${mc_backup_sync}
BACKUPSYNC
chmod +x /usr/local/bin/mc-backup-sync.sh

cd /home/mcs/docker || { echo "ERROR: cannot cd to /home/mcs/docker"; exit 1; }
docker compose up -d || { echo "ERROR: docker compose up -d failed"; exit 1; }

sleep 5
docker exec caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null \
  || echo "WARNING: Caddy reload failed (may not be up yet — it will load correctly on start)"

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
  CRAFTY_PASS=$(set +o pipefail; grep 'Your default admin password is:' /home/mcs/docker/logs/crafty.log \
    | grep -v 'Warning' | head -n1 | awk '{print $NF}' | tr -d '\r')
fi

if [ -z "$CRAFTY_PASS" ]; then
  echo "ERROR: Could not extract Crafty admin password. Aborting."
  exit 1
fi

{
  printf 'username: admin\n'
  printf 'password: %s\n' "$CRAFTY_PASS"
} > /home/mcs/docker/config/crafty-login.txt
chmod 600 /home/mcs/docker/config/crafty-login.txt
chown mcs:mcs /home/mcs/docker/config/crafty-login.txt

echo "Waiting for Crafty API to come up..."

API_READY=0
i=1
while [ "$i" -le 60 ]; do
  CONTAINER_STATE=$(docker inspect -f '{{.State.Running}}' crafty_container 2>/dev/null || echo "false")
  if [ "$CONTAINER_STATE" != "true" ]; then
    echo "ERROR: crafty_container is not running. Docker logs:"
    docker logs --tail 40 crafty_container 2>&1 || true
    exit 1
  fi

  PROBE=$(docker exec crafty_container \
    curl -s -k --max-time 5 -o /tmp/crafty_probe.json \
    -w "%%{http_code}" \
    -X POST "https://127.0.0.1:8443/api/v2/auth/login" \
    -H "Content-Type: application/json" \
    -d '{"username":"probe","password":"probe"}' 2>/dev/null || echo "000")

  if [ "$PROBE" = "200" ] || [ "$PROBE" = "400" ] || [ "$PROBE" = "403" ]; then
    echo "Crafty API is ready (HTTP $PROBE)."
    API_READY=1
    break
  fi

  HOST_PROBE=$(curl -s -k --max-time 5 -o /dev/null \
    -w "%%{http_code}" \
    -X POST "https://127.0.0.1:8443/api/v2/auth/login" \
    -H "Content-Type: application/json" \
    -d '{"username":"probe","password":"probe"}' 2>/dev/null || echo "000")

  if [ "$HOST_PROBE" = "200" ] || [ "$HOST_PROBE" = "400" ] || [ "$HOST_PROBE" = "403" ]; then
    echo "Crafty API is ready on host port (HTTP $HOST_PROBE)."
    API_READY=1
    break
  fi

  echo "API not ready yet (container: $PROBE, host: $HOST_PROBE), retrying... ($i/60)"
  sleep 5
  i=$((i + 1))
done

if [ "$API_READY" -eq 0 ]; then
  echo "ERROR: Crafty API did not become ready after 300s."
  docker logs --tail 50 crafty_container 2>&1 || true
  docker ps -a 2>&1 || true
  exit 1
fi

TOKEN=""
LOGIN_RES=""
for attempt in 1 2 3; do
  LOGIN_PAYLOAD=$(jq -n --arg pass "$CRAFTY_PASS" '{"username":"admin","password":$pass}')
  LOGIN_RES=$(curl -s -k -X POST "https://127.0.0.1:8443/api/v2/auth/login" \
    -H "Content-Type: application/json" \
    -d "$LOGIN_PAYLOAD")
  TOKEN=$(echo "$LOGIN_RES" | jq -r '.data.token // empty')
  if [ -n "$TOKEN" ]; then break; fi
  echo "Login attempt $attempt failed (response: $LOGIN_RES), retrying in 5s..."
  sleep 5
done

if [ -z "$TOKEN" ]; then
  echo "ERROR: Failed to authenticate with Crafty after 3 attempts. Aborting."
  exit 1
fi

NEW_CRAFTY_PASS="crafty@123"

USERS_RES=$(curl -s -k -X GET "https://127.0.0.1:8443/api/v2/users" \
  -H "Authorization: Bearer $TOKEN")
USER_ID=$(echo "$USERS_RES" | jq -r '.data[] | select(.username == "admin") | .user_id // empty' | head -1)
if [ -z "$USER_ID" ]; then
  echo "ERROR: Could not resolve admin user_id from /api/v2/users (response: $USERS_RES). Aborting."
  exit 1
fi

echo "Changing admin password (user_id=$USER_ID)..."
PATCH_PW_PAYLOAD=$(jq -n --arg pass "$NEW_CRAFTY_PASS" '{"password":$pass}')
PATCH_PW_RES=$(curl -s -k -X PATCH "https://127.0.0.1:8443/api/v2/users/$USER_ID" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "$PATCH_PW_PAYLOAD")
PATCH_PW_STATUS=$(echo "$PATCH_PW_RES" | jq -r '.status // empty')
if [ "$PATCH_PW_STATUS" != "ok" ]; then
  echo "ERROR: Password change failed (response: $PATCH_PW_RES). Aborting."
  exit 1
fi

echo "Re-authenticating with new password..."
TOKEN=""
for attempt in 1 2 3; do
  REAUTH_PAYLOAD=$(jq -n --arg pass "$NEW_CRAFTY_PASS" '{"username":"admin","password":$pass}')
  REAUTH_RES=$(curl -s -k -X POST "https://127.0.0.1:8443/api/v2/auth/login" \
    -H "Content-Type: application/json" \
    -d "$REAUTH_PAYLOAD")
  TOKEN=$(echo "$REAUTH_RES" | jq -r '.data.token // empty')
  if [ -n "$TOKEN" ]; then
    echo "Re-auth successful."
    break
  fi
  echo "Re-auth attempt $attempt failed, retrying in 5s..."
  sleep 5
done

if [ -z "$TOKEN" ]; then
  echo "ERROR: Re-authentication after password change failed. Aborting."
  exit 1
fi

cat > /home/mcs/docker/config/crafty-login.txt << 'LOGIN'
username: admin
password: crafty@123
LOGIN
chmod 600 /home/mcs/docker/config/crafty-login.txt
chown mcs:mcs /home/mcs/docker/config/crafty-login.txt
echo "Password changed, re-auth confirmed, credentials stored."

SERVERS_RES=$(curl -s -k -X GET "https://127.0.0.1:8443/api/v2/servers" \
  -H "Authorization: Bearer $TOKEN")

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

  TOPLEVEL_DIRS=$(unzip -l "$IMPORT_ZIP" | tail -n +4 | head -n -2 | awk '{print $NF}' | cut -d/ -f1 | sort -u | grep -v '^$' | wc -l)
  TOPLEVEL_NAME=$(unzip -l "$IMPORT_ZIP" | tail -n +4 | head -n -2 | awk '{print $NF}' | cut -d/ -f1 | sort -u | grep -v '^$' | head -1)

  archive_internal_path=""
  if [ "$TOPLEVEL_DIRS" -eq 1 ] && [ -n "$TOPLEVEL_NAME" ]; then
    TOTAL_ENTRIES=$(unzip -l "$IMPORT_ZIP" | tail -n +4 | head -n -2 | awk '{print $NF}' | grep -v '^$' | wc -l)
    PREFIXED=$(unzip -l "$IMPORT_ZIP" | tail -n +4 | head -n -2 | awk '{print $NF}' | grep -v '^$' | grep "^$TOPLEVEL_NAME/" | wc -l)
    if [ "$PREFIXED" -eq "$TOTAL_ENTRIES" ]; then
      archive_internal_path="$TOPLEVEL_NAME"
      echo "Detected archive prefix: $archive_internal_path"
    fi
  fi

  jarfile=""
  jarfile=$(set +o pipefail; unzip -l "$IMPORT_ZIP" | awk '/forge-[0-9].*-server\.jar$/{print $NF; exit}')
  if [ -z "$jarfile" ]; then
    jarfile=$(set +o pipefail; unzip -l "$IMPORT_ZIP" | awk '/[Ss]erver.*\.jar$/{print $NF; exit}')
  fi
  if [ -z "$jarfile" ]; then
    jarfile=$(set +o pipefail; unzip -v "$IMPORT_ZIP" | awk '/\.jar$/{print $1, $NF}' | sort -rn | head -1 | awk '{print $NF}')
  fi

  # Strip the archive_internal_path prefix from jarfile so Crafty receives
  # a path relative to the server root, not the zip root.
  # Terraform templatefile requires $${...} for runtime Bash expansion.
  if [ -n "$archive_internal_path" ]; then
    jarfile="$${jarfile#$archive_internal_path/}"
  fi

  if [ -z "$jarfile" ]; then
    echo "ERROR: Could not find a server jar inside $IMPORT_ZIP. Aborting."
    exit 1
  fi

  echo "Crafty import root: '$archive_internal_path'"
  echo "Crafty import jar:  '$jarfile'"

  SERVER_PAYLOAD=$(jq -n \
    --arg archive_name "$ARCHIVE_NAME" \
    --arg archive_internal_path "$archive_internal_path" \
    --arg jarfile "$jarfile" \
    '{
      name: "Minecraft",
      autostart: true,
      autostart_delay: 60,
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
          mem_min: 2,
          mem_max: 4,
          server_properties_port: 25565
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

  server_dir_container=$(curl -s -k "https://127.0.0.1:8443/api/v2/servers/$SERVER_ID" \
    -H "Authorization: Bearer $TOKEN" | jq -r '.data.path // empty')

  if [ -z "$server_dir_container" ]; then
    server_dir_container="/crafty/servers/$SERVER_ID"
    echo "WARNING: Could not get server path from API; using expected container path: $server_dir_container"
  fi

  server_dir_name="$${server_dir_container##*/}"
  server_dir="/home/mcs/docker/servers/$${server_dir_name}"

  echo "Container path: $server_dir_container"
  echo "Host path:      $server_dir"

  max_wait=600
  elapsed=0

  while [ "$elapsed" -lt "$max_wait" ]; do
    if [ -d "$server_dir" ] && [ -n "$(ls -A "$server_dir" 2>/dev/null)" ]; then
      echo "Server directory populated, waiting 15s for extraction to finish..."
      sleep 15
      break
    fi
    sleep 5
    elapsed=$((elapsed + 5))
    echo "Still waiting for server files... ($elapsed/$max_wait seconds)"
  done

  if [ ! -d "$server_dir" ]; then
    echo "ERROR: Crafty import did not complete within $max_wait seconds. Aborting."
    exit 1
  fi

  echo "Crafty import completed."
echo "Waiting 60 seconds for Crafty post-import processing..."
sleep 60

  # Write through the container so Crafty sees the right path and ownership.
  echo "Writing eula=true inside container at $server_dir_container/eula.txt ..."
  docker exec crafty_container \
    sh -c "printf 'eula=true\n' > '$server_dir_container/eula.txt'" \
    || { echo "ERROR: docker exec eula write failed. Aborting."; exit 1; }

  EULA_CHECK=$(docker exec crafty_container \
    cat "$server_dir_container/eula.txt" 2>/dev/null | tr -d '\r\n' || echo "")
  if [ "$EULA_CHECK" != "eula=true" ]; then
    echo "ERROR: eula.txt verification failed inside container (got: '$EULA_CHECK'). Aborting."
    exit 1
  fi
  echo "EULA confirmed inside container (verified)."

  # Java imports can leave Crafty's runtime server_path unset. Repair the DB
  # path and patch agree_eula to reload it before calling the API action.
  echo "Ensuring Crafty DB has server path before EULA API action..."
  docker exec crafty_container python3 -c "import glob, sqlite3, sys; server_id=sys.argv[1]; server_path=sys.argv[2]; dbs=glob.glob('/crafty/app/config/**/*.sqlite', recursive=True)+glob.glob('/crafty/app/config/**/*.db', recursive=True); updated=False
for db in dbs:
    con=sqlite3.connect(db)
    cur=con.cursor()
    tables=[r[0] for r in cur.execute(\"SELECT name FROM sqlite_master WHERE type='table'\")]
    if 'servers' in tables:
        cols=[r[1] for r in cur.execute('PRAGMA table_info(servers)')]
        if 'server_id' in cols and 'path' in cols:
            cur.execute('UPDATE servers SET path=? WHERE server_id=?', (server_path, server_id))
            con.commit()
            if cur.rowcount:
                print(f'Updated {db}: servers.path={server_path}')
                updated=True
    con.close()
if not updated:
    raise SystemExit('ERROR: Could not update servers.path in Crafty DB')" \
    "$SERVER_ID" "$server_dir_container" \
    || { echo "ERROR: Crafty DB path repair failed. Aborting."; exit 1; }

  echo "Patching Crafty EULA action to reload server_path when the runtime instance has None..."
  docker exec crafty_container python3 -c "from pathlib import Path
p=Path('/crafty/app/classes/shared/server.py')
s=p.read_text()
old='''    def agree_eula(self, user_id):
        eula_file = os.path.join(self.server_path, \"eula.txt\")
        with open(eula_file, \"w\", encoding=\"utf-8\") as f:
            f.write(\"eula=true\")
        self.run_threaded_server(user_id)
'''
new='''    def agree_eula(self, user_id):
        if self.server_path is None:
            self.reload_server_settings()
            self.server_path = Helpers.get_os_understandable_path(self.settings[\"path\"])
        eula_file = os.path.join(self.server_path, \"eula.txt\")
        with open(eula_file, \"w\", encoding=\"utf-8\") as f:
            f.write(\"eula=true\")
        self.run_threaded_server(user_id)
'''
if new not in s:
    if old not in s:
        raise SystemExit('ERROR: Could not find Crafty agree_eula block to patch')
    p.write_text(s.replace(old, new))
    print('Patched Crafty agree_eula server_path fallback')
else:
    print('Crafty agree_eula server_path fallback already patched')" \
    || { echo "ERROR: Crafty EULA runtime patch failed. Aborting."; exit 1; }

  echo "Restarting Crafty so server instances reload the repaired path and patched EULA action..."
  docker restart crafty_container >/dev/null \
    || { echo "ERROR: Failed to restart Crafty after DB path repair. Aborting."; exit 1; }

  echo "Waiting for Crafty API after restart..."
  API_READY=0
  for i in $(seq 1 60); do
    PROBE=$(curl -s -k --max-time 5 -o /dev/null \
      -w "%%{http_code}" \
      -X POST "https://127.0.0.1:8443/api/v2/auth/login" \
      -H "Content-Type: application/json" \
      -d '{"username":"probe","password":"probe"}' 2>/dev/null || echo "000")
    if [ "$PROBE" = "200" ] || [ "$PROBE" = "400" ] || [ "$PROBE" = "403" ]; then
      API_READY=1
      break
    fi
    echo "Crafty API not ready after restart (HTTP $PROBE), retrying... ($i/60)"
    sleep 5
  done
  if [ "$API_READY" -eq 0 ]; then
    echo "ERROR: Crafty API did not become ready after DB path repair restart. Aborting."
    docker logs --tail 50 crafty_container 2>&1 || true
    exit 1
  fi

  echo "Re-authenticating after Crafty restart..."
  TOKEN=""
  for attempt in 1 2 3; do
    REAUTH_PAYLOAD=$(jq -n --arg pass "$NEW_CRAFTY_PASS" '{"username":"admin","password":$pass}')
    REAUTH_RES=$(curl -s -k -X POST "https://127.0.0.1:8443/api/v2/auth/login" \
      -H "Content-Type: application/json" \
      -d "$REAUTH_PAYLOAD")
    TOKEN=$(echo "$REAUTH_RES" | jq -r '.data.token // empty')
    if [ -n "$TOKEN" ]; then
      break
    fi
    echo "Post-restart re-auth attempt $attempt failed, retrying in 5s..."
    sleep 5
  done
  if [ -z "$TOKEN" ]; then
    echo "ERROR: Could not re-authenticate after Crafty restart. Aborting."
    exit 1
  fi

  echo "Accepting EULA through Crafty API..."
  echo "SERVER_ID=$SERVER_ID"
  EULA_RES=$(curl -s -k -X POST \
    "https://127.0.0.1:8443/api/v2/servers/$SERVER_ID/action/eula/" \
    -H "Authorization: Bearer $TOKEN")
  echo "EULA response: $EULA_RES"
  EULA_STATUS=$(echo "$EULA_RES" | jq -r '.status // empty' 2>/dev/null || echo "")
  if [ "$EULA_STATUS" != "ok" ]; then
    echo "ERROR: Crafty EULA acceptance failed"
    exit 1
  fi
  echo "Crafty EULA accepted through API."

  chown -R mcs:mcs "$server_dir" || true

  forge_args_file=$(find "$server_dir/libraries/net/minecraftforge/forge" -name unix_args.txt -print -quit 2>/dev/null || true)
  if [ -f "$server_dir/user_jvm_args.txt" ] && [ -n "$forge_args_file" ]; then
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
  fi

  echo "Starting Server $SERVER_ID..."
  START_RES=$(curl -s -k -X POST \
    "https://127.0.0.1:8443/api/v2/servers/$SERVER_ID/action/start_server" \
    -H "Authorization: Bearer $TOKEN")
  echo "Server start command sent (response: $START_RES)."

  sleep 3
  AUTO_RES=$(curl -s -k -X PATCH "https://127.0.0.1:8443/api/v2/servers/$SERVER_ID" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"auto_start": true, "auto_start_delay": 60}')
  AUTO_STATUS=$(echo "$AUTO_RES" | jq -r '.status // empty')
  if [ "$AUTO_STATUS" != "ok" ]; then
    echo "ERROR: Failed to enable autostart (response: $AUTO_RES). Aborting."
    exit 1
  fi
  echo "Autostart enabled (delay: 60s)."
fi

# ── Create Crafty daily backup schedule ──────────────────
echo "Creating daily backup schedule in Crafty..."
# Look up the default backup config ID so the schedule links to it
BACKUP_ID=$(docker exec crafty_container python3 -c "
import sqlite3
con = sqlite3.connect('/crafty/app/config/db/crafty.sqlite')
row = con.execute('SELECT backup_id FROM backups WHERE server_id=? AND \"default\"=1', ('$SERVER_ID',)).fetchone()
print(row[0] if row else '')
con.close()
" 2>/dev/null)
echo "Backup config ID: $${BACKUP_ID:-not found}"

SCHEDULE_PAYLOAD=$(jq -n \
  --arg name "Daily Backup to R2" \
  --arg action_id "$${BACKUP_ID:-}" \
  '{
    name: $name,
    enabled: true,
    action: "backup",
    action_id: $action_id,
    interval: 1,
    interval_type: "days",
    start_time: "04:00",
    one_time: false,
    command: "backup_server",
    cron_string: "",
    delay: 0
  }')
SCHEDULE_RES=$(curl -s -k -X POST "https://127.0.0.1:8443/api/v2/servers/$SERVER_ID/tasks" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "$SCHEDULE_PAYLOAD")
SCHEDULE_STATUS=$(echo "$SCHEDULE_RES" | jq -r '.status // empty' 2>/dev/null || echo "")
if [ "$SCHEDULE_STATUS" = "ok" ]; then
  echo "Daily backup schedule created successfully."
else
  echo "WARNING: Failed to create backup schedule (response: $SCHEDULE_RES)."
fi

# ── Configure Default Backup (shutdown + compress) ───────
echo "Configuring default backup settings..."
docker exec crafty_container python3 -c "
import sqlite3
con = sqlite3.connect('/crafty/app/config/db/crafty.sqlite')
cur = con.cursor()
cur.execute('UPDATE backups SET shutdown=1, compress=1, max_backups=3 WHERE server_id=? AND \"default\"=1', ('$SERVER_ID',))
con.commit()
con.close()
print('Backup config updated.')
" && echo "Default backup configured (shutdown=1, compress=1, max_backups=3)." \
  || echo "WARNING: Failed to update backup config."

# ── Create systemd timer for R2 sync ─────────────────────
cat > /etc/systemd/system/mc-backup-sync.service << 'SVCUNIT'
[Unit]
Description=Sync Crafty backups to R2
After=docker.service
Wants=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/mc-backup-sync.sh
StandardOutput=journal
StandardError=journal
SyslogIdentifier=mc-backup-sync
SVCUNIT

cat > /etc/systemd/system/mc-backup-sync.timer << 'TMRUNIT'
[Unit]
Description=Run mc-backup-sync every 5 minutes
Requires=mc-backup-sync.service

[Timer]
OnCalendar=*:0/5
Persistent=false
Unit=mc-backup-sync.service

[Install]
WantedBy=timers.target
TMRUNIT

systemctl daemon-reload
systemctl enable --now mc-backup-sync.timer
echo "Backup sync timer installed and started."

touch "$DEPLOY_MARKER"
chown mcs:mcs "$DEPLOY_MARKER"

echo "Deployment complete at $(date)."
echo "Crafty credentials stored at: /home/mcs/docker/config/crafty-login.txt"
