#!/bin/bash
set -euo pipefail

# Sends a notification to Discord and prints to stdout
function notify() {
    local title="$1"
    local message="$2"
    # Escape backticks for Discord formatting in the title only
    local esc_title esc_message json_payload
    esc_title=$(echo "$title" | sed 's/`/\\`/g')
    # For the message, escape backslashes and double quotes, but NOT backticks
    esc_message=$(echo "$message" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk '{printf "%s\\n", $0}' | sed '$s/\\n$//')
    json_payload="{\"embeds\":[{\"title\":\"$esc_title\",\"description\":\"$esc_message\",\"color\":5814783}]}"
    echo "$title: $message"
    if [[ -z "${DISCORD_WEBHOOK_URL:-}" ]]; then return; fi
    curl -s -X POST -H "Content-Type: application/json" \
      -d "$json_payload" \
      "$DISCORD_WEBHOOK_URL" > /dev/null
}

# Standard logging function with timestamp
function log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

escape_json() {
  # Escape backslashes, then double quotes, then control characters
  echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\r//g'
}

CONFIG_FILE=""
TEST_DISCORD=false
# Parse command-line arguments
for arg in "$@"; do
  case $arg in
    --help|-h)
      echo "gh-docker-compose-monitor compose-deploy.sh"
      echo "Usage: $0 --config-file=PATH [--test-discord] [--help|-h]"
      echo ""
      echo "Automates git pull, Docker Compose file diff, and deployment for a project."
      echo ""
      echo "Flags:"
      echo "  --config-file=PATH   (Required) Specify project config file."
      echo "  --test-discord       Send a test notification to Discord and exit."
      echo "  --help, -h           Show this help message and exit."
      exit 0
      ;;
    --config-file=*)
      CONFIG_FILE="${arg#*=}"
      shift
      ;;
    --test-discord)
      TEST_DISCORD=true
      shift
      ;;
  esac
done

# Ensure config file is provided
if [ -z "$CONFIG_FILE" ]; then
  log "ERROR: --config-file=PATH is required."
  exit 1
fi

# Load project config file (must define PROJECT_NAME, PROJECT_DIR, REPO_URL, etc.)
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

# Validate required config variables
REQUIRED_VARS=(PROJECT_NAME PROJECT_DIR REPO_URL)
for var in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!var:-}" ]; then
    log "ERROR: Required variable '$var' is not set in $CONFIG_FILE."
    exit 1
  fi
done

# Validate Discord webhook for notifications
if [[ -z "${DISCORD_WEBHOOK_URL:-}" ]]; then
  log "ERROR: DISCORD_WEBHOOK_URL environment variable is not set."
  exit 1
fi

REPO_DIR="$PROJECT_DIR/repo"
COMPOSE_HASH_FILE="$PROJECT_DIR/.compose_hash"
LAST_COMPOSE_FILE="$PROJECT_DIR/.last_compose.yaml"

# Allow testing Discord notifications directly
if $TEST_DISCORD; then
    TEST_COMMIT_MSG="This is a test commit message.
It has multiple lines.
- Bullet 1
- Bullet 2
End of message."
    TEST_COMMIT_ID="2d95998b028770216187947dde4583969037fcf6"
    message="Action: Compose file changed — safe update
