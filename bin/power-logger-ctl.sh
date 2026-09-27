#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="power-logger"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
SCRIPT_PATH="$(dirname "$(realpath "$0")")/service-scripts/power-logger.py"
DATA_DIR="/srv/data/power"
DATA_OWNER="${SUDO_USER:-$USER}"

install_service() {
    chmod +x "$SCRIPT_PATH"
    # Owned by the user so the data can be cleared without sudo; the root
    # service can still write into it.
    sudo mkdir -p "$DATA_DIR"
    sudo chown "$DATA_OWNER": "$DATA_DIR"

    echo "Creating systemd service..."
    sudo tee "$SERVICE_FILE" > /dev/null << EOF
[Unit]
Description=Whole-system power and energy logger (RAPL CPU + fixed base, estimated)

[Service]
ExecStart=/usr/bin/python3 ${SCRIPT_PATH}
Environment=POWER_DATA_DIR=${DATA_DIR}
Environment=POWER_BASE_W=10
Environment=POWER_FAN_MAX_W=2.5
UMask=0022
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable "$SERVICE_NAME"
    sudo systemctl restart "$SERVICE_NAME"

    echo ""
    echo "✓ Service installed and started. Data: ${DATA_DIR}/YYYY-MM.csv"
    echo "  Status:  sudo systemctl status ${SERVICE_NAME}"
    echo "  Logs:    journalctl -u ${SERVICE_NAME} -f"
}

remove_service() {
    echo "Stopping and removing service..."
    sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    sudo systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    sudo rm -f "$SERVICE_FILE"
    sudo systemctl daemon-reload

    echo ""
    echo "✓ Service removed. Data left in ${DATA_DIR}."
}

echo "Power Logger Service Manager"
echo "============================"
echo ""

if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    echo "Status: RUNNING"
else
    echo "Status: NOT INSTALLED"
fi

echo ""
echo "1) Install / reinstall service"
echo "2) Remove service"
echo "3) Cancel"
echo ""
read -rp "Choice [1/2/3]: " choice

case "$choice" in
    1) install_service ;;
    2) remove_service ;;
    *) echo "Cancelled." ;;
esac
