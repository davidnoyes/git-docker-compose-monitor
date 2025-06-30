#!/bin/bash
set -euo pipefail

SCRIPT_VERSION="v0.0.15"

###############################################################################
# Dependency Check
###############################################################################
for dep in yq docker git; do
	if ! command -v "$dep" >/dev/null 2>&1; then
		echo "ERROR: '$dep' is required but not installed."
		case "$dep" in
		yq)
			echo "Install with:"
			echo "  sudo wget -O /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64"
			echo "  sudo chmod +x /usr/local/bin/yq"
			;;
		docker)
			echo "See: https://docs.docker.com/get-docker/"
			;;
		git)
			echo "See: https://git-scm.com/book/en/v2/Getting-Started-Installing-Git"
			;;
		esac
		exit 1
	fi
done

###############################################################################
# Logging & Notification Functions
###############################################################################
LOG_LEVEL="INFO"

if [ -t 1 ]; then
	COLOR_DEBUG="\033[36m"
	COLOR_INFO="\033[32m"
	COLOR_WARN="\033[33m"
	COLOR_ERROR="\033[31m"
	COLOR_RESET="\033[0m"
else
	COLOR_DEBUG=""
	COLOR_INFO=""
	COLOR_WARN=""
	COLOR_ERROR=""
	COLOR_RESET=""
fi

log() {
	local level="$1"
	shift
	local msg
	msg="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
	local level_num min_level color
	case "$level" in
	DEBUG)
		level_num=0
		color=$COLOR_DEBUG
		;;
	INFO)
		level_num=1
		color=$COLOR_INFO
		;;
	WARN)
		level_num=2
		color=$COLOR_WARN
		;;
	ERROR)
		level_num=3
		color=$COLOR_ERROR
		;;
	*)
		level_num=1
		color=$COLOR_INFO
		;;
	esac
	case "$LOG_LEVEL" in
	DEBUG) min_level=0 ;;
	INFO) min_level=1 ;;
	WARN) min_level=2 ;;
	ERROR) min_level=3 ;;
	*) min_level=1 ;;
	esac
	if [ "$level_num" -ge "$min_level" ]; then
		echo -e "${color}${msg}${COLOR_RESET}"
	fi
}

notify() {
	local title="$1"
	local message="$2"
	local esc_title esc_message json_payload
	esc_title="${title//\`/\\\`}"
	esc_message=$(echo "$message" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk '{printf "%s\\n", $0}' | sed '$s/\\n$//')
	json_payload="{\"embeds\":[{\"title\":\"$esc_title\",\"description\":\"$esc_message\",\"color\":5814783}]}"
	echo "$title: $message"
	if [[ -z ${DISCORD_WEBHOOK_URL:-} ]]; then return; fi
	curl -s -X POST -H "Content-Type: application/json" \
		-d "$json_payload" \
		"$DISCORD_WEBHOOK_URL" >/dev/null
}

log_error_and_exit() {
	log ERROR "$1"
	notify "Deployment Error" "$1"
	exit 1
}

###############################################################################
# Argument Parsing
###############################################################################
CONFIG_FILE=""
TEST_DISCORD=false
FORCE_UP_FLAG=false
FORCE_SYNC_FLAG=false

for arg in "$@"; do
	case $arg in
	--help | -h)
		cat <<EOF
git-docker-compose-monitor compose-deploy.sh v$SCRIPT_VERSION

Usage: $0 --config-file=PATH [--test-discord] [--log-level=LEVEL] [--force-sync] [--force-up] [--version] [--help|-h]

Flags:
  --config-file=PATH   (Required) Specify project config file.
  --test-discord       Send a test notification to Discord and exit.
  --log-level=LEVEL    Set log level (DEBUG, INFO, WARN, ERROR). Default: INFO.
  --force-sync         Force a git pull before any other actions.
  --force-up           Run 'docker compose up -d' regardless of git changes. If used with --force-sync, git pull happens first.
  --version            Show script version and exit.
  --help, -h           Show this help message and exit.

Example:
  $0 --config-file=/opt/git-docker-compose-monitor/projects/project1/config
EOF
		exit 0
		;;
	--version)
		echo "compose-deploy.sh version $SCRIPT_VERSION"
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

###############################################################################
# Config Loading & Validation
###############################################################################
if [ -z "$CONFIG_FILE" ]; then
	log_error_and_exit "--config-file=PATH is required."
fi

if [ ! -f "$CONFIG_FILE" ]; then
	log_error_and_exit "Config file '$CONFIG_FILE' does not exist."
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

PROJECT_NAME="${PROJECT_NAME:-}"
PROJECT_DIR="${PROJECT_DIR:-}"
REPO_URL="${REPO_URL:-}"
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"

REQUIRED_VARS=(PROJECT_NAME PROJECT_DIR REPO_URL)
for var in "${REQUIRED_VARS[@]}"; do
	if [ -z "${!var:-}" ]; then
		log_error_and_exit "Required variable '$var' is not set in $CONFIG_FILE or environment.

Example config:
PROJECT_NAME=example
REPO_URL=git@github.com:your-org/example-repo.git
PROJECT_DIR=/opt/git-docker-compose-monitor/projects/example
DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/your-token
"
	fi