Commit: \`$TEST_COMMIT_ID\`
Message: $TEST_COMMIT_MSG"
    notify "Test Project - Deployment complete" "$message"
    echo "✔ Discord test message sent."
    exit 0
fi

# Error handler for the script
function handle_error() {
    local exit_code=$?
    local msg="ERROR: Script failed with exit code $exit_code"
    # If docker compose error output exists, include it in the notification
    if [ -s /tmp/compose_error.log ]; then
        local compose_err
        compose_err=$(cat /tmp/compose_error.log)
        msg="$msg

Docker Compose error output:
$compose_err"
    fi
    echo "$msg"
    notify "Deployment Error" "$msg"
    exit $exit_code
}
trap handle_error ERR

log "Starting sync..."

# Clone repo if it doesn't exist
if [ ! -d "$REPO_DIR/.git" ]; then
    git clone --quiet "$REPO_URL" "$REPO_DIR"
fi

cd "$REPO_DIR"
git fetch --quiet origin main > /dev/null 2>&1

LOCAL_HASH=$(git rev-parse HEAD)
REMOTE_HASH=$(git rev-parse origin/main)

# Check if there are any new commits or if this is the first run
if [ "$LOCAL_HASH" == "$REMOTE_HASH" ]; then
    if [ ! -f "$COMPOSE_HASH_FILE" ]; then
        log "First run detected — no prior Compose file hash, proceeding with initial deployment."
    elif ! docker compose --project-name "$PROJECT_NAME" ps --quiet | grep -q .; then
        log "No running containers for project — performing initial deployment."
    else
        log "No Git changes detected. Exiting."
        exit 0
    fi
fi

log "Git changes detected or initial deploy. Pulling latest..."
git reset --hard -q origin/main > /dev/null 2>&1
COMMIT_MSG=$(git log -1 --pretty=%B)

FORCE_DOWN=false
FORCE_UP=false
SKIP_DEPLOY=false
RESTART_SERVICE=""

# Parse commit message for deployment directives
[[ "$COMMIT_MSG" == *"[compose:noop]"* ]] && SKIP_DEPLOY=true
[[ "$COMMIT_MSG" == *"[compose:down]"* ]] && FORCE_DOWN=true
[[ "$COMMIT_MSG" == *"[compose:up]"* ]] && FORCE_UP=true
[[ "$COMMIT_MSG" =~ \[compose:restart:(.+)\] ]] && RESTART_SERVICE="${BASH_REMATCH[1]}"

if $SKIP_DEPLOY; then
    log "Skipping deploy due to [compose:noop]"
    notify "Deployment Skipped" "Commit: \`$REMOTE_HASH\`
Directive: \`[compose:noop]\`"
    exit 0
fi

# Generate Compose YAML for diffing and hash calculation
docker compose --project-name "$PROJECT_NAME" config > /tmp/${PROJECT_NAME}_compose.yaml 2>/tmp/compose_error.log
CURRENT_HASH=$(sha256sum /tmp/${PROJECT_NAME}_compose.yaml | awk '{print $1}')
PREVIOUS_HASH=$(cat "$COMPOSE_HASH_FILE" 2>/dev/null || echo "none")

IMAGE_CHANGED=false

# Detect if any image lines have changed in the Compose file
if [[ "$CURRENT_HASH" != "$PREVIOUS_HASH" ]]; then
    if grep -q 'image:' /tmp/${PROJECT_NAME}_compose.yaml; then
        IMAGE_CHANGED=true
    fi
fi

ACTION="none"

# Handle forced full restart
if $FORCE_DOWN; then
    : > /tmp/compose_error.log
    docker compose --project-name "$PROJECT_NAME" down --remove-orphans 2>/tmp/compose_error.log
    if $IMAGE_CHANGED; then
        docker compose --project-name "$PROJECT_NAME" pull 2>/tmp/compose_error.log
    fi
    docker compose --project-name "$PROJECT_NAME" up -d --build 2>/tmp/compose_error.log
    ACTION="Forced full restart [compose:down]"

# Handle single service restart
elif [[ -n "$RESTART_SERVICE" ]]; then
    : > /tmp/compose_error.log
    docker compose --project-name "$PROJECT_NAME" up -d --build "$RESTART_SERVICE" 2>/tmp/compose_error.log
    ACTION="Restarted service \`$RESTART_SERVICE\` [compose:restart:$RESTART_SERVICE]"

# Handle forced update
elif $FORCE_UP; then
    : > /tmp/compose_error.log
    if $IMAGE_CHANGED; then
        docker compose --project-name "$PROJECT_NAME" pull 2>/tmp/compose_error.log
    fi
    docker compose --project-name "$PROJECT_NAME" up -d --build 2>/tmp/compose_error.log
    ACTION="Forced update [compose:up]"

# Handle Compose file changes
elif [[ "$CURRENT_HASH" != "$PREVIOUS_HASH" ]]; then
    if [ -f "$LAST_COMPOSE_FILE" ]; then
        # Detect removed or renamed services, volumes, or networks in Compose file
        # Only trigger a full restart if a top-level service/volume/network or their block is removed
        REMOVED=$(diff -u "$LAST_COMPOSE_FILE" /tmp/${PROJECT_NAME}_compose.yaml \
            | grep '^-' \
            | grep -E '^\-\s+(services:|volumes:|networks:)$|^\-\s{2,}[a-zA-Z0-9_-]+:$' || true)
    else
        REMOVED="yes"
    fi

    if [[ -n "$REMOVED" ]]; then
        : > /tmp/compose_error.log
        docker compose --project-name "$PROJECT_NAME" down --remove-orphans 2>/tmp/compose_error.log
        if $IMAGE_CHANGED; then
            docker compose --project-name "$PROJECT_NAME" pull 2>/tmp/compose_error.log
        fi
        docker compose --project-name "$PROJECT_NAME" up -d --build 2>/tmp/compose_error.log
        ACTION="Compose file changed — removal detected, full restart triggered"
    else
        : > /tmp/compose_error.log
        if $IMAGE_CHANGED; then
            docker compose --project-name "$PROJECT_NAME" pull 2>/tmp/compose_error.log
        fi
        docker compose --project-name "$PROJECT_NAME" up -d --build 2>/tmp/compose_error.log
        ACTION="Compose file changed — safe update"
    fi
else
    # No Compose file changes detected, just ensure containers are up
    : > /tmp/compose_error.log
    docker compose --project-name "$PROJECT_NAME" up -d 2>/tmp/compose_error.log
    ACTION="No Compose file changes — safe up"
fi

# Save the latest Compose YAML and hash for future comparisons
mv /tmp/${PROJECT_NAME}_compose.yaml "$LAST_COMPOSE_FILE"
echo "$CURRENT_HASH" > "$COMPOSE_HASH_FILE"

# Sanitize commit message for Discord (escape backticks and newlines)
SANITIZED_COMMIT_MSG=$(echo "$COMMIT_MSG" | sed 's/`/\\`/g' | tr '\n' '\\n')

# Notify user of deployment result
if [[ "$ACTION" == "Compose file changed — removal detected, full restart triggered" ]] || \
   [[ "$ACTION" == "Compose file changed — safe update" ]] || \
   [[ "$ACTION" == "Forced full restart [compose:down]" ]] || \
   [[ "$ACTION" == "Forced update [compose:up]" ]] || \
   [[ "$ACTION" =~ Restarted\ service ]]; then
    notify "$PROJECT_NAME - Deployment complete" "Action: $ACTION
Commit: \`$REMOTE_HASH\`
Message: $COMMIT_MSG"
else
    notify "$PROJECT_NAME - Deployment complete" "Action: $ACTION"
fi
