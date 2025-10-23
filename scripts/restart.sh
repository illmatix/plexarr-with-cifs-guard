#!/usr/bin/env bash
# restart.sh — smarter restarts for your Compose stack
# - Auto-discovers services from docker-compose.yml
# - Supports selective restarts (--only/--except)
# - Optional rolling restarts (default) or full down/up
# - Guard to ensure a required mount exists before restarting
# - Health/ready wait after restart
set -euo pipefail

# Resolve this script's directory even if called via symlink
SCRIPT_PATH="${BASH_SOURCE[0]}"
while [ -h "$SCRIPT_PATH" ]; do
  DIR="$(cd -P "$(dirname "$SCRIPT_PATH")" && pwd)"
  SCRIPT_PATH="$(readlink "$SCRIPT_PATH")"
  [[ "$SCRIPT_PATH" != /* ]] && SCRIPT_PATH="$DIR/$SCRIPT_PATH"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_PATH")" && pwd)"

# Repo root = parent of ./scripts
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

# Compose file is now absolute and safe
COMPOSE_FILE="$ROOT_DIR/docker-compose.yml"

cd "$(dirname "$0")"

# ---------------------- Config (overridable via env or flags) -------------------
COMPOSE_FILE="${COMPOSE_FILE:-./docker-compose.yml}"
REQUIRE_MOUNT="${REQUIRE_MOUNT:-/mnt/nas}"   # "" to skip mount check
ROLLING="${ROLLING:-true}"                   # true = rolling restart; false = full down/up
ONLY="${ONLY:-}"                             # comma-separated service names to include
EXCEPT="${EXCEPT:-}"                         # comma-separated service names to exclude
RUNNING_ONLY="${RUNNING_ONLY:-false}"        # true = only restart currently running services
WAIT_HEALTH="${WAIT_HEALTH:-true}"           # wait for healthy containers after restart
WAIT_SECS="${WAIT_SECS:-120}"                # max seconds to wait for health/ready
DRY_RUN="${DRY_RUN:-false}"                  # print commands instead of executing

# ---------------------- Help ----------------------------------------------------
usage() {
  cat <<EOF
Usage: ${0##*/} [options]

Options:
  -f, --file FILE        Compose file (default: ${COMPOSE_FILE})
  -o, --only a,b         Only restart these services
  -x, --except a,b       Exclude these services
  -r, --running          Only restart currently running services
  --full                 Use full restart: 'compose down' then 'up -d' (default is rolling)
  --no-mount-check       Skip required mount check (${REQUIRE_MOUNT})
  --no-wait              Do not wait for healthy/ready containers
  -w, --wait SECS        Max seconds to wait for health/ready (default: ${WAIT_SECS})
  -n, --dry-run          Print actions without executing
  -h, --help             Show this help

Env overrides: COMPOSE_FILE, REQUIRE_MOUNT, ROLLING, ONLY, EXCEPT, RUNNING_ONLY, WAIT_HEALTH, WAIT_SECS, DRY_RUN
EOF
}

# ---------------------- Parse args ---------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--file) COMPOSE_FILE="$2"; shift 2;;
    -o|--only) ONLY="$2"; shift 2;;
    -x|--except) EXCEPT="$2"; shift 2;;
    -r|--running) RUNNING_ONLY="true"; shift;;
    --full) ROLLING="false"; shift;;
    --no-mount-check) REQUIRE_MOUNT=""; shift;;
    --no-wait) WAIT_HEALTH="false"; shift;;
    -w|--wait) WAIT_SECS="$2"; shift 2;;
    -n|--dry-run) DRY_RUN="true"; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1;;
  esac
done

# ---------------------- Helpers -------------------------------------------------
COMPOSE=(docker compose -f "$COMPOSE_FILE")
run() { echo "+ $*"; [[ "$DRY_RUN" == "true" ]] || eval "$@"; }

require_cmd() { command -v "$1" >/dev/null || { echo "Missing command: $1" >&2; exit 1; }; }
require_cmd docker

[[ -r "$COMPOSE_FILE" ]] || { echo "Compose file not found: $COMPOSE_FILE" >&2; exit 1; }

