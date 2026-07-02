#!/bin/bash

REAL=/opt/mc-startup.sh

cat > "$REAL" << 'STARTUP'
${startup_script}
STARTUP

chmod +x "$REAL"
nohup "$REAL" < /dev/null >> /var/log/mc-startup.log 2>&1 &
disown
echo "mc-startup launched (pid $!). Follow: sudo tail -f /var/log/mc-startup.log"
