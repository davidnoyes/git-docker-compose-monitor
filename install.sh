#!/bin/bash
set -euo pipefail

PROJECT_NAME="${1:-project1}"
USER="deploy"
BASE_DIR="/opt/github-monitor"
SCRIPT_SRC_DIR="$(dirname "$0")"
SCRIPT_PATH="$BASE_DIR/common/deploy.sh"
ENV_FILE="$BASE_DIR/projects/$PROJECT_NAME/.env"
SYSTEMD_DIR="/etc/systemd/system"

# Ensure script is run as root
if [[ "$EUID" -ne 0 ]]; then
  echo "Please run as root (e.g. with sudo)"
  exit 1
fi

echo "[*] Verifying project .env exists for '$PROJECT_NAME'"
if [ ! -f "$SCRIPT_SRC_DIR/projects/$PROJECT_NAME/.env" ]; then
  echo "ERROR: Environment file '$SCRIPT_SRC_DIR/projects/$PROJECT_NAME/.env' not found."
  exit 1
fi

echo "[*] Creating deployment directories..."
mkdir -p "$BASE_DIR/common"
mkdir -p "$BASE_DIR/projects/$PROJECT_NAME"

echo "[*] Installing deploy script..."
cp "$SCRIPT_SRC_DIR/common/deploy.sh" "$SCRIPT_PATH"
chmod +x "$SCRIPT_PATH"
chown "$USER:$USER" "$SCRIPT_PATH"

echo "[*] Installing environment file..."
cp "$SCRIPT_SRC_DIR/projects/$PROJECT_NAME/.env" "$ENV_FILE"
chmod 600 "$ENV_FILE"
chown "$USER:$USER" "$ENV_FILE"

echo "[*] Installing systemd templates..."
cp "$SCRIPT_SRC_DIR/systemd/github-monitor@.service" "$SYSTEMD_DIR/github-monitor@.service"
cp "$SCRIPT_SRC_DIR/systemd/github-monitor@.timer" "$SYSTEMD_DIR/github-monitor@.timer"

echo "[*] Reloading systemd..."
systemctl daemon-reexec
systemctl daemon-reload

echo "[*] Enabling and starting timer for $PROJECT_NAME..."
systemctl enable --now "github-monitor@${PROJECT_NAME}.timer"

echo "[✔] Installation complete for project: $PROJECT_NAME"
echo "🛈 To check logs:"
echo "  journalctl -u github-monitor@${PROJECT_NAME}"
