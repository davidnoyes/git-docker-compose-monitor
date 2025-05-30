#!/bin/bash
set -euo pipefail

# Check for yq dependency
if ! command -v yq >/dev/null 2>&1; then
    echo "ERROR: 'yq' is required but not installed. Please install yq (https://github.com/mikefarah/yq) and try again."
    exit 1
fi

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

# Standard logging function with log levels
LOG_LEVEL="INFO"
LOG_LEVELS=("DEBUG" "INFO" "WARN" "ERROR")

function log() {
    local level="$1"
    shift
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
    # Map log levels to numbers
    case "$level" in
        DEBUG) level_num=0 ;;
        INFO)  level_num=1 ;;
        WARN)  level_num=2 ;;
        ERROR) level_num=3 ;;
        *)     level_num=1 ;; # Default to INFO
    esac
    case "$LOG_LEVEL" in
        DEBUG) min_level=0 ;;
        INFO)  min_level=1 ;;
        WARN)  min_level=2 ;;
        ERROR) min_level=3 ;;
        *)     min_level=1 ;;
    esac
    if [ "$level_num" -ge "$min_level" ]; then
        echo "$msg"
    fi
}

escape_json() {
  # Escape backslashes, then double quotes, then control characters
  echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\r//g'
}

CONFIG_FILE=""
TEST_DISCORD=false
FORCE_UP_FLAG=false
FORCE_SYNC_FLAG=false

# Parse command-line arguments
for arg in "$@"; do
  case $arg in
    --help|-h)
      echo "gh-docker-compose-monitor compose-deploy.sh"
      echo "Usage: $0 --config-file=PATH [--test-discord] [--log-level=LEVEL] [--force-sync] [--force-up] [--help|-h]"
      echo ""
      echo "Automates git pull, Docker Compose file diff, and deployment for a project."
      echo ""
      echo "Flags:"
      echo "  --config-file=PATH   (Required) Specify project config file."
      echo "  --test-discord       Send a test notification to Discord and exit."
      echo "  --log-level=LEVEL    Set log level (DEBUG, INFO, WARN, ERROR). Default: INFO."
      echo "  --force-sync         Force a git pull before any other actions."
      echo "  --force-up           Run 'docker compose up -d' regardless of git changes. If used with --force-sync, git pull happens first."
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
    --log-level=*)
      LOG_LEVEL="${arg#*=}"
      shift
      ;;
    --force-up)
      FORCE_UP_FLAG=true
      shift
      ;;
    --force-sync)
      FORCE_SYNC_FLAG=true
      shift
      ;;
  esac
done

# Ensure config file is provided
if [ -z "$CONFIG_FILE" ]; then
  log ERROR "--config-file=PATH is required."
  exit 1
fi

# Load project config file (must define PROJECT_NAME, PROJECT_DIR, REPO_URL, etc.)
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

# Validate required config variables
REQUIRED_VARS=(PROJECT_NAME PROJECT_DIR REPO_URL)
for var in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!var:-}" ]; then
    log ERROR "Required variable '$var' is not set in $CONFIG_FILE."
    exit 1
  fi
done

# Validate Discord webhook for notifications
if [[ -z "${DISCORD_WEBHOOK_URL:-}" ]]; then
  log ERROR "DISCORD_WEBHOOK_URL environment variable is not set."
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

log INFO "Starting sync..."

# Clone repo if it doesn't exist
if [ ! -d "$REPO_DIR/.git" ]; then
    git clone --quiet "$REPO_URL" "$REPO_DIR"
fi

cd "$REPO_DIR"

# --force-sync flag logic (should be before force-up)
if $FORCE_SYNC_FLAG; then
    log INFO "--force-sync flag detected. Forcing git pull."
    git fetch --quiet origin main > /dev/null 2>&1
    git reset --hard -q origin/main > /dev/null 2>&1
fi

git fetch --quiet origin main > /dev/null 2>&1

LOCAL_HASH=$(git rev-parse HEAD)
REMOTE_HASH=$(git rev-parse origin/main)

# Generate Compose YAML for diffing and hash calculation
# (We capture stderr to /tmp/compose_error.log here so that if the config is invalid,
# the error can be included in Discord notifications by the error handler.)
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

# Detect floating tags in Compose YAML
FLOATING_TAGS_REGEX=':(latest|develop|edge|nightly)$'
FLOATING_TAG_FOUND=false
if grep -E "image:.*$FLOATING_TAGS_REGEX" /tmp/${PROJECT_NAME}_compose.yaml > /dev/null; then
    FLOATING_TAG_FOUND=true
fi

# Default interval if not set in config
FLOATING_IMAGE_PULL_INTERVAL_MINUTES="${FLOATING_IMAGE_PULL_INTERVAL_MINUTES:-60}"
FLOATING_PULL_STATE_FILE="$PROJECT_DIR/.last_floating_pull"

NEED_FLOATING_PULL=false
if $FLOATING_TAG_FOUND; then
    NOW_EPOCH=$(date +%s)
    LAST_PULL_EPOCH=0
    if [ -f "$FLOATING_PULL_STATE_FILE" ]; then
        LAST_PULL_EPOCH=$(cat "$FLOATING_PULL_STATE_FILE")
    fi
    INTERVAL_SEC=$((FLOATING_IMAGE_PULL_INTERVAL_MINUTES * 60))
    if (( FLOATING_IMAGE_PULL_INTERVAL_MINUTES > 0 )) && (( NOW_EPOCH - LAST_PULL_EPOCH >= INTERVAL_SEC )); then
        NEED_FLOATING_PULL=true
    fi
fi