done

if [[ -z ${DISCORD_WEBHOOK_URL:-} ]]; then
	log_error_and_exit "DISCORD_WEBHOOK_URL environment variable is not set."
fi

REPO_DIR="$PROJECT_DIR/repo"
COMPOSE_HASH_FILE="$PROJECT_DIR/.compose_hash"
LAST_COMPOSE_FILE="$PROJECT_DIR/.last_compose.yaml"

###############################################################################
# Discord Test Mode
###############################################################################
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

###############################################################################
# Error Handling
###############################################################################
handle_error() {
	local exit_code=$?
	local line_no=${BASH_LINENO[0]}
	local cmd="${BASH_COMMAND}"
	local msg="ERROR: Script failed at line $line_no: '$cmd' with exit code $exit_code"
	if [ -s /tmp/compose_error.log ]; then
		local compose_err
		compose_err=$(cat /tmp/compose_error.log)
		msg="$msg

Docker Compose error output:
$compose_err"
	fi
	log ERROR "$msg"
	notify "Deployment Error" "$msg"
	exit $exit_code
}
trap 'handle_error' ERR

###############################################################################
# Compose Command Helper
###############################################################################
DC() {
	docker compose --project-name "$PROJECT_NAME" "$@"
}

###############################################################################
# Git Operations
###############################################################################
log INFO "Starting sync..."

if [ ! -d "$REPO_DIR/.git" ]; then
	git clone --quiet "$REPO_URL" "$REPO_DIR"
fi

cd "$REPO_DIR"

if $FORCE_SYNC_FLAG; then
	log INFO "--force-sync flag detected. Forcing git pull."
	git fetch --quiet origin main >/dev/null 2>&1
	git reset --hard -q origin/main >/dev/null 2>&1
fi

git fetch --quiet origin main >/dev/null 2>&1

LOCAL_HASH=$(git rev-parse HEAD)
REMOTE_HASH=$(git rev-parse origin/main)

###############################################################################
# Compose File Hashing
###############################################################################
DC config >"/tmp/${PROJECT_NAME}_compose.yaml" 2>/tmp/compose_error.log
CURRENT_HASH=$(sha256sum "/tmp/${PROJECT_NAME}_compose.yaml" | awk '{print $1}')
PREVIOUS_HASH=$(cat "$COMPOSE_HASH_FILE" 2>/dev/null || echo "none")

IMAGE_CHANGED=false
if [[ $CURRENT_HASH != "$PREVIOUS_HASH" ]]; then
	if grep -q 'image:' "/tmp/${PROJECT_NAME}_compose.yaml"; then
		IMAGE_CHANGED=true
	fi
fi

###############################################################################
# Floating Tag Logic
###############################################################################
FLOATING_TAGS_REGEX=':(latest|develop|edge|nightly)$'
FLOATING_TAG_FOUND=false
if grep -E "image:.*$FLOATING_TAGS_REGEX" "/tmp/${PROJECT_NAME}_compose.yaml" >/dev/null; then
	FLOATING_TAG_FOUND=true
fi

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
	if ((FLOATING_IMAGE_PULL_INTERVAL_MINUTES > 0)) && ((NOW_EPOCH - LAST_PULL_EPOCH >= INTERVAL_SEC)); then
		NEED_FLOATING_PULL=true
	fi
fi

###############################################################################
# Compose Actions (Helper Functions)
###############################################################################
compose_up() { DC up -d --remove-orphans; }
compose_pull() { DC pull; }

###############################################################################
# Main Logic
###############################################################################

# --force-up flag logic
if $FORCE_UP_FLAG; then
	log INFO "--force-up flag detected. Running 'docker compose up -d' regardless of git changes."
	compose_up
	ACTION="Forced up via --force-up flag"
	notify "$PROJECT_NAME - Deployment complete" "Action: $ACTION"
	exit 0
fi

