#!/bin/bash
set -euo pipefail

CONFIG_FILE=${CONFIG_FILE:-"/opt/gh-docker-compose-monitor/projects/$PROJECT_NAME/config"}
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

function notify_discord() {
    local title="$1"
    local message="$2"
    if [[ -z "${DISCORD_WEBHOOK_URL:-}" ]]; then return; fi
    curl -s -X POST -H "Content-Type: application/json" \
      -d "{"embeds":[{"title":"$title","description":"$message","color":5814783}]}" \
      "$DISCORD_WEBHOOK_URL" > /dev/null
}

function handle_error() {
    local exit_code=$?
    local msg="ERROR: Script failed with exit code $exit_code"
    echo "$msg"
    notify_discord "Deployment Error" "$msg"
    exit $exit_code
}
trap handle_error ERR

echo "[$(date)] Starting sync..."

if [ ! -d "$REPO_DIR/.git" ]; then
    git clone "$REPO_URL" "$REPO_DIR"
fi

cd "$REPO_DIR"
git fetch origin main

LOCAL_HASH=$(git rev-parse HEAD)
REMOTE_HASH=$(git rev-parse origin/main)

if [ "$LOCAL_HASH" == "$REMOTE_HASH" ]; then
    if [ ! -f "$CONFIG_HASH_FILE" ]; then
        echo "First run detected — no prior config hash, proceeding with initial deployment."
    elif ! docker compose --project-name "$PROJECT_NAME" ps --quiet | grep -q .; then
        echo "No running containers for project — performing initial deployment."
    else
        echo "No Git changes detected. Exiting."
        exit 0
    fi
fi

echo "Git changes detected or initial deploy. Pulling latest..."
git reset --hard origin/main
COMMIT_MSG=$(git log -1 --pretty=%B)

FORCE_DOWN=false
FORCE_UP=false
SKIP_DEPLOY=false
RESTART_SERVICE=""

[[ "$COMMIT_MSG" == *"[compose:noop]"* ]] && SKIP_DEPLOY=true
[[ "$COMMIT_MSG" == *"[compose:down]"* ]] && FORCE_DOWN=true
[[ "$COMMIT_MSG" == *"[compose:up]"* ]] && FORCE_UP=true
[[ "$COMMIT_MSG" =~ \[compose:restart:(.+)\] ]] && RESTART_SERVICE="${BASH_REMATCH[1]}"

if $SKIP_DEPLOY; then
    echo "Skipping deploy due to [compose:noop]"
    notify_discord "Deployment Skipped" "Commit: \`$REMOTE_HASH\`
Directive: \`[compose:noop]\`"
    exit 0
fi

docker compose --project-name "$PROJECT_NAME" pull
docker compose --project-name "$PROJECT_NAME" config > /tmp/current_compose_config.yaml
CURRENT_HASH=$(sha256sum /tmp/current_compose_config.yaml | awk '{print $1}')
PREVIOUS_HASH=$(cat "$CONFIG_HASH_FILE" 2>/dev/null || echo "none")

ACTION="none"

if $FORCE_DOWN; then
    docker compose --project-name "$PROJECT_NAME" down --remove-orphans
    docker compose --project-name "$PROJECT_NAME" up -d --build
    ACTION="Forced full restart [compose:down]"

elif [[ -n "$RESTART_SERVICE" ]]; then
    docker compose --project-name "$PROJECT_NAME" up -d --build "$RESTART_SERVICE"
    ACTION="Restarted service \`$RESTART_SERVICE\` [compose:restart:$RESTART_SERVICE]"

elif $FORCE_UP; then
    docker compose --project-name "$PROJECT_NAME" up -d --build
    ACTION="Forced update [compose:up]"

elif [[ "$CURRENT_HASH" != "$PREVIOUS_HASH" ]]; then
    if [ -f "$CONFIG_DUMP_FILE" ]; then
        STRUCTURAL_DIFF=$(diff -u "$CONFIG_DUMP_FILE" /tmp/current_compose_config.yaml \
            | grep '^-' | grep -E '(image|build|volume|network|depends_on|container_name|deploy)' || true)
    else
        STRUCTURAL_DIFF="yes"
    fi

    if [[ -n "$STRUCTURAL_DIFF" ]]; then
        docker compose --project-name "$PROJECT_NAME" down --remove-orphans
        docker compose --project-name "$PROJECT_NAME" up -d --build
        ACTION="Config changed — full restart triggered"
    else
        docker compose --project-name "$PROJECT_NAME" up -d --build
        ACTION="Config changed — safe update"
    fi
else
    docker compose --project-name "$PROJECT_NAME" up -d
    ACTION="No config changes — safe up"
fi

mv /tmp/current_compose_config.yaml "$CONFIG_DUMP_FILE"
echo "$CURRENT_HASH" > "$CONFIG_HASH_FILE"

echo "Deployment complete. Action: $ACTION"
notify_discord "Deployment Performed" "Commit: \`$REMOTE_HASH\`
Action: $ACTION"
