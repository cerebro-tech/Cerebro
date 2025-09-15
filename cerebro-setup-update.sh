#!/bin/bash
set -euo pipefail

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

echo "Created service: $SERVICE_FILE"

# 2️⃣ Create interval-aligned timer
TIMER_FILE="/etc/systemd/system/cerebro-update.timer"
sudo tee "$TIMER_FILE" > /dev/null <<EOF
[Unit]
Description=Cerebro Auto Update Timer
Requires=cerebro-update.service

[Timer]
# Run at 4AM every day, script handles 3-day interval
OnCalendar=*-*-* 14:30:00
Persistent=true
WakeSystem=true

[Install]
WantedBy=timers.target
EOF

echo "Created timer: $TIMER_FILE"

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

echo "Created sleep service: $SLEEP_SERVICE_FILE"

# 4️⃣ Reload systemd and enable timer + sleep service
sudo systemctl daemon-reload
sudo systemctl enable --now cerebro-update.timer
sudo systemctl enable --now cerebro-update-sleep.service

echo "✅ Cerebro update timer and services installed and enabled!"
echo "Next scheduled run:"
systemctl list-timers cerebro-update.timer
