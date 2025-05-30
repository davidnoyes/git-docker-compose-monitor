# gh-docker-compose-monitor

This project allows you to monitor multiple private GitHub repositories for Docker Compose projects and automatically deploy them when changes are detected.

## Features

- Per-project configuration using `config` files
- Zero-downtime Docker Compose deployment logic
- Supports commit message directives for control:
    - `[compose:down]`: Force full restart (compose down/up)
    - `[compose:up]`: Force in-place update (compose up --build)
    - `[compose:restart:<service>]`: Restart a specific service
    - `[compose:noop]`: Skip deployment
- Discord notifications on changes, errors, and deployment actions (with commit message and hash)
- systemd timers for periodic polling
- Robust error handling and validation of required config/environment variables
- Cross-platform (Linux/macOS) shell scripting, no third-party dependencies

## ⚙️ System User Setup: `composebot`

Before installing, create a dedicated Linux user to securely manage Docker Compose deployments.

### 1. Create the user

```bash
sudo useradd --system --create-home --shell /usr/sbin/nologin composebot
```

### 2. Add the user to the Docker group

```bash
sudo usermod -aG docker composebot
```

## 🔐 SSH Key Setup for GitHub Access (non-interactive)

If your GitHub repository is private, configure SSH keys for `composebot`:

### Generate SSH key pair

```bash
sudo -u composebot ssh-keygen -t ed25519 -f /home/composebot/.ssh/github_compose -N ""
```

### Configure GitHub SSH access

```bash
sudo -u composebot mkdir -p /home/composebot/.ssh
sudo -u composebot bash -c 'echo -e "Host github.com\n  HostName github.com\n  IdentityFile ~/.ssh/github_compose\n  IdentitiesOnly yes" > /home/composebot/.ssh/config'
sudo chown -R composebot:composebot /home/composebot/.ssh
chmod 700 /home/composebot/.ssh
sudo chmod 600 /home/composebot/.ssh/github_compose
sudo chmod 600 /home/composebot/.ssh/github_compose.pub
sudo chmod 600 /home/composebot/.ssh/config
```

### Add GitHub fingerprint to known_hosts

```bash
sudo ssh-keyscan github.com | sudo -u composebot tee /home/composebot/.ssh/known_hosts > /dev/null
sudo chmod 600 /home/composebot/.ssh/known_hosts
```

This ensures `git clone` and `git fetch` work without prompting to trust GitHub the first time.

## 📁 Directory Structure

```bash
/opt/gh-docker-compose-monitor/
  common/
    compose-deploy.sh
  projects/
    project1/
      config
/etc/systemd/system/
  gh-docker-compose-monitor.service
  gh-docker-compose-monitor.timer
```

## 🚀 Usage

1. **Edit the config file:**  
   Edit `projects/project1/config` with your Git repo and webhook details.  
   **Required variables:**  
   - `PROJECT_NAME`
   - `PROJECT_DIR`
   - `REPO_URL`
   - (Optional) `DISCORD_WEBHOOK_URL` (can also be set as an environment variable)

2. **Copy the script and config to your target location:**  
   Place `compose-deploy.sh` and your `config` file in a directory on your server, for example:

   ```bash
   sudo mkdir -p /opt/gh-docker-compose-monitor/projects/project1
   sudo cp common/compose-deploy.sh /opt/gh-docker-compose-monitor/common/
   sudo cp projects/project1/config /opt/gh-docker-compose-monitor/projects/project1/config
   sudo chmod +x /opt/gh-docker-compose-monitor/common/compose-deploy.sh
   ```

3. **Install the systemd service and timer:**  
   Copy the provided unit files to `/etc/systemd/system/`:

   ```bash
   sudo cp systemd/gh-docker-compose-monitor.service /etc/systemd/system/
   sudo cp systemd/gh-docker-compose-monitor.timer /etc/systemd/system/
   ```

4. **Enable and start the timer:**  

   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable --now gh-docker-compose-monitor.timer
   ```

5. **View logs:**  

   ```bash
   journalctl -u gh-docker-compose-monitor
   ```

6. **Manual run (for testing):**  
   You can manually run the script at any time:

   ```bash
   /opt/gh-docker-compose-monitor/common/compose-deploy.sh --config-file=/opt/gh-docker-compose-monitor/projects/project1/config
   ```

Example usage:

```bash
/opt/gh-docker-compose-monitor/common/compose-deploy.sh --config-file=/opt/gh-docker-compose-monitor/projects/project1/config
```

---

### 🔧 Script Flags

- `--config-file=PATH`: **(Required)** Specify the configuration file for the project.
- `--test-discord`: Send a test notification to the configured Discord webhook and exit. The test message includes a realistic multi-line commit message and a full-length commit hash.
- `--log-level=LEVEL`: Set log verbosity. Options are `DEBUG`, `INFO`, `WARN`, `ERROR`. Default is `INFO`.
- `--force-sync`: Force a `git pull` from the remote repository before any other actions.
- `--force-up`: Run `docker compose up -d` regardless of git or Compose file changes. If used with `--force-sync`, the git pull will happen first.
- `--help` or `-h`: Show usage information.

Example:

```bash
./compose-deploy.sh --config-file=./projects/project1/config --force-sync --force-up --log-level=DEBUG
```

---

### ⚠️ Requirements

- **yq** is required for YAML parsing.  
  Install with:
  ```bash
  sudo wget -O /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
  sudo chmod +x /usr/local/bin/yq
  ```
  The script will exit with an error if `yq` is not installed.

---

### 📝 Floating Tag Image Checks

- The interval for checking floating tag images (e.g., `latest`, `develop`, `edge`, `nightly`) is controlled by `FLOATING_IMAGE_PULL_INTERVAL_MINUTES` in your config file.
- **Set to `0` to disable floating tag image checks entirely.**
- When enabled, the script will only redeploy containers if the image ID of the running container differs from the latest pulled image.

---

## 🛡️ Validation & Error Handling

- The script validates that all required variables are set in the config file.
- The `DISCORD_WEBHOOK_URL` must be set in the environment or config.
- All user-facing messages are timestamped and respect the configured log level.
- If Docker Compose commands fail, error output is sent to Discord.
- All Discord notifications are properly escaped for Markdown and JSON.

## 📦 Discord Notifications

- Deployment notifications include the action, commit hash (as code), and commit message.
- Errors and important events are sent to Discord with full context.
- Markdown formatting is preserved for commit hashes and messages.

## 📜 License

MIT
