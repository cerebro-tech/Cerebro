#!/bin/bash
set -euo pipefail

# Detect the original user (not root)
REAL_USER=${SUDO_USER:-$USER}
USER_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
SCRIPT_PATH="$USER_HOME/cerebro/cerebro-update.sh"

# Check if script exists
if [ ! -f "$SCRIPT_PATH" ]; then
    echo "Error: $SCRIPT_PATH not found!"
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

# 2️⃣ Create interval-aligned timer
TIMER_FILE="/etc/systemd/system/cerebro-update.timer"
sudo tee "$TIMER_FILE" > /dev/null <<EOF
[Unit]
Description=Cerebro Auto Update Timer
Requires=cerebro-update.service

[Timer]
OnCalendar=*-*-* 14:58:00
Persistent=true
WakeSystem=true

[Install]
WantedBy=timers.target
EOF

# 3️⃣ Create suspend/hibernate trigger service
SLEEP_SERVICE_FILE="/etc/systemd/system/cerebro-update-sleep.service"
sudo tee "$SLEEP_SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=Run Cerebro Update Before Suspend/Hibernate
Before=sleep.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH

[Install]
WantedBy=sleep.target
EOF

# 4️⃣ Reload systemd and enable
sudo systemctl daemon-reload
sudo systemctl enable --now cerebro-update.timer
sudo systemctl enable --now cerebro-update-sleep.service

echo "✅ Cerebro update timer and services installed!"
systemctl list-timers cerebro-update.timer
