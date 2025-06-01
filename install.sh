#!/bin/bash
set -euo pipefail

PROJECT_NAME="${1:-project1}"
USER="composebot"
BASE_DIR="/opt/gh-docker-compose-monitor"
SCRIPT_SRC_DIR="$(dirname "$0")"
SCRIPT_PATH="$BASE_DIR/common/compose-deploy.sh"
CONFIG_FILE="$BASE_DIR/projects/$PROJECT_NAME/config"
SYSTEMD_DIR="/etc/systemd/system"

if [[ $EUID -ne 0 ]]; then
	echo "Please run as root (e.g. with sudo)"
	exit 1
fi

echo "[*] Verifying project config exists for '$PROJECT_NAME'"
if [ ! -f "$SCRIPT_SRC_DIR/projects/$PROJECT_NAME/config" ]; then
	echo "ERROR: Configuration file '$SCRIPT_SRC_DIR/projects/$PROJECT_NAME/config' not found."
	exit 1
fi

echo "[*] Creating deployment directories..."
mkdir -p "$BASE_DIR/common"
mkdir -p "$BASE_DIR/projects/$PROJECT_NAME"

echo "[*] Installing deploy script..."
cp "$SCRIPT_SRC_DIR/common/compose-deploy.sh" "$SCRIPT_PATH"
chmod +x "$SCRIPT_PATH"
chown "$USER:$USER" "$SCRIPT_PATH"

echo "[*] Installing configuration file..."
cp "$SCRIPT_SRC_DIR/projects/$PROJECT_NAME/config" "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"
chown "$USER:$USER" "$CONFIG_FILE"

echo "[*] Installing systemd templates..."
cp "$SCRIPT_SRC_DIR/systemd/gh-docker-compose-monitor@.service" "$SYSTEMD_DIR/gh-docker-compose-monitor@.service"
cp "$SCRIPT_SRC_DIR/systemd/gh-docker-compose-monitor@.timer" "$SYSTEMD_DIR/gh-docker-compose-monitor@.timer"

echo "[*] Adding GitHub fingerprint to known_hosts..."
sudo -u $USER mkdir -p /home/$USER/.ssh
sudo ssh-keyscan github.com | sudo -u $USER tee /home/$USER/.ssh/known_hosts >/dev/null
sudo chown -R $USER:$USER /home/$USER/.ssh
chmod 700 /home/$USER/.ssh
chmod 600 /home/$USER/.ssh/known_hosts

echo "[*] Reloading systemd..."
systemctl daemon-reexec
systemctl daemon-reload

echo "[*] Enabling and starting timer for $PROJECT_NAME..."
systemctl enable --now "gh-docker-compose-monitor@${PROJECT_NAME}.timer"

echo "[✔] Installation complete for project: $PROJECT_NAME"
echo "🛈 To check logs:"
echo "  journalctl -u gh-docker-compose-monitor@${PROJECT_NAME}"
