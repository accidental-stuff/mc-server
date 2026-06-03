#!/bin/bash

REAL=/opt/mc-startup.sh

# startup.sh content is embedded below by Terraform templatefile
cat > "$REAL" << 'STARTUP'
${startup_script}
STARTUP

chmod +x "$REAL"
nohup "$REAL" > /dev/null 2>&1 &
disown
echo "mc-startup launched (pid $!). Follow: sudo tail -f /var/log/mc-startup.log"
