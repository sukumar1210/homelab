#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="mdns-unicast-bridge"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
SCRIPT_PATH="$(dirname "$(realpath "$0")")/service-scripts/mdns-unicast-bridge.py"

install_service() {
    chmod +x "$SCRIPT_PATH"

    echo "Creating systemd service..."
    sudo tee "$SERVICE_FILE" > /dev/null << EOF
[Unit]
Description=mDNS unicast bridge for wired-to-WiFi discovery
After=network-online.target avahi-daemon.service
Wants=network-online.target

[Service]
ExecStart=/usr/bin/python3 ${SCRIPT_PATH}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable "$SERVICE_NAME"
    sudo systemctl restart "$SERVICE_NAME"

    echo ""
    echo "✓ Service installed and started."
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
    echo "✓ Service removed. ${SCRIPT_PATH} stays: it is part of this repository."
}

# Non-interactive, for the `homelab` command; with no argument, the menu below.
case "${1:-}" in
    install) install_service; exit ;;
    remove)  remove_service; exit ;;
    "") ;;
    *) echo "usage: $0 [install|remove]" >&2; exit 2 ;;
esac

echo "mDNS Unicast Bridge Service Manager"
echo "===================================="
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
