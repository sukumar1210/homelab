#!/bin/bash
set -e

SERVICE="/etc/systemd/system/nextboot.service"

sudo tee "$SERVICE" > /dev/null <<'SERVICE_EOF'
[Unit]
Description=Queue current OS as next boot
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'OS=$(. /etc/os-release && echo "$ID"); BOOT_ID=$(/usr/bin/efibootmgr | awk -v os="$OS" '\''BEGIN{IGNORECASE=1} $0 ~ "^Boot[0-9]+.*" os {print substr($1,5,4); exit}'\''); if [ -z "$BOOT_ID" ]; then echo "EFI boot entry for $OS not found"; exit 1; fi; echo "Current OS: $OS"; echo "EFI boot entry: Boot$BOOT_ID"; /usr/bin/efibootmgr --bootnext "$BOOT_ID"'

[Install]
WantedBy=multi-user.target
SERVICE_EOF

sudo systemctl daemon-reload
sudo systemctl enable nextboot.service
sudo systemctl start nextboot.service

echo "=== nextboot ==="
systemctl status nextboot.service --no-pager
echo "=== EFI ==="
sudo efibootmgr
