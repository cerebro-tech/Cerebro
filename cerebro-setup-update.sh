#!/bin/bash
set -euo pipefail

# Detect the real (non-root) user home
REAL_USER=${SUDO_USER:-$USER}
USER_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
SCRIPT_PATH="$USER_HOME/cerebro/cerebro-update.sh"

# Check if update script exists
if [ ! -f "$SCRIPT_PATH" ]; then
    echo "❌ Error: $SCRIPT_PATH not found!"
    exit 1
fi

# 1️⃣ Create main systemd service
SERVICE_FILE="/etc/systemd/system/cerebro-update.service"
sudo tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=Cerebro Auto Update
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH
EOF

echo "✅ Created service: $SERVICE_FILE"

# 2️⃣ Create timer (runs daily at 4AM, script enforces 3-day interval)
TIMER_FILE="/etc/systemd/system/cerebro-update.timer"
sudo tee "$TIMER_FILE" > /dev/null <<EOF
[Unit]
Description=Cerebro Auto Update Timer
Requires=cerebro-update.service

[Timer]
# Run every day at 4AM, script enforces once/3 days via marker
OnCalendar=*-*-* 04:00:00
Persistent=true
WakeSystem=true

[Install]
WantedBy=timers.target
EOF

echo "✅ Created timer: $TIMER_FILE"

# 3️⃣ Reload systemd and enable timer
sudo systemctl daemon-reload
sudo systemctl enable --now cerebro-update.timer

echo "✅ Cerebro auto-update installed and enabled!"
echo "⏱  Next scheduled runs:"
systemctl list-timers cerebro-update.timer | grep cerebro-update