# Guard: ensure mount exists to avoid binding empty dirs
if [[ -n "$REQUIRE_MOUNT" ]]; then
  if ! findmnt -rn --target "$REQUIRE_MOUNT" >/dev/null 2>&1; then
    echo "ERROR: Required mount '$REQUIRE_MOUNT' is not mounted. Aborting to avoid empty binds." >&2
    exit 1
  fi
fi

# Discover services from compose
mapfile -t ALL_SERVICES < <("${COMPOSE[@]}" config --services)

# Filter services based on ONLY/EXCEPT/RUNNING_ONLY
filter_services() {
  local -n src=$1 dst=$2
  local only_csv="$3" except_csv="$4" running_only="$5"

  local -a only=() except=() running=()
  local IFS=,

  [[ -n "$only_csv" ]] && read -r -a only <<< "$only_csv" || true
  [[ -n "$except_csv" ]] && read -r -a except <<< "$except_csv" || true
  if [[ "$running_only" == "true" ]]; then
    mapfile -t running < <("${COMPOSE[@]}" ps --services --status=running)
  fi

  for s in "${src[@]}"; do
    local keep=1
    if [[ ${#only[@]} -gt 0 ]]; then
      keep=0; for o in "${only[@]}"; do [[ "$s" == "$o" ]] && keep=1; done
    fi
    if [[ $keep -eq 1 && ${#except[@]} -gt 0 ]]; then
      for x in "${except[@]}"; do [[ "$s" == "$x" ]] && keep=0; done
    fi
    if [[ $keep -eq 1 && ${#running[@]} -gt 0 ]]; then
      local found=0; for r in "${running[@]}"; do [[ "$s" == "$r" ]] && found=1; done
      [[ $found -eq 1 ]] || keep=0
    fi
    [[ $keep -eq 1 ]] && dst+=("$s")
  done
}

SERVICES=()
filter_services ALL_SERVICES SERVICES "$ONLY" "$EXCEPT" "$RUNNING_ONLY"
if [[ ${#SERVICES[@]} -eq 0 ]]; then
  echo "No services matched filters. All services: ${ALL_SERVICES[*]}" >&2
  exit 1
fi

echo "Services selected: ${SERVICES[*]}"

# ---------------------- Restart logic ------------------------------------------
if [[ "$ROLLING" == "true" ]]; then
  echo "Performing rolling restart (no full down)..."
  # For each service: stop -> start detached; or just recreate via up -d
  # Recreate ensures config/env updates are applied.
  run "${COMPOSE[*]} up -d --remove-orphans ${SERVICES[*]}"
else
  echo "Performing full restart (down -> up -d)..."
  run "${COMPOSE[*]} down"
  run "${COMPOSE[*]} up -d --remove-orphans"
fi

# ---------------------- Post: wait for health/ready -----------------------------
if [[ "$WAIT_HEALTH" == "true" ]]; then
  echo "Waiting up to ${WAIT_SECS}s for services to be healthy/ready..."
  deadline=$(( $(date +%s) + WAIT_SECS ))
  not_ready=("${SERVICES[@]}")

  is_ready() {
    local s="$1"
    # Prefer health status if present; otherwise consider running as ready.
    local status; status="$("${COMPOSE[@]}" ps --status=running --services | grep -Fx "$s" || true)"
    if [[ -z "$status" ]]; then return 1; fi
    # If 'health' column exists, check it:
    local line; line="$("${COMPOSE[@]}" ps | awk -v S="$s" '$1==S {print $0}')"
    if grep -q 'healthy' <<<"$line"; then return 0; fi
    if grep -q 'unhealthy' <<<"$line"; then return 1; fi
    # No healthcheck configured: running is good enough
    return 0
  }

  while ((${#not_ready[@]})); do
    now=$(date +%s)
    if (( now > deadline )); then
      echo "Timed out waiting for: ${not_ready[*]}"
      "${COMPOSE[@]}" ps
      exit 1
    fi
    tmp=()
    for s in "${not_ready[@]}"; do
      if is_ready "$s"; then
        echo "✓ ${s} ready"
      else
        tmp+=("$s")
      fi
    done
    not_ready=("${tmp[@]}")
    ((${#not_ready[@]})) && sleep 3
  done
fi

# ---------------------- Status --------------------------------------------------
echo "Final status:"
run "${COMPOSE[*]} ps"

echo "Restart process completed."
