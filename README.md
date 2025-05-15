# gh-docker-compose-monitor

This project allows you to monitor multiple private GitHub repositories for Docker Compose projects and automatically deploy them when changes are detected.

## Features

- Per-project configuration using `config` files
- Zero-downtime Docker Compose deployment logic
- Supports commit message directives for control:
  - `[compose:down]`: Force full restart
  - `[compose:up]`: Force in-place update
  - `[compose:restart:<service>]`: Restart a specific service
  - `[compose:noop]`: Skip deployment
- Discord notifications on changes or errors
- systemd timers for periodic polling

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

### Generate SSH key pair:
```bash
sudo -u composebot ssh-keygen -t ed25519 -f /home/composebot/.ssh/github_compose -N ""
```

### Configure GitHub SSH access:
```bash
sudo -u composebot mkdir -p /home/composebot/.ssh
sudo -u composebot bash -c 'echo -e "Host github.com\n  HostName github.com\n  IdentityFile ~/.ssh/github_compose\n  IdentitiesOnly yes" > /home/composebot/.ssh/config'
sudo chown -R composebot:composebot /home/composebot/.ssh
chmod 700 /home/composebot/.ssh
sudo chmod 600 /home/composebot/.ssh/github_compose
sudo chmod 600 /home/composebot/.ssh/github_compose.pub
sudo chmod 600 /home/composebot/.ssh/config
```

### Add GitHub fingerprint to known_hosts:
```bash
sudo ssh-keyscan github.com | sudo -u composebot tee /home/composebot/.ssh/known_hosts > /dev/null
sudo chmod 600 /home/composebot/.ssh/known_hosts
```

This ensures `git clone` and `git fetch` work without prompting to trust GitHub the first time.

## 📁 Directory Structure

```
/opt/gh-docker-compose-monitor/
  common/
    compose-deploy.sh
  projects/
    project1/
      config
/etc/systemd/system/
  gh-docker-compose-monitor@.service
  gh-docker-compose-monitor@.timer
```

## 🚀 Usage

1. Edit `projects/project1/config` with your Git repo and webhook details.
2. Run the install script:
   ```bash
   sudo ./install.sh project1
   ```
3. View logs with:
   ```bash
   journalctl -u gh-docker-compose-monitor@project1
   ```

## 📜 License

MIT
