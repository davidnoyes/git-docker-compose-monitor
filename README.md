# GitHub Docker Compose Monitor

This project allows you to monitor multiple private GitHub repositories for Docker Compose projects and automatically deploy them when changes are detected.

## Features

- Per-project configuration using `.env` files
- Zero-downtime Docker Compose deployment logic
- Supports commit message directives for control:
    - `[compose:down]`: Force full restart
    - `[compose:up]`: Force in-place update
    - `[compose:restart:<service>]`: Restart a specific service
    - `[compose:noop]`: Skip deployment
- Discord notifications on changes or errors
- systemd timers for periodic polling

## Directory Structure

```plaintext
/opt/github-monitor/
  common/
    deploy.sh                  # Shared logic
  projects/
    project1/
      .env                     # Project-specific configuration
/etc/systemd/system/
  github-monitor@.service      # systemd service template
  github-monitor@.timer        # systemd timer template
```

## Usage

1. Edit `projects/project1/.env` with your Git repo and webhook details.
2. Copy `common/deploy.sh` and systemd templates to the appropriate locations.
3. Enable with:

   ```bash
   sudo systemctl enable --now github-monitor@project1.timer
   ```

4. View logs with:

   ```bash
   journalctl -u github-monitor@project1
   ```

## License

MIT