# If no git/compose changes and no floating pull needed, exit if containers are running
if [ "$LOCAL_HASH" == "$REMOTE_HASH" ] && [ -f "$COMPOSE_HASH_FILE" ] && ! $NEED_FLOATING_PULL; then
	CONTAINER_IDS=$(DC ps --quiet)
	if [ -z "$CONTAINER_IDS" ]; then
		log WARN "No running containers for project ($PROJECT_NAME) — performing initial deployment."
		log DEBUG "docker compose ps output:"
		DC ps
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

	compose_pull

	FLOATING_SERVICES=$(yq '.services | to_entries[] | select(.value.image | test(":(latest|develop|edge|nightly)$")) | .key' "/tmp/${PROJECT_NAME}_compose.yaml")
	log DEBUG "Floating services found: $FLOATING_SERVICES"
	UPDATED_SERVICES=()
	while IFS= read -r SERVICE; do
		[ -z "$SERVICE" ] && continue
		SERVICE_CLEAN=${SERVICE#\"}
		SERVICE_CLEAN=${SERVICE_CLEAN%\"}
		CONTAINER_ID=$(DC ps -q "$SERVICE_CLEAN")
		IMAGE_NAME=$(yq -r ".services.\"$SERVICE_CLEAN\".image" "/tmp/${PROJECT_NAME}_compose.yaml")
		if [ -z "$CONTAINER_ID" ] || [ -z "$IMAGE_NAME" ]; then
			continue
		fi
		RUNNING_IMAGE_ID=$(docker inspect --format='{{.Image}}' "$CONTAINER_ID" 2>/dev/null || echo "")
		LATEST_IMAGE_ID=$(docker image ls --no-trunc --format '{{.ID}}' "$IMAGE_NAME" | head -n1)
		if [ -n "$RUNNING_IMAGE_ID" ] && [ -n "$LATEST_IMAGE_ID" ] && [ "$RUNNING_IMAGE_ID" != "$LATEST_IMAGE_ID" ]; then
			UPDATED_SERVICES+=("$SERVICE_CLEAN ($IMAGE_NAME)")
		fi
	done <<<"$FLOATING_SERVICES"

	if [ "${#UPDATED_SERVICES[@]}" -gt 0 ]; then
		compose_up
		ACTION="Floating tag image(s) refreshed"
		notify "$PROJECT_NAME - Floating Tag Update" "Action: $ACTION

Services updated (image ID changed):
\`\`\`
$(printf "%s\n" "${UPDATED_SERVICES[@]}")
\`\`\`
"
	fi

	date +%s >"$FLOATING_PULL_STATE_FILE"
	exit 0
fi

###############################################################################
# Commit Message Parsing
###############################################################################
parse_commit_directives() {
	local msg="$1"
	SKIP_DEPLOY=false
	FORCE_DOWN=false
	FORCE_UP=false
	RESTART_SERVICE=""
	[[ ${msg:-} == *"[compose:noop]"* ]] && SKIP_DEPLOY=true
	[[ ${msg:-} == *"[compose:down]"* ]] && FORCE_DOWN=true
	[[ ${msg:-} == *"[compose:up]"* ]] && FORCE_UP=true
	if [[ -n ${msg:-} ]] && [[ $msg =~ \[compose:restart:(.+)\] ]]; then
		RESTART_SERVICE="${BASH_REMATCH[1]}"
	fi
}

log INFO "Git changes detected or initial deploy. Pulling latest..."
git reset --hard -q origin/main >/dev/null 2>&1
COMMIT_MSG=$(git log -1 --pretty=%B)

parse_commit_directives "$COMMIT_MSG"

if $SKIP_DEPLOY; then
	log INFO "Skipping deploy due to [compose:noop]"
	notify "Deployment Skipped" "Commit: \`$REMOTE_HASH\`
Directive: \`[compose:noop]\`"
	exit 0
fi

ACTION="none"

if $FORCE_DOWN; then
	DC down --remove-orphans
	if $IMAGE_CHANGED; then
		compose_pull
	fi
	DC up -d --build
	ACTION="Forced full restart [compose:down]"

elif [[ -n $RESTART_SERVICE ]]; then
	DC up -d --build "$RESTART_SERVICE"
	ACTION="Restarted service \`$RESTART_SERVICE\` [compose:restart:$RESTART_SERVICE]"

elif $FORCE_UP; then
	if $IMAGE_CHANGED; then
		compose_pull
	fi
	DC up -d --build
	ACTION="Forced update [compose:up]"

elif [[ $CURRENT_HASH != "$PREVIOUS_HASH" ]]; then
	if [ -f "$LAST_COMPOSE_FILE" ]; then
		REMOVED=$(diff -u "$LAST_COMPOSE_FILE" "/tmp/${PROJECT_NAME}_compose.yaml" |
			grep '^-' |
			grep -E '^\-\s+(services:|volumes:|networks:)$|^\-\s{2,}[a-zA-Z0-9_-]+:$' || true)
	else
		REMOVED="yes"
	fi

	if [[ -n $REMOVED ]]; then
		DC down --remove-orphans
		if $IMAGE_CHANGED; then
			compose_pull
		fi
		DC up -d --build
		ACTION="Compose file changed — removal detected, full restart triggered"
	else
		if $IMAGE_CHANGED; then
			compose_pull
		fi
		DC up -d --build
		ACTION="Compose file changed — safe update"
	fi
else
	compose_up
	ACTION="No Compose file changes — safe up"
fi

mv "/tmp/${PROJECT_NAME}_compose.yaml" "$LAST_COMPOSE_FILE"
echo "$CURRENT_HASH" >"$COMPOSE_HASH_FILE"

if [[ $ACTION == "Compose file changed — removal detected, full restart triggered" ]] ||
	[[ $ACTION == "Compose file changed — safe update" ]] ||
	[[ $ACTION == "Forced full restart [compose:down]" ]] ||
	[[ $ACTION == "Forced update [compose:up]" ]] ||
	[[ $ACTION =~ Restarted\ service ]]; then
	notify "$PROJECT_NAME - Deployment complete" "Action: $ACTION
Commit: \`$REMOTE_HASH\`
Message: $COMMIT_MSG"
else
	notify "$PROJECT_NAME - Deployment complete" "Action: $ACTION"
fi