# --force-up flag logic (should be here)
if $FORCE_UP_FLAG; then
    log INFO "--force-up flag detected. Running 'docker compose up -d' regardless of git changes."
    docker compose --project-name "$PROJECT_NAME" up -d
    ACTION="Forced up via --force-up flag"
    notify "$PROJECT_NAME - Deployment complete" "Action: $ACTION"
    exit 0
fi

# If no git/compose changes and no floating pull needed, exit if containers are running
if [ "$LOCAL_HASH" == "$REMOTE_HASH" ] && [ -f "$COMPOSE_HASH_FILE" ] && ! $NEED_FLOATING_PULL; then
    # More robust check for running containers
    CONTAINER_IDS=$(docker compose --project-name "$PROJECT_NAME" ps --quiet)
    if [ -z "$CONTAINER_IDS" ]; then
        log WARN "No running containers for project ($PROJECT_NAME) — performing initial deployment."
        log DEBUG "docker compose ps output:"
        docker compose --project-name "$PROJECT_NAME" ps
        log DEBUG "docker ps -a (filtered by project label):"
        docker ps -a --filter "label=com.docker.compose.project=$PROJECT_NAME"
    else
        log DEBUG "Found running containers for project ($PROJECT_NAME): $CONTAINER_IDS"
        log INFO "No Git changes detected. Exiting."
        exit 0
    fi
fi

# If floating tag needs a pull, do it and exit
if $NEED_FLOATING_PULL; then
    log INFO "Floating tag image detected and interval elapsed. Checking for updated images..."

    # Pull latest images (ignore output for now)
    docker compose --project-name "$PROJECT_NAME" pull

    # Use yq to find all services with floating tags
    FLOATING_SERVICES=$(yq '.services | to_entries[] | select(.value.image | test(":(latest|develop|edge|nightly)$")) | .key' /tmp/${PROJECT_NAME}_compose.yaml)
    
    UPDATED_SERVICES=""
    for SERVICE in $FLOATING_SERVICES; do
        # Get running container ID for the service
        CONTAINER_ID=$(docker compose --project-name "$PROJECT_NAME" ps -q "$SERVICE")
        # Get image name from compose yaml for this service
        IMAGE_NAME=$(yq -r ".services.\"$SERVICE\".image" /tmp/${PROJECT_NAME}_compose.yaml)
        if [ -z "$CONTAINER_ID" ] || [ -z "$IMAGE_NAME" ]; then
            continue
        fi
        # Get image ID of running container
        RUNNING_IMAGE_ID=$(docker inspect --format='{{.Image}}' "$CONTAINER_ID" 2>/dev/null || echo "")
        # Get image ID of latest pulled image
        LATEST_IMAGE_ID=$(docker image ls --no-trunc --format '{{.ID}}' "$IMAGE_NAME" | head -n1)
        # Compare
        if [ -n "$RUNNING_IMAGE_ID" ] && [ -n "$LATEST_IMAGE_ID" ] && [ "$RUNNING_IMAGE_ID" != "$LATEST_IMAGE_ID" ]; then
            UPDATED_SERVICES="$UPDATED_SERVICES$SERVICE ($IMAGE_NAME)\n"
        fi
    done

    if [ -n "$UPDATED_SERVICES" ]; then
        docker compose --project-name "$PROJECT_NAME" up -d
        ACTION="Floating tag image(s) refreshed"
        notify "$PROJECT_NAME - Floating Tag Update" "Action: $ACTION

Services updated (image ID changed):
\`\`\`
$UPDATED_SERVICES
\`\`\`
"
    fi

    # Always update the timestamp, even if no images were updated
    date +%s > "$FLOATING_PULL_STATE_FILE"
    exit 0
fi

log INFO "Git changes detected or initial deploy. Pulling latest..."
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
    log INFO "Skipping deploy due to [compose:noop]"
    notify "Deployment Skipped" "Commit: \`$REMOTE_HASH\`
Directive: \`[compose:noop]\`"
    exit 0
fi

ACTION="none"

# Handle forced full restart
if $FORCE_DOWN; then
    docker compose --project-name "$PROJECT_NAME" down --remove-orphans
    if $IMAGE_CHANGED; then
        docker compose --project-name "$PROJECT_NAME" pull
    fi
    docker compose --project-name "$PROJECT_NAME" up -d --build
    ACTION="Forced full restart [compose:down]"

# Handle single service restart
elif [[ -n "$RESTART_SERVICE" ]]; then
    docker compose --project-name "$PROJECT_NAME" up -d --build "$RESTART_SERVICE"
    ACTION="Restarted service \`$RESTART_SERVICE\` [compose:restart:$RESTART_SERVICE]"

# Handle forced update
elif $FORCE_UP; then
    if $IMAGE_CHANGED; then
        docker compose --project-name "$PROJECT_NAME" pull
    fi
    docker compose --project-name "$PROJECT_NAME" up -d --build
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
        docker compose --project-name "$PROJECT_NAME" down --remove-orphans
        if $IMAGE_CHANGED; then
            docker compose --project-name "$PROJECT_NAME" pull
        fi
        docker compose --project-name "$PROJECT_NAME" up -d --build
        ACTION="Compose file changed — removal detected, full restart triggered"
    else
        if $IMAGE_CHANGED; then
            docker compose --project-name "$PROJECT_NAME" pull
        fi
        docker compose --project-name "$PROJECT_NAME" up -d --build
        ACTION="Compose file changed — safe update"
    fi
else
    # No Compose file changes detected, just ensure containers are up
    docker compose --project-name "$PROJECT_NAME" up -d
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
